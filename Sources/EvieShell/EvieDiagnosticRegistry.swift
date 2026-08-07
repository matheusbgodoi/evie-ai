import AppKit
import EvieCore
import Foundation

/// Every diagnostic flag the shell answers to.
///
/// The order is the order the flags used to be tested in, and it is kept because
/// it decides which one wins when two are written on the same line. Nothing
/// depends on that today, but changing it silently is the sort of thing that is
/// only noticed once it has already confused somebody.
@MainActor
enum EvieDiagnosticRegistry {
  static let all: [EvieDiagnostic] = [
    EvieDiagnostic.immediate(
      flag: "--help",
      summary: "esta lista"
    ) { _ in
      print(helpText)
    },

    // Exists so the exact hidden instructions Evie receives can be reviewed
    // without reading them out of a running conversation.
    EvieDiagnostic.immediate(
      flag: "--print-persona",
      summary: "imprime as instruções ocultas que a Evie recebe"
    ) { _ in
      EvieDiagnostics.printPersona()
    },

    // Reports the microphone situation without asking for anything. Deliberately
    // never calls `requestAccess`: a diagnostic must not put a consent dialog on
    // someone's screen as a side effect of being run.
    EvieDiagnostic.immediate(
      flag: "--audio-check",
      summary: "o que o microfone permite, sem pedir permissão a ninguém"
    ) { _ in
      EvieDiagnostics.audioCheck()
    },

    // Reports whether this Mac can transcribe Portuguese, and whether doing so
    // would first need a download. Opens no microphone.
    EvieDiagnostic.terminating(
      flag: "--speech-check",
      summary: "se este Mac transcreve português, e se precisa baixar algo"
    ) { _ in
      await EvieDiagnostics.speechCheck()
    },

    // Stores real files and reports what they cost, because "compressed" is a
    // claim and a ratio is a measurement.
    //
    // The termination request stays inside the body, unlike every other check
    // here, so it keeps its original position relative to the `defer` that
    // clears the scratch folder.
    EvieDiagnostic(
      flag: "--media-check",
      usage: "--media-check <arquivo>…",
      summary: "guarda arquivos de verdade e diz quanto passaram a ocupar",
      requiredArguments: 1
    ) { arguments, _ in
      let paths = arguments.values()
      Task { @MainActor in
        await EvieDiagnostics.mediaCheck(paths: paths)
      }
    },

    // Runs a real plan against the running model and prints each stage, because
    // the only thing worth knowing about a planner is whether the model actually
    // produces a list this parser can read.
    EvieDiagnostic.terminating(
      flag: "--plan-check",
      usage: "--plan-check <pergunta>",
      summary: "planeja, cumpre cada etapa e sintetiza, imprimindo cada estágio",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.planCheck(arguments.value())
    },

    // Runs the update check against the real feed, and runs the signature
    // verification against real tampered copies of this very bundle. The second
    // half is the one that matters: it is the only thing standing between a
    // release feed and code executing here.
    EvieDiagnostic.terminating(
      flag: "--update-check",
      summary: "checa o feed e verifica a assinatura contra cópias adulteradas"
    ) { _ in
      await EvieDiagnostics.updateCheck()
    },

    // Brings the voice engine up the way asking her to speak does, and reports
    // how long it took. The point is to prove the app can start it without the
    // shell script, which is the failure this exists for.
    EvieDiagnostic.terminating(
      flag: "--voice-engine-check",
      summary: "sobe o motor de voz como a Evie sobe, e cronometra"
    ) { _ in
      await EvieDiagnostics.voiceEngineCheck()
    },

    // Speaks one sentence out loud through the whole path — synthesis, playback,
    // and metering — and reports what happened. You hear it; the file says
    // whether the level was real.
    EvieDiagnostic.terminating(
      flag: "--speak-check",
      summary: "fala uma frase em voz alta e mede o nível de saída"
    ) { _ in
      await EvieDiagnostics.speakCheck()
    },

    // Drives the presentation animation through the sequence most likely to break
    // it — show, hide, and show again before the dismissal has finished — and
    // reports whether the window survived. A half-faded or ordered-out overlay is
    // the failure this guards against.
    //
    // The only check that needs the delegate: the coordinator it drives has to be
    // held for the duration, and started before the run loop turns.
    EvieDiagnostic(
      flag: "--presentation-check",
      summary: "abre, esconde e reabre a janela depressa, e diz se ela sobreviveu"
    ) { _, delegate in
      let coordinator = AppCoordinator()
      delegate.retain(coordinator)
      coordinator.start()
      Task { @MainActor in
        await EvieDiagnostics.presentationCheck(coordinator: coordinator)
        NSApp.terminate(nil)
      }
    },

    // Opens the microphone for a couple of seconds through exactly the path a
    // real activation takes, and writes what happened to a file. Launch Services
    // gives no console, and this is the only way to exercise the audio tap —
    // where a main-actor closure once crashed the process — without a mouse.
    EvieDiagnostic.terminating(
      flag: "--voice-check",
      summary: "abre o microfone por alguns segundos e registra o que aconteceu"
    ) { _ in
      await EvieDiagnostics.voiceCheck()
    },

    // Arms the wake listener for a fixed period and reports what it cost.
    //
    // The promise this project makes is "only spends processing when the tool is
    // used", and arming is the one state where that could quietly be false. It
    // was never measured before this flag existed.
    EvieDiagnostic.terminating(
      flag: "--wake-cost-check",
      usage: "--wake-cost-check [segundos]",
      summary: "mede o que custa deixar a escuta por nome armada (30 s por fase)"
    ) { arguments in
      await EvieDiagnostics.wakeCostCheck(seconds: arguments.number() ?? 30)
    },

    // Reads a file and prints exactly what Evie would receive. Useful on its own,
    // and the only way to check the reader without dragging something onto a
    // window.
    EvieDiagnostic.terminating(
      flag: "--read",
      usage: "--read <arquivo>",
      summary: "imprime exatamente o que a Evie receberia deste arquivo",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.read(fileAt: arguments.url())
    },

    // Runs a real agentic turn against the running model, over a folder made for
    // the occasion. The wire format was proved with a throwaway script; this is
    // the only thing that proves *this* client speaks it, which is the part that
    // would otherwise be discovered by a person asking Evie a question.
    EvieDiagnostic.terminating(
      flag: "--tools-check",
      summary: "uma rodada agêntica real sobre uma pasta feita para a ocasião"
    ) { _ in
      await EvieDiagnostics.toolsCheck()
    },

    // Asks a real question of a real folder — the vault, by default — so that
    // "she can read my notes" is something demonstrated rather than claimed.
    EvieDiagnostic.terminating(
      flag: "--ask-folder",
      usage: "--ask-folder <pasta> <pergunta>",
      summary: "pergunta de verdade a uma pasta de verdade, com as tools ligadas",
      requiredArguments: 2
    ) { arguments in
      await EvieDiagnostics.folderQuestion(folder: arguments.url(), question: arguments.value(1))
    },

    // A real agentic turn with the web switched on, so the whole path — decide to
    // search, search, open a page, answer — is demonstrated rather than assumed.
    EvieDiagnostic.terminating(
      flag: "--ask-web",
      usage: "--ask-web <pergunta>",
      summary: "uma rodada agêntica com a web ligada, de ponta a ponta",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.webQuestion(arguments.value())
    },

    // Exercises the voice library through the same client the settings window
    // uses. The engine's protocol was proved with a throwaway script; this is
    // what proves *this* code speaks it, which is otherwise discovered by a
    // person trying to train a voice and getting an error.
    EvieDiagnostic.terminating(
      flag: "--voices-check",
      usage: "--voices-check <áudio>",
      summary: "treina, usa e apaga uma voz clonada descartável",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.voicesCheck(audioURL: arguments.url())
    },

    // Proves the one part of Evie that leaves this Mac actually works, and
    // shows exactly what it sends and receives.
    EvieDiagnostic.terminating(
      flag: "--web-check",
      usage: "--web-check <busca>",
      summary: "busca, lê uma página e confere os endereços que devem ser recusados",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.webCheck(query: arguments.value())
    },

    // Measures the claim that selecting passages is both smaller and better than
    // taking a prefix, rather than asserting it.
    EvieDiagnostic.terminating(
      flag: "--passage-check",
      usage: "--passage-check <busca>",
      summary: "compara pegar um prefixo de uma página com selecionar trechos de três",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.passageCheck(query: arguments.value())
    },

    // Describes a real image through the real path, so "she can see" is
    // demonstrated rather than claimed.
    EvieDiagnostic.terminating(
      flag: "--see",
      usage: "--see <imagem>",
      summary: "descreve uma imagem e mostra o texto reconhecido nela",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.see(imageAt: arguments.url())
    },

    // Drives the whole change path against the running model over a throwaway
    // folder: she proposes, the proposal is inspected, it is performed, and the
    // file is checked afterwards. Nothing about this is asserted from the couch.
    EvieDiagnostic.terminating(
      flag: "--change-check",
      summary: "propõe, inspeciona e executa uma mudança em arquivos descartáveis"
    ) { _ in
      await EvieDiagnostics.changeCheck()
    },

    // Shows which skills a question loads, and answers it with them, so
    // "she learned it" is something seen rather than assumed.
    EvieDiagnostic.terminating(
      flag: "--skill-check",
      usage: "--skill-check <pergunta>",
      summary: "mostra quais habilidades uma pergunta carrega, e responde com elas",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.skillCheck(question: arguments.value())
    },

    // Builds the index over a real folder and asks it real questions, including
    // the paraphrase kind that substring search cannot answer at all.
    EvieDiagnostic.terminating(
      flag: "--rag-check",
      usage: "--rag-check <pasta> [pergunta…]",
      summary: "indexa uma pasta e pergunta a ela, por palavra e por significado",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.ragCheck(folder: arguments.url(), questions: arguments.values(from: 1))
    },

    // Loads a cache file and says what it cost. Reads the old JSON cache too, so
    // "the index got smaller and cheaper to read" is two measurements taken with
    // the same instrument rather than an assertion about a rewrite.
    EvieDiagnostic.immediate(
      flag: "--index-check",
      usage: "--index-check [arquivo] [saída]",
      summary: "carrega o índice do vault e mede tamanho, tempo e memória"
    ) { arguments in
      let given = arguments.values()
      EvieDiagnostics.indexCheck(
        path: given.first,
        writingTo: given.count > 1 ? given[1] : nil
      )
    },

    // The flag every scheduled job passes back. `launchd` wakes this bundle,
    // this runs the one prompt, the answer goes to the history and to a banner,
    // and the process quits — nothing of Evie's is alive in between.
    //
    // Registered here rather than handled apart from the diagnostics because it
    // is the same shape: one flag, one bounded thing, then exit. It also keeps
    // the argument written into every generated plist documented in `--help`.
    EvieDiagnostic.terminating(
      flag: EvieScheduleAgent.flag,
      usage: "\(EvieScheduleAgent.flag) <id>",
      summary: "roda um agendamento agora — é isto que o launchd chama",
      requiredArguments: 1
    ) { arguments in
      await EvieDiagnostics.runSchedule(arguments.value())
    },

    // Installs a real job for the next minute and waits for it. A scheduler that
    // was never watched scheduling something is not a scheduler anybody has
    // reason to believe.
    EvieDiagnostic.terminating(
      flag: "--schedule-check",
      summary: "agenda algo para daqui a um minuto e espera o launchd disparar"
    ) { _ in
      await EvieDiagnostics.scheduleCheck()
    },

    // Says what is scheduled and whether launchd is actually holding it, which
    // are two different questions that look the same from the settings window.
    EvieDiagnostic.terminating(
      flag: "--schedules-check",
      summary: "lista os agendamentos e o que o launchd tem carregado"
    ) { _ in
      await EvieDiagnostics.schedulesCheck()
    },

    // Acted on by the coordinator once the application is up, not here — the
    // window it opens needs the running app. Listed so `--help` is the whole
    // truth about what the shell answers to.
    EvieDiagnostic(
      flag: "--open-settings",
      summary: "abre a janela de ajustes (a Evie não tem ícone no Dock)"
    ),
  ]

  /// The first diagnostic on the command line, with the arguments that follow it.
  ///
  /// Entries with no runner are skipped rather than matched, so a flag handled
  /// elsewhere in the application cannot swallow the launch.
  static func match(_ arguments: [String]) -> (diagnostic: EvieDiagnostic, arguments: EvieDiagnosticArguments)? {
    for diagnostic in all where diagnostic.run != nil {
      guard let index = arguments.firstIndex(of: diagnostic.flag),
        index + diagnostic.requiredArguments < arguments.count
      else {
        continue
      }
      return (diagnostic, EvieDiagnosticArguments(all: arguments, flagIndex: index))
    }
    return nil
  }

  /// The registry read out loud. Nothing here is written twice, so it cannot say
  /// something the shell does not do.
  static var helpText: String {
    let width = all.map(\.usage.count).max() ?? 0
    let lines = all.map { diagnostic in
      "  " + diagnostic.usage.padding(toLength: width, withPad: " ", startingAt: 0)
        + "  " + diagnostic.summary
    }
    return ([
      "evie-shell — verificações que este projeto faz em si mesmo",
      "",
      "Uso: evie-shell <flag> [argumentos]",
      "",
    ] + lines).joined(separator: "\n")
  }
}
