import Foundation

/// Turns a schedule into the `launchd` job that fires it.
///
/// A user LaunchAgent rather than anything of Evie's own. `launchd` is already
/// running — it is what starts everything else on this Mac — so one more entry
/// costs nothing until the minute it fires, and between firings there is no
/// timer, no daemon and no process of ours alive at all. That is the whole
/// reason this feature is shaped this way; see `docs/AUTOMATIONS.md`.
///
/// Everything here is a pure function from a schedule to a property list, so
/// what gets written can be read in a test instead of being discovered at eight
/// in the morning.
public enum EvieScheduleAgent {
  /// The file the plist goes in, inside `~/Library/LaunchAgents`.
  ///
  /// `launchctl` does not require the filename to match the label, but every
  /// tool a person might use to look — `ls`, Spotlight, their own eyes — assumes
  /// it does.
  public static func fileName(forIdentifier id: String) -> String {
    EvieSchedule.label(forIdentifier: id) + ".plist"
  }

  /// Where this schedule's run writes what it printed.
  ///
  /// One file per schedule rather than one shared log, so a job that never fires
  /// is visibly distinguishable from one that fires and fails: the first has no
  /// file.
  public static func logFileName(forIdentifier id: String) -> String {
    "schedule-\(id).log"
  }

  /// The job, as a property list.
  ///
  /// - Parameter executable: the binary `launchd` should run — Evie's own, inside
  ///   the app bundle. Passed in rather than looked up so this stays a function
  ///   of its arguments.
  /// - Parameter logDirectory: where standard output and error go.
  public static func propertyList(
    for schedule: EvieSchedule,
    executable: URL,
    logDirectory: URL
  ) -> EviePropertyList {
    var job: [String: EviePropertyList] = [
      "Label": .string(schedule.label),
      // The prompt is deliberately *not* here. `~/Library/LaunchAgents` is
      // readable by anything running as this user; the prompt may say "resume
      // meus e-mails não lidos" and lives in the 0600 store instead. What
      // travels on the command line is only which schedule to run.
      "ProgramArguments": .array([
        .string(executable.path),
        .string(EvieScheduleAgent.flag),
        .string(schedule.id),
      ]),
      // False, and it matters: `bootstrap` with this true would fire the job the
      // instant a schedule was saved, which is a surprise turn against the model
      // every time somebody edits a time.
      "RunAtLoad": .boolean(false),
      // A GUI login session only. The run posts a notification and brings up an
      // NSApplication; neither means anything in a session with no user in it.
      "LimitLoadToSessionType": .string("Aqua"),
      "StandardOutPath": .string(
        logDirectory.appendingPathComponent(logFileName(forIdentifier: schedule.id)).path
      ),
      "StandardErrorPath": .string(
        logDirectory.appendingPathComponent(logFileName(forIdentifier: schedule.id)).path
      ),
      // Not a key `launchd` reads. It is here because the only other thing in
      // this file is an eight-character identifier, and somebody opening
      // `~/Library/LaunchAgents` to find out what wakes their Mac at eight
      // deserves an answer in the file rather than in another application.
      "EvieScheduleName": .string(schedule.name),
    ]

    switch schedule.trigger {
    case .daily(let hour, let minute):
      // A dictionary, not an array: `StartCalendarInterval` takes one interval
      // or a list of them, and the keys left out are the wildcards. Hour and
      // minute with no Weekday means every day.
      job["StartCalendarInterval"] = .dictionary([
        "Hour": .integer(hour),
        "Minute": .integer(minute),
      ])

    case .weekly(let weekdays, let hour, let minute):
      // One interval per chosen day. There is no "these weekdays" key —
      // repeating the time with a different `Weekday` is how `launchd` spells it.
      job["StartCalendarInterval"] = .array(
        weekdays.sorted().map { weekday in
          .dictionary([
            "Weekday": .integer(weekday),
            "Hour": .integer(hour),
            "Minute": .integer(minute),
          ])
        }
      )

    case .folder(let path):
      job["WatchPaths"] = .array([.string(path)])
      // `launchd` will start the job again as soon as it exits if the path
      // changed while it ran, and a folder gaining twenty files at once is one
      // event per file. A minute between starts turns a download burst into one
      // run instead of twenty. The default is ten seconds, which is not enough
      // for a turn that takes longer than that to finish.
      job["ThrottleInterval"] = .integer(60)
    }

    return .dictionary(job)
  }

  /// The flag the job passes back to Evie. Named here so the plist and the
  /// diagnostic that answers it cannot drift apart.
  public static let flag = "--run-schedule"
}
