import AppKit
import EvieCore
import Foundation

/// The schedules, the editor above them, and the `launchd` jobs behind them.
///
/// Every write goes to both places at once. The store is what the run reads and
/// the pane shows; the LaunchAgent is what actually makes it happen. A change
/// that reached only one of them is a schedule that lies about itself — a row
/// saying 08:00 that fires at seven, or a row the user deleted that goes on
/// waking the Mac. So `save` and `remove` here always do both, and when the
/// second half fails the first is undone.
///
/// The editor's fields live here rather than in `@State`: this toolchain is the
/// Command Line Tools without Xcode and SwiftUI's `@State` macro plugin ships
/// only with Xcode. Same reason as `OverlayChromeModel`; see
/// `docs/MACOS_RUNTIME.md`.
@MainActor
final class EvieSchedulesViewModel: ObservableObject {
  @Published private(set) var schedules: [EvieSchedule] = []
  @Published private(set) var feedback: Feedback?
  /// Which schedule is running right now, if the user pressed "Testar".
  @Published private(set) var runningID: String?

  // The editor. `nil` in `editingID` means the fields describe a new schedule.
  @Published var isEditing = false
  @Published var editingID: String?
  @Published var draftName = ""
  @Published var draftPrompt = ""
  /// 0 daily, 1 weekly, 2 folder. An index because that is what a segmented
  /// picker binds to.
  @Published var draftKind = 0
  @Published var draftHour = 8
  @Published var draftMinute = 0
  @Published var draftWeekdays: Set<Int> = [1, 2, 3, 4, 5]
  @Published var draftFolder = ""

  struct Feedback: Equatable {
    var message: String
    var isError: Bool
  }

  private let store: EvieScheduleStore
  private let agents: EvieLaunchAgents

  init(
    store: EvieScheduleStore = EvieScheduleStore(),
    agents: EvieLaunchAgents = EvieLaunchAgents()
  ) {
    self.store = store
    self.agents = agents
    reload()
  }

  func reload() {
    schedules = store.load().sorted { $0.createdAt < $1.createdAt }
    sweepOrphans()
  }

  var canSaveDraft: Bool {
    (try? draftSchedule().validate()) != nil
  }

  func beginNewSchedule() {
    editingID = nil
    draftName = ""
    draftPrompt = ""
    draftKind = 0
    draftHour = 8
    draftMinute = 0
    draftWeekdays = [1, 2, 3, 4, 5]
    draftFolder = ""
    isEditing = true
  }

  func beginEditing(_ schedule: EvieSchedule) {
    editingID = schedule.id
    draftName = schedule.name
    draftPrompt = schedule.prompt
    switch schedule.trigger {
    case .daily(let hour, let minute):
      draftKind = 0
      draftHour = hour
      draftMinute = minute
    case .weekly(let weekdays, let hour, let minute):
      draftKind = 1
      draftWeekdays = Set(weekdays)
      draftHour = hour
      draftMinute = minute
    case .folder(let path):
      draftKind = 2
      draftFolder = path
    }
    isEditing = true
  }

  func cancelEditing() {
    isEditing = false
  }

  /// Picks the folder to watch. A panel rather than a text field, because the
  /// path has to be one that exists and one the user can actually reach.
  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Escolher"
    panel.message = "Qual pasta ela deve vigiar?"
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    draftFolder = url.path
  }

  /// Writes the schedule and installs its job.
  func saveDraft() {
    let schedule = draftSchedule()
    do {
      try schedule.validate()
    } catch {
      feedback = Feedback(message: Self.explain(error), isError: true)
      return
    }

    var updated = schedules
    if let index = updated.firstIndex(where: { $0.id == schedule.id }) {
      updated[index] = schedule
    } else {
      guard updated.count < EvieSchedule.maximumSchedules else {
        feedback = Feedback(
          message: "Já são \(EvieSchedule.maximumSchedules) agendamentos — apague um antes.",
          isError: true
        )
        return
      }
      updated.append(schedule)
    }

    let previous = schedules
    do {
      try store.save(updated)
      try agents.install(schedule)
      schedules = updated.sorted { $0.createdAt < $1.createdAt }
      isEditing = false
      feedback = Feedback(message: "\(schedule.name): \(schedule.summary).", isError: false)
    } catch {
      // The store already took it and `launchd` did not. Rolling back keeps the
      // pane honest: a row that exists is a job that exists.
      try? store.save(previous)
      schedules = previous
      feedback = Feedback(message: Self.explain(error), isError: true)
      return
    }

    // Asked here, with somebody looking at the screen, rather than at the moment
    // a schedule fires — see `EvieScheduleNotifier`.
    Task { @MainActor in
      let granted = await EvieScheduleNotifier.requestAuthorization()
      guard !granted else {
        return
      }
      feedback = Feedback(
        message:
          "Guardei. Este Mac não deixa a Evie mandar avisos com o nome dela, "
          + "então o aviso vai chegar por outro caminho — e a resposta inteira "
          + "fica sempre no histórico.",
        isError: false
      )
    }
  }

  /// Turning one off unloads the job and removes its file; turning it back on
  /// writes them again. There is no "loaded but idle" state, on purpose: a job
  /// `launchd` holds is a Mac that wakes up for it.
  func setEnabled(_ enabled: Bool, for schedule: EvieSchedule) {
    var updated = schedule
    updated.isEnabled = enabled
    var all = schedules
    guard let index = all.firstIndex(where: { $0.id == schedule.id }) else {
      return
    }
    all[index] = updated
    do {
      try store.save(all)
      if enabled {
        try agents.install(updated)
      } else {
        agents.remove(updated)
      }
      schedules = all
    } catch {
      feedback = Feedback(message: Self.explain(error), isError: true)
      reload()
    }
  }

  func remove(_ schedule: EvieSchedule) {
    // The job goes first. A store that no longer lists it while `launchd` still
    // holds it is the one failure that keeps firing after the user believes it
    // is gone.
    agents.remove(schedule)
    let remaining = schedules.filter { $0.id != schedule.id }
    do {
      try store.save(remaining)
      schedules = remaining
      feedback = Feedback(message: "Apaguei \"\(schedule.name)\".", isError: false)
    } catch {
      feedback = Feedback(message: Self.explain(error), isError: true)
    }
  }

  /// Runs it now, through `launchd`, so what is tested is the job that will fire
  /// at eight rather than a second path that resembles it.
  ///
  /// Nothing is awaited: the run is another process and takes as long as a turn
  /// takes. The banner and the history are how it reports, exactly as it will
  /// when nobody pressed anything.
  func runNow(_ schedule: EvieSchedule) {
    guard schedule.isEnabled else {
      feedback = Feedback(
        message: "Ligue o agendamento antes de testar — desligado, o launchd não o tem.",
        isError: true
      )
      return
    }
    do {
      try agents.runNow(schedule)
      runningID = schedule.id
      feedback = Feedback(
        message: "Rodando \"\(schedule.name)\" agora. A resposta chega por notificação.",
        isError: false
      )
      // Cleared after a moment because there is nothing to watch: the run is a
      // separate process and this one is not told when it ends.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        self?.runningID = nil
      }
    } catch {
      feedback = Feedback(message: Self.explain(error), isError: true)
    }
  }

  func revealLog(for schedule: EvieSchedule) {
    let url = agents.logURL(for: schedule)
    guard FileManager.default.fileExists(atPath: url.path) else {
      feedback = Feedback(message: "Esse agendamento ainda não rodou nenhuma vez.", isError: false)
      return
    }
    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
  }
}

