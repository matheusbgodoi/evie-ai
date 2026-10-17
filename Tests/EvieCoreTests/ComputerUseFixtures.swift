import CoreGraphics
import Foundation

@testable import EvieCore

/// One synthetic screen the computer-use tests act on: Mail in front, a
/// compose window with a send button, a subject field and a password field,
/// and Evie's overlay in the top-right corner.
enum ComputerUseFixture {
  static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  static let mail = ComputerAppIdentity(bundleID: "com.apple.mail", name: "Mail", processID: 501)
  static let safari = ComputerAppIdentity(
    bundleID: "com.apple.Safari",
    name: "Safari",
    processID: 502
  )
  static let finder = ComputerAppIdentity(
    bundleID: "com.apple.finder",
    name: "Finder",
    processID: 503
  )
  static let spotlight = ComputerAppIdentity(
    bundleID: "com.apple.Spotlight",
    name: "Spotlight",
    processID: 504
  )
  static let textEdit = ComputerAppIdentity(
    bundleID: "com.apple.TextEdit",
    name: "TextEdit",
    processID: 505
  )
  static let terminal = ComputerAppIdentity(
    bundleID: "com.apple.Terminal",
    name: "Terminal",
    processID: 506
  )
  static let dock = ComputerAppIdentity(bundleID: "com.apple.dock", name: "Dock", processID: 507)

  /// A 1512×982-point display sent as a 1024×665 image.
  static let frame = ScreenGeometry.ObservedFrame(
    frameInGlobalCG: CGRect(x: 0, y: 0, width: 1_512, height: 982),
    imageSize: CGSize(width: 1_024, height: 665)
  )
  /// Evie's overlay, in global points: grid x from about 794, y up to about 204.
  static let evieWindow = CGRect(x: 1_200, y: 0, width: 312, height: 200)

  static let sendButton = AXElementSummary(
    index: 0,
    role: "AXButton",
    title: "Enviar",
    box0to1000: CGRect(x: 500, y: 880, width: 60, height: 20),
    isSecure: false
  )
  static let subjectField = AXElementSummary(
    index: 1,
    role: "AXTextField",
    title: "Assunto",
    box0to1000: CGRect(x: 100, y: 100, width: 500, height: 30),
    isSecure: false
  )
  static let passwordField = AXElementSummary(
    index: 2,
    role: "AXSecureTextField",
    title: "Senha",
    box0to1000: CGRect(x: 100, y: 300, width: 300, height: 30),
    isSecure: true
  )
  static let saveButton = AXElementSummary(
    index: 3,
    role: "AXButton",
    title: "Salvar rascunho",
    box0to1000: CGRect(x: 600, y: 880, width: 80, height: 20),
    isSecure: false
  )

  static let defaultElements = [sendButton, subjectField, passwordField, saveButton]

  static func observation(
    id: String = "obs-1",
    app: ComputerAppIdentity = mail,
    elements: [AXElementSummary] = defaultElements,
    focused: Int? = 1,
    windowTitle: String? = "Nova mensagem",
    capturedAt: Date = start,
    windowFrame: CGRect? = nil,
    windows: [ComputerWindowSummary]? = nil
  ) -> ComputerObservation {
    ComputerObservation(
      id: id,
      capturedAt: capturedAt,
      displayID: 1,
      frame: frame,
      frontApp: app,
      windowTitle: windowTitle,
      elements: elements,
      focusedElementIndex: focused,
      evieWindowFrames: [evieWindow],
      windowFrame: windowFrame,
      windows: windows
    )
  }

  /// A window of `owner` on the window server's list, in global points.
  static func window(
    _ owner: ComputerAppIdentity,
    _ frame: CGRect = CGRect(x: 0, y: 0, width: 1_512, height: 982),
    layer: Int = 0
  ) -> ComputerWindowSummary {
    ComputerWindowSummary(owner: owner, frame: frame, layer: layer)
  }

  static func live(
    for observation: ComputerObservation,
    secureInput: Bool = false,
    focusedFieldIsSecure: Bool = false
  ) -> ComputerLiveState {
    ComputerLiveState(
      frontApp: observation.frontApp,
      secureInputEnabled: secureInput,
      focusedFieldIsSecure: focusedFieldIsSecure
    )
  }

  /// A one-button screen of `app`, for the app-specific rules.
  static func screen(
    of app: ComputerAppIdentity,
    button title: String = "OK",
    role: String = "AXButton",
    id: String = "obs-1",
    windows: [ComputerWindowSummary]? = nil
  ) -> ComputerObservation {
    observation(
      id: id,
      app: app,
      elements: [
        AXElementSummary(
          index: 0,
          role: role,
          title: title,
          box0to1000: CGRect(x: 400, y: 400, width: 100, height: 40),
          isSecure: false
        )
      ],
      focused: nil,
      windows: windows
    )
  }

