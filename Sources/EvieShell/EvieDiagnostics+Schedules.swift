import EvieCore
import Foundation

/// The two flags that belong to scheduling: the one `launchd` calls, and the one
/// a person calls to see what `launchd` is holding.
extension EvieDiagnostics {
  /// Runs one schedule now. This is the flag in every generated plist.
  ///
  /// A diagnostic rather than a mode of its own because that is exactly what it
  /// is: a flag that makes the process do one bounded thing and quit. It also
  /// means `--help` lists it, so the argument in the plist is documented in the
  /// same place as everything else the shell answers to.
  static func runSchedule(_ identifier: String) async {
    await EvieScheduleRunner.run(identifier: identifier)
  }

  /// Installs a throwaway schedule for the next minute, waits for `launchd` to
  /// fire it, and reports what happened.
  ///
  /// The only way to know a scheduler works is to watch it schedule something.
  /// Everything else about this feature can be unit tested — the plist, the
  /// label, the validation — and none of it proves that `launchd` accepted the
  /// job, ran this binary, and that the run produced an answer.
  ///
  /// It borrows the real store, because that is where `--run-schedule` looks, and
  /// puts it back afterwards. The plist goes to a temporary folder rather than to
  /// `~/Library/LaunchAgents`: `bootstrap` takes a path, not a location, so a
  /// check has no business leaving a file where the user's own jobs live.
  static func scheduleCheck() async {
    setvbuf(stdout, nil, _IOLBF, 0)

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-schedule-check", isDirectory: true)
    try? FileManager.default.removeItem(at: scratch)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    let store = EvieScheduleStore()
    let existing = store.load()
    let agents = EvieLaunchAgents(directory: scratch, logDirectory: scratch)

    // The next whole minute plus one, so the check never loses a race against
    // the minute boundary it is aiming at.
    let fireAt = Date().addingTimeInterval(90)
    let parts = Calendar.current.dateComponents([.hour, .minute], from: fireAt)
    let schedule = EvieSchedule(
      name: "Verificação de agendamento",
      prompt: "Responda apenas com esta frase, sem mais nada: agendamento funcionando.",
      trigger: .daily(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    )

    print("binário: \(agents.executable.path)")
    print("empacotado: \(Bundle.main.bundleIdentifier ?? "(sem bundle — notificação não vai dar)")")
    print("plist: \(agents.plistURL(for: schedule).path)")
    print("registro: \(agents.logURL(for: schedule).path)")
    print("dispara às \(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))")
    print("")

    // Restoring the store matters more than anything printed below: this check
    // borrows the user's real file and must give it back whatever happens.
    defer {
      agents.remove(schedule)
      try? store.save(existing)
      try? FileManager.default.removeItem(at: scratch)
      print("")
      print("limpei: agendamento removido do launchd e do arquivo")
    }

    do {
      try store.save(existing + [schedule])
      try agents.install(schedule)
    } catch {
      print("NÃO INSTALOU: \(error)")
      return
    }
    print("launchd carregou: \(agents.isLoaded(schedule) ? "sim" : "NÃO")")

    let log = agents.logURL(for: schedule)
    let deadline = Date().addingTimeInterval(300)
    var reported = ""
    while Date() < deadline {
      try? await Task.sleep(for: .seconds(2))
      guard let contents = try? String(contentsOf: log, encoding: .utf8) else {
        continue
      }
      if reported.isEmpty, !contents.isEmpty {
        print(String(format: "DISPAROU — %.0f s depois de instalar", 300 - deadline.timeIntervalSinceNow))
      }
      reported = contents
      // The last thing a run prints either way.
      if contents.contains("avisei na tela") || contents.contains("FALHOU")
        || contents.contains("PULEI")
      {
        break
      }
    }

    print("")
    if reported.isEmpty {
      print("NÃO DISPAROU em 5 minutos — o registro continua vazio")
      return
    }
    print("o que a execução escreveu:")
    for line in reported.split(separator: "\n") {
      print("   \(line)")
    }
  }

  /// What is scheduled, and whether `launchd` agrees.
  ///
  /// The two can disagree — a plist written while the job was loaded, a schedule
  /// deleted from the store by hand, a job left over from a build that has since
  /// moved. Printing both sides is the only way to see which.
  static func schedulesCheck() async {
    let store = EvieScheduleStore()
    let agents = EvieLaunchAgents()
    let schedules = store.load()

    print("arquivo: \(store.fileURL.path)")
    print("agentes: \(agents.directory.path)")
    print("binário que o launchd chamaria: \(agents.executable.path)")
    print("")

    if schedules.isEmpty {
      print("nenhum agendamento guardado")
    }
    for schedule in schedules {
      let loaded = agents.isLoaded(schedule)
      let hasPlist = FileManager.default.fileExists(atPath: agents.plistURL(for: schedule).path)
      print("\(schedule.id)  \(schedule.name)")
      print("   quando: \(schedule.summary)")
      print("   ligado: \(schedule.isEnabled ? "sim" : "não")")
      print("   plist: \(hasPlist ? "existe" : "NÃO EXISTE")")
      print("   launchd: \(loaded ? "carregado" : "não carregado")")
      let log = agents.logURL(for: schedule)
      if let contents = try? String(contentsOf: log, encoding: .utf8), !contents.isEmpty {
        let lines = contents.split(separator: "\n").suffix(4)
        print("   última execução:")
        for line in lines {
          print("      \(line)")
        }
      } else {
        print("   última execução: (nunca rodou)")
      }
      print("")
    }

    // Files with no schedule behind them. These are the ones that wake the Mac
    // to do nothing, and nothing in the interface would ever show them.
    let known = Set(schedules.map(\.id))
    let orphans = agents.installedIdentifiers().filter { !known.contains($0) }
    if !orphans.isEmpty {
      print("plists sem agendamento correspondente: \(orphans.joined(separator: ", "))")
      print("abra Ajustes › Automações para limpá-los")
    }
  }
}
