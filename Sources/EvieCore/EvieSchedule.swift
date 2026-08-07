import Foundation

/// One thing Evie does on her own: a question, and when to ask it.
///
/// The record is deliberately small. A schedule is a prompt plus a trigger, and
/// the answer is produced by the same path a typed question takes — so there is
/// nothing here about tools, folders or the web. Whatever she can do when asked
/// at the keyboard, she can do at eight in the morning, and whatever she cannot
/// do then she cannot do now either.
public struct EvieSchedule: Identifiable, Codable, Hashable, Sendable {
  /// A ceiling, so a runaway loop in some future feature cannot fill
  /// `~/Library/LaunchAgents` with jobs the user never asked for.
  public static let maximumSchedules = 24
  public static let maximumNameLength = 80
  /// Long enough for a paragraph of instructions, short enough that the file
  /// stays something a person can read.
  public static let maximumPromptLength = 2_000

  /// Stable for the life of the schedule, because it is what `launchd` knows the
  /// job by. Renaming a schedule must not orphan a loaded job.
  public let id: String
  public var name: String
  public var prompt: String
  public var trigger: EvieScheduleTrigger
  /// Off means the plist is removed and the job unloaded — not a flag the run
  /// checks. A disabled schedule that `launchd` still holds would wake the app
  /// at eight to do nothing, which is exactly the resident cost this design
  /// exists to avoid.
  public var isEnabled: Bool
  public var createdAt: Date

  public init(
    id: String = EvieSchedule.makeIdentifier(),
    name: String,
    prompt: String,
    trigger: EvieScheduleTrigger,
    isEnabled: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
    self.trigger = trigger
    self.isEnabled = isEnabled
    self.createdAt = createdAt
  }

  /// Eight lowercase hex characters, the same shape `EvieFileRoot` uses.
  ///
  /// Short because it is read out of a filename by a person looking for which
  /// job is which, and hex because the identifier ends up in a path, in a
  /// `launchd` label, and on a command line — three places where a stray slash
  /// or space would be somebody else's bug to find.
  public static func makeIdentifier() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
  }

  /// What `launchd` calls this job, for its whole life.
  ///
  /// Namespaced under the bundle identifier because the label is global to the
  /// user's session: two jobs with the same label are the same job, and a label
  /// like `evie.8` would collide with anything else careless.
  public var label: String {
    Self.label(forIdentifier: id)
  }

  public static func label(forIdentifier id: String) -> String {
    "com.matheusbgodoi.evie.schedule.\(id)"
  }

  public enum ValidationFailure: Error, Equatable, Sendable {
    case identifierIsNotSafe
    case nameIsEmpty
    case nameIsTooLong
    case promptIsEmpty
    case promptIsTooLong
    case triggerIsInvalid(EvieScheduleTrigger.ValidationFailure)
  }

  /// Checked before anything is written, because everything downstream of a
  /// schedule is a file path, a plist and a process argument.
  public func validate() throws {
    // The identifier reaches a filename in `~/Library/LaunchAgents` and an
    // argument passed to `launchctl`. A hand-edited `../../something` in the
    // store would otherwise write a plist wherever it liked.
    guard id.count == 8, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      throw ValidationFailure.identifierIsNotSafe
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw ValidationFailure.nameIsEmpty
    }
    guard trimmedName.count <= Self.maximumNameLength else {
      throw ValidationFailure.nameIsTooLong
    }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      throw ValidationFailure.promptIsEmpty
    }
    guard trimmedPrompt.count <= Self.maximumPromptLength else {
      throw ValidationFailure.promptIsTooLong
    }
    do {
      try trigger.validate()
    } catch let failure as EvieScheduleTrigger.ValidationFailure {
      throw ValidationFailure.triggerIsInvalid(failure)
    }
  }

  /// The trigger in one line, for the row in Settings.
  public var summary: String {
    trigger.summary
  }
}

/// When a schedule runs: a clock, or a folder that changed.
///
/// These two and no others, because these two are what `launchd` can do without
/// anything of Evie's being alive in between. A trigger that needed something
/// listening would need a daemon, and there is not going to be a daemon.
public enum EvieScheduleTrigger: Hashable, Sendable {
  /// Every day at this hour and minute.
  case daily(hour: Int, minute: Int)
  /// On these weekdays at this hour and minute. `0` is Sunday, `6` Saturday.
  case weekly(weekdays: [Int], hour: Int, minute: Int)
  /// When anything at this path changes. A folder, normally.
  case folder(path: String)