extension EvieSchedulesViewModel {
  /// The editor's fields as a schedule. Keeps the identifier when editing, so
  /// `launchd` goes on knowing the job by the same label.
  fileprivate func draftSchedule() -> EvieSchedule {
    let existing = schedules.first { $0.id == editingID }
    return EvieSchedule(
      id: existing?.id ?? EvieSchedule.makeIdentifier(),
      name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
      prompt: draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
      trigger: draftTrigger(),
      isEnabled: existing?.isEnabled ?? true,
      createdAt: existing?.createdAt ?? Date()
    )
  }

  fileprivate func draftTrigger() -> EvieScheduleTrigger {
    switch draftKind {
    case 1:
      .weekly(weekdays: draftWeekdays.sorted(), hour: draftHour, minute: draftMinute)
    case 2:
      .folder(path: draftFolder)
    default:
      .daily(hour: draftHour, minute: draftMinute)
    }
  }

  /// Jobs whose schedule is gone — a store edited by hand, an install rolled
  /// back halfway, a version of Evie that crashed between the two writes.
  ///
  /// Swept on every load rather than reported, because there is nothing for the
  /// user to decide: a job with no schedule behind it wakes the Mac to print
  /// "nenhum agendamento com esse id" and quit.
  fileprivate func sweepOrphans() {
    let known = Set(schedules.filter(\.isEnabled).map(\.id))
    for identifier in agents.installedIdentifiers() where !known.contains(identifier) {
      // Reconstructed only far enough to name the file and the label; nothing
      // else about it is known, and nothing else is needed to remove it.
      agents.remove(
        EvieSchedule(
          id: identifier,
          name: "órfão",
          prompt: "órfão",
          trigger: .daily(hour: 0, minute: 0)
        )
      )
    }
  }

  fileprivate static func explain(_ error: any Error) -> String {
    switch error {
    case EvieSchedule.ValidationFailure.nameIsEmpty:
      "Dê um nome a este agendamento."
    case EvieSchedule.ValidationFailure.nameIsTooLong:
      "O nome está longo demais."
    case EvieSchedule.ValidationFailure.promptIsEmpty:
      "Escreva o que ela deve fazer."
    case EvieSchedule.ValidationFailure.promptIsTooLong:
      "O pedido está longo demais para um agendamento."
    case EvieSchedule.ValidationFailure.triggerIsInvalid(.noWeekdaysChosen):
      "Escolha pelo menos um dia da semana."
    case EvieSchedule.ValidationFailure.triggerIsInvalid(.pathIsEmpty),
      EvieSchedule.ValidationFailure.triggerIsInvalid(.pathIsNotAbsolute):
      "Escolha a pasta que ela deve vigiar."
    case EvieLaunchAgents.Failure.couldNotWritePlist:
      "Não consegui escrever o arquivo do agendamento."
    case EvieLaunchAgents.Failure.launchctlFailed(let command, let status, let output):
      // Apple's own sentence, verbatim and in quotes. A paraphrase of a
      // `launchctl` error is a paraphrase of the only clue there is.
      "O launchd recusou (\(command), código \(status)): «\(output)»"
    default:
      "Não consegui guardar este agendamento."
    }
  }
}
