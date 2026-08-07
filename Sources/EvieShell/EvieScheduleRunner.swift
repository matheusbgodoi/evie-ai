import AppKit
import EvieCore
import Foundation

/// What happens when `launchd` wakes Evie to run one schedule.
///
/// The process exists for exactly this: it starts, takes the lock, asks the
/// question, writes the answer where the user will find it, and quits. Nothing
/// is left running — no overlay, no wake listener, no voice engine, no timer.
/// That is the promise the whole feature is built on.
///
/// The question goes through `EvieAgentLoop` with the persona, the memories, the
/// granted folders and the web exactly as a typed question does. A scheduled
/// question and a typed one are the same question asked by a different hand, and
/// a second code path here would be a second set of answers to keep in step.
@MainActor
enum EvieScheduleRunner {
  /// The whole run. Returns when there is nothing left to do; the caller quits.
  static func run(identifier: String) async {
    // Line-buffered because standard output is the log file `launchd` opened,
    // and a run that is watched while it happens is the only way to see where a
    // slow one is stuck.
    setvbuf(stdout, nil, _IOLBF, 0)

    let started = Date()
    log("— \(stamp(started)) — agendamento \(identifier)")

    guard let schedule = EvieScheduleStore().schedule(withID: identifier) else {
      // The plist outlived the schedule. Not an error worth a notification: the
      // user deleted something, and the remedy is to stop the job, which the
      // settings pane does when it next sweeps.
      log("nenhum agendamento com esse id — nada a fazer")
      return
    }
    log("\"\(schedule.name)\" · \(schedule.summary)")

    guard let lock = EvieScheduleLock() else {
      log("PULEI: outro agendamento já está rodando")
      return
    }
    // Named so it is obvious the lock is being held on purpose for the length of
    // the run, rather than released the moment the initialiser returns.
    defer { _ = lock }

    let preferences = EviePreferencesStore().load()
    let roots = EvieRootRegistry().load()
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()

    // The same rule the coordinator applies when the overlay opens: a capability
    // is claimed only where its code path is actually wired. The two that a
    // scheduled run genuinely has are files and, if the user switched it on, the
    // web; she has no microphone here and nothing to speak to.
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsImagesAndDocuments = true
    capabilities.readsLocalFiles = !roots.isEmpty
    capabilities.searchesTheWeb = preferences.webSearchEnabled

    let web: (any EvieWebSearching)? = preferences.webSearchEnabled ? EvieWebClient() : nil
    let messages = [
      ChatMessage(
        role: .system,
        content: OverlayViewModel.systemPrompt(
          for: capabilities,
          remembering: EvieMemoryStore().load()
        )
      ),
      ChatMessage(role: .user, content: schedule.prompt),
    ]

    do {
      let outcome = try await EvieAgentLoop(
        web: web,
        // No vault retrieval. Building the index costs minutes of CPU over every
        // note in every granted folder, and a schedule that rebuilt it at eight
        // every morning would be precisely the background cost this design
        // refuses. The file tools still reach the same folders.
        vault: nil,
        // Nothing a schedule does may change a file. A change is approved by
        // somebody looking at a card, and at eight in the morning nobody is.
        offersChanges: false
      ).run(
        messages: messages,
        roots: roots,
        client: TurboFieldfareClient(configuration: configuration),
        emit: { event in
          if case .status(let message) = event {
            await log("   · \(message)")
          }
        }
      )

      let answer = outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines)
      let elapsed = Date().timeIntervalSince(started)
      guard !answer.isEmpty else {
        log(String(format: "SEM RESPOSTA em %.0f s — o laço se esgotou", elapsed))
        await report(
          schedule: schedule,
          title: schedule.name,
          body: "Ela não conseguiu responder desta vez. Abra a Evie para tentar de novo.",
          answer: nil,
          messages: messages
        )
        return
      }

      log(String(format: "resposta em %.0f s, %d chamada(s) de tool", elapsed, outcome.toolCallCount))
      await report(
        schedule: schedule,
        title: schedule.name,
        body: answer,
        answer: answer,
        messages: messages
      )
    } catch {
      let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      log("FALHOU: \(reason)")
      // A failure is reported as loudly as a success. A schedule that quietly
      // stopped working is worse than one that never worked: the user goes on
      // believing the mail was read.
      await report(
        schedule: schedule,
        title: schedule.name,
        body: "Não consegui rodar isso agora: \(reason)",
        answer: nil,
        messages: messages
      )
    }
  }

  /// Puts the result where it will be found: the history, then a banner.
  ///
  /// History first, deliberately. If the notification is refused — permission
  /// denied, Do Not Disturb, a bug in a future macOS — the answer still exists.
  /// The other order can lose it.
  private static func report(
    schedule: EvieSchedule,
    title: String,
    body: String,
    answer: String?,
    messages: [ChatMessage]
  ) async {
    await store(schedule: schedule, question: messages, answer: answer ?? body)
    log(await EvieScheduleNotifier.post(title: title, body: body).note)
  }

  /// One conversation per run, so it appears in the history window like any
  /// other. Titled with the schedule's name rather than the first line of the
  /// answer: a column of "Resumo da manhã" entries is scannable, and a column of
  /// answers that all begin "Você tem 4 e-mails" is not.
  private static func store(
    schedule: EvieSchedule,
    question: [ChatMessage],
    answer: String
  ) async {
    let visible = question.filter { $0.role == .user }
    do {
      _ = try await EvieConversationStore().create(
        title: schedule.name,
        messages: visible + [ChatMessage(role: .assistant, content: answer)]
      )
    } catch {
      // Logged, not raised. The banner is still going out, and a history that
      // failed to save is not a reason to withhold the answer entirely.
      log("não consegui guardar no histórico: \(error)")
    }
  }

  private static func log(_ line: String) {
    print(line)
  }

  private static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}