  public enum ValidationFailure: Error, Equatable, Sendable {
    case hourOutOfRange
    case minuteOutOfRange
    case noWeekdaysChosen
    case weekdayOutOfRange
    case pathIsEmpty
    case pathIsNotAbsolute
  }

  public func validate() throws {
    switch self {
    case .daily(let hour, let minute):
      try Self.validateTime(hour: hour, minute: minute)
    case .weekly(let weekdays, let hour, let minute):
      try Self.validateTime(hour: hour, minute: minute)
      guard !weekdays.isEmpty else {
        throw ValidationFailure.noWeekdaysChosen
      }
      // 7 is also Sunday to `launchd`, but allowing both spellings would mean
      // two schedules that look different and fire together.
      guard weekdays.allSatisfy({ (0...6).contains($0) }) else {
        throw ValidationFailure.weekdayOutOfRange
      }
    case .folder(let path):
      guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ValidationFailure.pathIsEmpty
      }
      // `WatchPaths` takes absolute paths only; a relative one silently watches
      // nothing, which looks exactly like a schedule that never fires.
      guard path.hasPrefix("/") else {
        throw ValidationFailure.pathIsNotAbsolute
      }
    }
  }

  private static func validateTime(hour: Int, minute: Int) throws {
    guard (0...23).contains(hour) else {
      throw ValidationFailure.hourOutOfRange
    }
    guard (0...59).contains(minute) else {
      throw ValidationFailure.minuteOutOfRange
    }
  }

  public var summary: String {
    switch self {
    case .daily(let hour, let minute):
      "Todo dia às \(Self.clock(hour, minute))"
    case .weekly(let weekdays, let hour, let minute):
      "\(Self.weekdayNames(weekdays)) às \(Self.clock(hour, minute))"
    case .folder(let path):
      "Quando algo mudar em \(URL(fileURLWithPath: path).lastPathComponent)"
    }
  }

  private static func clock(_ hour: Int, _ minute: Int) -> String {
    String(format: "%02d:%02d", hour, minute)
  }

  /// Portuguese, abbreviated, in week order however the days were stored — a
  /// list reading "sáb, seg" is a list somebody has to re-sort in their head.
  private static func weekdayNames(_ weekdays: [Int]) -> String {
    let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
    let chosen = Set(weekdays)
    guard !chosen.isEmpty else {
      return "Nunca"
    }
    if chosen == Set(0...6) {
      return "Todo dia"
    }
    return (0...6).filter { chosen.contains($0) }.map { names[$0] }.joined(separator: ", ")
  }
}

extension EvieScheduleTrigger: Codable {
  // Written by hand rather than synthesised. Swift's synthesis for an enum with
  // associated values produces a nested shape keyed by the case name, which is
  // both ugly to hand-edit and tied to the Swift case names — renaming a case
  // would silently orphan every schedule already on disk.
  private enum CodingKeys: String, CodingKey {
    case kind
    case hour
    case minute
    case weekdays
    case path
  }

  private enum Kind: String, Codable {
    case daily
    case weekly
    case folder
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .daily:
      self = .daily(
        hour: try container.decode(Int.self, forKey: .hour),
        minute: try container.decode(Int.self, forKey: .minute)
      )
    case .weekly:
      self = .weekly(
        weekdays: try container.decode([Int].self, forKey: .weekdays),
        hour: try container.decode(Int.self, forKey: .hour),
        minute: try container.decode(Int.self, forKey: .minute)
      )
    case .folder:
      self = .folder(path: try container.decode(String.self, forKey: .path))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .daily(let hour, let minute):
      try container.encode(Kind.daily, forKey: .kind)
      try container.encode(hour, forKey: .hour)
      try container.encode(minute, forKey: .minute)
    case .weekly(let weekdays, let hour, let minute):
      try container.encode(Kind.weekly, forKey: .kind)
      try container.encode(weekdays.sorted(), forKey: .weekdays)
      try container.encode(hour, forKey: .hour)
      try container.encode(minute, forKey: .minute)
    case .folder(let path):
      try container.encode(Kind.folder, forKey: .kind)
      try container.encode(path, forKey: .path)
    }
  }
}