  static func identity(_ bundleID: String, _ name: String) -> ComputerAppIdentity {
    ComputerAppIdentity(bundleID: bundleID, name: name, processID: 700)
  }

  static let policy = ComputerActionPolicy(resolver: StubAppResolver())

  /// A stand-in capture: the bytes are never decoded, only counted and sent.
  static func picture() -> EvieImagePart {
    EvieImagePart(
      mimeType: "image/jpeg",
      data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
      pixelSize: frame.imageSize,
      origin: .screenshot
    )
  }
}

/// Resolves the few names the tests use, the way the shell's resolver would:
/// a localised name or an English one, to the bundle and its display name.
struct StubAppResolver: ComputerAppResolving {
  func resolve(name: String) -> ResolvedApp? {
    let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .lowercased()
    switch key {
    case "atalhos", "shortcuts":
      return ResolvedApp(bundleID: "com.apple.shortcuts", displayName: "Atalhos")
    case "terminal":
      return ResolvedApp(bundleID: "com.apple.Terminal", displayName: "Terminal")
    case "editor de scripts", "script editor":
      return ResolvedApp(bundleID: "com.apple.ScriptEditor2", displayName: "Editor de Scripts")
    case "notas", "notes":
      return ResolvedApp(
        bundleID: "com.apple.Notes",
        displayName: "Notas",
        otherNames: ["Notes"]
      )
    case "safari":
      return ResolvedApp(bundleID: "com.apple.Safari", displayName: "Safari")
    case "calculadora", "calculator":
      return ResolvedApp(bundleID: "com.apple.calculator", displayName: "Calculadora")
    case "evie":
      return ResolvedApp(bundleID: ComputerActionPolicy.evieBundleID, displayName: "Evie")
    default:
      return nil
    }
  }
}

/// The executor's side of the contract, in the `ScriptedClient` style: it
/// observes from a script of screens, acts only on a commit the broker still
/// accepts, and records what it did.
@MainActor
final class StubComputer: EvieComputerActing {
  let broker: EvieAgentModeBroker
  /// The screens observations show, in order; the last one keeps being shown.
  var screens: [ComputerObservation] = [ComputerUseFixture.observation()]
  /// What the next action reports.
  var result = ActionResult(outcome: .changed, detail: "Feito.")
  /// Runs as each action is carried out, before it returns.
  var onPerform: (ComputerAction) -> Void = { _ in }
  private(set) var requests: [ComputerObservationRequest] = []
  private(set) var performed: [ComputerAction] = []
  /// Observations and actions in the order they happened.
  private(set) var journal: [String] = []
  private(set) var refusals: [String] = []
  private(set) var endedSucceeded: Bool?
  var live: ((ComputerObservation?) -> ComputerLiveState)?
  private var last: ComputerObservation?

  init(broker: EvieAgentModeBroker) {
    self.broker = broker
  }

  /// Each observation gets a new id, `obs-<n>`, and a picture when asked.
  func observe(_ request: ComputerObservationRequest) async throws -> ComputerObservation {
    requests.append(request)
    journal.append(request.withImage ? "observe picture" : "observe list")
    let screen = screens.count > 1 ? screens.removeFirst() : screens[0]
    let observation = ComputerObservation(
      id: "obs-\(requests.count)",
      capturedAt: screen.capturedAt,
      displayID: screen.displayID,
      frame: screen.frame,
      frontApp: screen.frontApp,
      windowTitle: screen.windowTitle,
      elements: screen.elements,
      focusedElementIndex: screen.focusedElementIndex,
      evieWindowFrames: screen.evieWindowFrames,
      windowFrame: screen.windowFrame,
      windows: screen.windows,
      image: request.withImage ? ComputerUseFixture.picture() : nil
    )
    last = observation
    return observation
  }

  func liveState() async -> ComputerLiveState {
    if let live {
      return live(last)
    }
    return ComputerLiveState(
      frontApp: last?.frontApp,
      secureInputEnabled: false,
      focusedFieldIsSecure: false
    )
  }

  func endObserving(succeeded: Bool) async {
    endedSucceeded = succeeded
  }

  func perform(_ action: ComputerAction, commit: CapabilityCommit) async throws -> ActionResult {
    do {
      try broker.validate(commit, for: action)
    } catch {
      refusals.append(error.localizedDescription)
      throw error
    }
    performed.append(action)
    journal.append("act")
    onPerform(action)
    return result
  }
}

/// A clock the broker tests move by hand.
@MainActor
final class TestClock {
  var now: Date

  init(_ now: Date = ComputerUseFixture.start) {
    self.now = now
  }

  func advance(_ seconds: TimeInterval) {
    now = now.addingTimeInterval(seconds)
  }
}
