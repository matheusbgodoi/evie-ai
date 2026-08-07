import AppKit
import Foundation

/// One command-line check: the flag that selects it, what it does, and how to
/// run it.
///
/// This project verifies things by measuring them, and these flags are how it
/// measures. They used to be a wall of `if` statements at the top of
/// `applicationDidFinishLaunching`, which had two costs. The entry point of the
/// application was mostly not about launching the application. And `--help` was
/// impossible to write honestly: it would have needed a second list of flags,
/// kept by hand, that would be wrong the first time somebody added a check and
/// forgot it. Declaring each one here means the help text is the registry read
/// out loud, so it cannot drift.
struct EvieDiagnostic {
  /// Called on the main actor once the flag has matched.
  ///
  /// What it does about quitting is its own business: most checks terminate when
  /// they are done, and `--presentation-check` has to keep a coordinator alive
  /// while it works.
  typealias Run = @MainActor (EvieDiagnosticArguments, AppDelegate) -> Void

  let flag: String
  /// How the flag is written, arguments included, for `--help`.
  let usage: String
  /// One line, in the same voice as the output the check itself prints.
  let summary: String
  /// How many arguments must follow the flag for it to count as present.
  ///
  /// A flag written without them does not match, and the application launches
  /// normally — exactly what the hand-written `index + 1 < count` guards did
  /// before this type existed. Keeping that is not pedantry: `--read` with no
  /// path used to open the overlay, and a person who mistypes a flag should not
  /// get a different failure than they used to.
  let requiredArguments: Int
  /// `nil` for a flag that is documented here but acted on somewhere else.
  /// `--help` lists it; matching skips it, so it can never shadow a real check.
  let run: Run?

  init(
    flag: String,
    usage: String? = nil,
    summary: String,
    requiredArguments: Int = 0,
    run: Run? = nil
  ) {
    self.flag = flag
    self.usage = usage ?? flag
    self.summary = summary
    self.requiredArguments = requiredArguments
    self.run = run
  }

  /// A check that answers straight away, without a task, and then quits.
  static func immediate(
    flag: String,
    usage: String? = nil,
    summary: String,
    requiredArguments: Int = 0,
    body: @escaping @MainActor (EvieDiagnosticArguments) -> Void
  ) -> EvieDiagnostic {
    EvieDiagnostic(
      flag: flag,
      usage: usage,
      summary: summary,
      requiredArguments: requiredArguments
    ) { arguments, _ in
      body(arguments)
      NSApp.terminate(nil)
    }
  }

  /// A check that runs as a task and quits when it returns.
  ///
  /// The task is explicitly `@MainActor` because that is the context these ran in
  /// before, inheriting it from `applicationDidFinishLaunching`. Anything the
  /// body calls that is not main-actor isolated hops off on its own, as it did.
  static func terminating(
    flag: String,
    usage: String? = nil,
    summary: String,
    requiredArguments: Int = 0,
    body: @escaping @MainActor (EvieDiagnosticArguments) async -> Void
  ) -> EvieDiagnostic {
    EvieDiagnostic(
      flag: flag,
      usage: usage,
      summary: summary,
      requiredArguments: requiredArguments
    ) { arguments, _ in
      Task { @MainActor in
        await body(arguments)
        NSApp.terminate(nil)
      }
    }
  }
}

/// Where the checks themselves live, split across files by subject.
///
/// Main-actor isolated as a whole, which is the isolation these had as static
/// methods on the app delegate — a `@MainActor` class isolates its statics too.
/// It is load-bearing rather than incidental: several of them touch the window,
/// the microphone, or the wake listener, all of which are main-actor bound, and
/// they hold the main actor for tens of seconds while they measure. Nothing else
/// is running at the time; a diagnostic is the only thing the process is doing.
@MainActor
enum EvieDiagnostics {
  /// Writes a report to `~/Library/Logs/Evie`.
  ///
  /// The checks that open the microphone or drive the overlay can only be run
  /// from a real app bundle, and a bundle launched by Launch Services has no
  /// standard output anyone can read. A file is the only way to get the result
  /// back out. Failures are swallowed on purpose: a check that has already done
  /// its measuring must not report a logging problem as if it were the finding.
  static func writeLog(_ lines: [String], named name: String) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").appending("\n").write(
      to: directory.appendingPathComponent(name),
      atomically: true,
      encoding: .utf8
    )
  }
}

/// What was written on the command line after the flag.
///
/// The whole argument list is carried rather than a pre-cut slice, because a few
/// checks read the tail of the line (`--media-check` takes any number of files)
/// and one reads an unrelated flag from elsewhere on it (`--gated-first`).
struct EvieDiagnosticArguments {
  let all: [String]
  /// Where the flag itself sits in `all`.
  let flagIndex: Int

  /// The argument `offset` places after the flag.
  ///
  /// Safe to call for any offset below the check's `requiredArguments`: matching
  /// already refused the flag if they were not all there.
  func value(_ offset: Int = 0) -> String {
    all[flagIndex + 1 + offset]
  }

  func url(_ offset: Int = 0) -> URL {
    URL(fileURLWithPath: value(offset))
  }

  /// A number written after the flag, when there is one and it parses.
  func number(_ offset: Int = 0) -> Double? {
    let index = flagIndex + 1 + offset
    guard index < all.count else { return nil }
    return Double(all[index])
  }

  /// Everything from `offset` places after the flag to the end of the line,
  /// which is empty when the line stopped earlier.
  func values(from offset: Int = 0) -> [String] {
    let index = flagIndex + 1 + offset
    guard index < all.count else { return [] }
    return Array(all[index...])
  }

  /// Whether some other flag appears anywhere on the line.
  func contains(_ flag: String) -> Bool {
    all.contains(flag)
  }
}
