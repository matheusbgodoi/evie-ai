import Foundation
import UserNotifications

/// How the answer reaches somebody who is not looking at the screen.
///
/// `UNUserNotificationCenter` and not `NSUserNotification`: the old class has
/// been deprecated since macOS 11 and its delivery is no longer reliable, and
/// the modern one needs no entitlement at all for local notifications — the
/// entitlement people remember (`aps-environment`) is for *push*, which arrives
/// from Apple's servers. What it does need is a real application bundle with an
/// identifier, so an Evie run from `swift build` output cannot post one, and a
/// run from `Evie.app` can even though the bundle is signed only by this Mac.
///
/// The banner is a pointer, not the answer. It carries the first lines; the
/// whole thing is in the conversation history, which is where somebody who reads
/// the banner at 8:04 goes to find out what she actually said.
@MainActor
enum EvieScheduleNotifier {
  /// A local notification needs a bundle identifier to be attributed to. Asking
  /// `UNUserNotificationCenter.current()` without one raises an Objective-C
  /// exception, which is not catchable in Swift and takes the process with it.
  static var isAvailable: Bool {
    Bundle.main.bundleIdentifier != nil
  }

  /// Asks for permission, from somewhere a person is looking.
  ///
  /// Called when a schedule is saved rather than when one fires. The first
  /// notification any application posts raises a system dialog; raising it at
  /// eight in the morning, with nobody at the keyboard, means the one run that
  /// most needed to be seen is the one that goes unanswered on screen.
  static func requestAuthorization() async -> Bool {
    guard isAvailable else {
      return false
    }
    let center = UNUserNotificationCenter.current()
    return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
  }

  /// Why a banner did or did not appear.
  ///
  /// Four outcomes and not a `Bool`, because "Evie was run from a build
  /// directory instead of an app bundle" and "the user said no to notifications"
  /// are different problems with different remedies, and a log line that reports
  /// them as the same one sends whoever reads it to the wrong place. Measured:
  /// the first is what the check reported before this distinction existed.
  enum Outcome: Equatable, Sendable {
    case posted
    case postedByScript
    case notBundled
    case denied
    case failed(String)

    var note: String {
      switch self {
      case .posted:
        "avisei na tela"
      case .postedByScript:
        "avisei na tela pelo caminho alternativo (o sistema recusa avisos assinados aqui)"
      case .notBundled:
        "não avisei na tela (esta cópia não é um app empacotado)"
      case .denied:
        "não avisei na tela (notificações desligadas para a Evie)"
      case .failed(let reason):
        "não avisei na tela (\(reason))"
      }
    }
  }

  /// Hands the banner to the system.
  ///
  /// Anything but `.posted` is worth logging and not worth stopping for: the
  /// answer is already in the history by the time this is called, so the worst
  /// case is that it is found later rather than lost.
  @discardableResult
  static func post(title: String, body: String) async -> Outcome {
    guard isAvailable else {
      return script(title: title, body: body) ? .postedByScript : .notBundled
    }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      guard await requestAuthorization() else {
        return script(title: title, body: body) ? .postedByScript : .denied
      }
    } else if settings.authorizationStatus == .denied {
      return script(title: title, body: body) ? .postedByScript : .denied
    }

    let content = UNMutableNotificationContent()
    content.title = title
    // Trimmed here rather than left to the system. macOS shows about four lines
    // of a banner and truncates the rest mid-word; cutting at a sentence keeps
    // the visible part readable.
    content.body = Self.excerpt(from: body)
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      // `nil` means deliver now. A trigger would mean asking the system to wake
      // us again later, which is a second schedule nobody asked for.
      content: content,
      trigger: nil
    )
    do {
      try await center.add(request)
      return .posted
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// The way through when the framework refuses.
  ///
  /// Measured on this Mac (Darwin 27), with the bundle signed both ad-hoc and
  /// with this project's own "Evie Dev" certificate: `requestAuthorization`
  /// throws `UNErrorDomain` 1, *"Notifications are not allowed for this
  /// application"*, and the status goes straight to denied. `add()` then reports
  /// success and nothing appears — which is the worst possible shape for a
  /// failure, since the code that trusted it would report having told the user.
  /// It is not an entitlement that is missing: the one people remember,
  /// `aps-environment`, is for push. A locally-signed application simply does
  /// not get to post here.
  ///
  /// `osascript` posts under Apple's own signed identity, which does. It costs
  /// one short-lived process, only on the path where the framework already said
  /// no, and the banner reads as coming from Script Editor rather than from
  /// Evie — a worse banner than the one we cannot have, and better than silence.
  ///
  /// Honestly stated: the exit code is what was measured, not the pixels. If
  /// this Mac is later signed by an identified developer, the framework path
  /// takes over on its own and this stops being reached.
  private static func script(title: String, body: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
      "-e",
      "display notification \(quoted(excerpt(from: body))) with title \(quoted(title))",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// An AppleScript string literal.
  ///
  /// Backslashes first, then quotes — the other order escapes the escapes. A
  /// schedule named `Ele disse "oi"` would otherwise end the literal early and
  /// the rest of the name would be read as AppleScript.
  private static func quoted(_ text: String) -> String {
    let escaped =
      text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      // A literal cannot span lines; the excerpt has already flattened the body,
      // but a name has not been through it.
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return "\"\(escaped)\""
  }

  /// How much of the answer the banner carries.
  static let excerptLength = 240

  static func excerpt(from answer: String) -> String {
    let flattened =
      answer
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      // Markdown emphasis is written for a card that renders it; in a banner it
      // is literal asterisks around the words that mattered most.
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "##", with: "")
      .trimmingCharacters(in: .whitespaces)
    guard flattened.count > excerptLength else {
      return flattened
    }
    let cut = flattened.index(flattened.startIndex, offsetBy: excerptLength)
    let head = flattened[..<cut]
    if let stop = head.lastIndex(where: { ".!?".contains($0) }) {
      return String(head[...stop])
    }
    return String(head) + "…"
  }
}
