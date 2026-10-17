import Foundation

/// A macOS privacy permission the first-run guide asks for.
///
/// Five, not six. Input Monitoring is not one: the computer-use takeover
/// monitor uses `NSEvent` monitors, which the 0xE71E tag was measured to reach
/// (2026-10-16), so it needs no listen-only event tap — and asking for a
/// permission nothing uses is how a checklist teaches people to click
/// "Permitir" without reading.
public enum EviePermission: String, CaseIterable, Codable, Sendable {
  case microphone
  case speechRecognition = "speech_recognition"
  case screenRecording = "screen_recording"
  case accessibility
  case postEvents = "post_events"

  public var title: String {
    switch self {
    case .microphone: "Microfone"
    case .speechRecognition: "Reconhecimento de fala"
    case .screenRecording: "Gravação de tela"
    case .accessibility: "Acessibilidade"
    case .postEvents: "Controlar o teclado e o mouse"
    }
  }

  /// Why Evie wants it, in the words the guide shows next to the button. Kept
  /// next to the Info.plist usage strings in spirit: it says when, not only what.
  public var purpose: String {
    switch self {
    case .microphone:
      "Só abre quando você aciona a fala, e o áudio não sai deste Mac."
    case .speechRecognition:
      "Transcreve sua fala localmente, neste Mac."
    case .screenRecording:
      "Ela vê sua tela só quando você pede, para responder sobre ela ou agir por você."
    case .accessibility:
      "Lê os botões e campos da janela da frente quando você pede para ela agir."
    case .postEvents:
      "Clica e digita por você, só depois de você pedir, e você pode parar com Esc."
    }
  }

  /// Something the user has to do after allowing it, or nil.
  ///
  /// Only Screen Recording has one: a running process keeps the answer it got
  /// at launch, so a grant made in System Settings takes effect only when Evie is
  /// opened again.
  public var hint: String? {
    switch self {
    case .screenRecording:
      "Depois de permitir em Ajustes, reabra a Evie: o macOS só aplica essa permissão a quem abre de novo."
    case .microphone, .speechRecognition, .accessibility, .postEvents:
      nil
    }
  }

  /// The Privacy & Security pane that holds this permission's switch.
  ///
  /// Posting events has no pane of its own: macOS lists it under Accessibility,
  /// which is also where `CGRequestPostEventAccess` sends the user.
  public var settingsURL: URL {
    let anchor =
      switch self {
      case .microphone: "Privacy_Microphone"
      case .speechRecognition: "Privacy_SpeechRecognition"
      case .screenRecording: "Privacy_ScreenCapture"
      case .accessibility, .postEvents: "Privacy_Accessibility"
      }
    // Force-unwrapped because the string is a constant built from constants; a
    // typo here is a programming error, not a runtime condition.
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
  }
}

/// What macOS says about a permission right now.
public enum EviePermissionStatus: Sendable, Equatable {
  case granted
  /// Never asked. Only APIs with a three-way answer can report this.
  case notDetermined
  /// Asked and refused, or restricted by the system.
  case denied
  /// Not granted, from an API that answers only yes or no —
  /// `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`,
  /// `CGPreflightPostEventAccess`. A refusal and a question never asked look
  /// the same, so whether Evie already asked comes from `PermissionGuideRecord`.
  case notGranted
}

/// One line of the first-run checklist.
///
/// Plain data so the shell can draw every row the same way and the decisions
/// about what each row offers can be tested here. A row that is not a system
/// permission — the gateway key, the brain's connection test — is built by its
/// own factory (`EviePermissionGuide+Brain.swift`) and drawn by the same view.
public struct PermissionGuideRow: Identifiable, Sendable, Equatable {
  /// What the row's symbol says. Three distinct shapes, so colour is never the
  /// only signal.
  public enum Mark: Sendable, Equatable {
    case satisfied
    case pending
    case refused
  }

  public struct Action: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
      /// Show the system prompt.
      case request
      /// macOS will not prompt again; only the switch in System Settings can
      /// change the answer.
      case openSettings(URL)
      /// Copy the PC configuration's key into Evie's own Keychain item. Shows
      /// the macOS prompt for that item, not a privacy prompt.
      case importPCKey
      /// Run Testar conexão on the brain in use. Asks the network, not macOS.
      case testConnection
    }

    public let title: String
    public let kind: Kind

    public init(title: String, kind: Kind) {
      self.title = title
      self.kind = kind
    }
  }

  public let id: String
  public let title: String
  public let detail: String
  public let hint: String?
  public let mark: Mark
  public let statusText: String
  public let action: Action?

  public init(
    id: String,
    title: String,
    detail: String,
    hint: String?,
    mark: Mark,
    statusText: String,
    action: Action?
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.hint = hint
    self.mark = mark
    self.statusText = statusText
    self.action = action
  }

  /// The row for a system permission.
  ///
  /// "Pedir" is offered only while asking can still show a prompt. macOS shows
  /// each of these prompts once; after that the request call returns at once
  /// and does nothing, so a second "Pedir" would be a button that silently
  /// fails. From then on the row offers the pane in System Settings instead.
  public static func permission(
    _ permission: EviePermission,
    status: EviePermissionStatus,
    alreadyRequested: Bool
  ) -> PermissionGuideRow {
    let request = Action(title: "Pedir", kind: .request)
    let openSettings = Action(title: "Abrir Ajustes", kind: .openSettings(permission.settingsURL))

    let mark: Mark
    let statusText: String
    let action: Action?
    switch status {
    case .granted:
      (mark, statusText, action) = (.satisfied, "Permitido", nil)
    case .notDetermined:
      (mark, statusText, action) = (.pending, "Ainda não pedido", request)
    case .denied:
      (mark, statusText, action) = (.refused, "Negado", openSettings)
    case .notGranted where alreadyRequested:
      (mark, statusText, action) = (.refused, "Não permitido", openSettings)
    case .notGranted:
      (mark, statusText, action) = (.pending, "Ainda não pedido", request)
    }

    return PermissionGuideRow(
      id: permission.rawValue,
      title: permission.title,
      detail: permission.purpose,
      hint: permission.hint,
      mark: mark,
      statusText: statusText,
      action: action
    )
  }
}

/// What the guide remembers between launches: whether it was closed once, and
/// which yes-or-no permissions were already requested.
public struct PermissionGuideRecord: Equatable, Sendable {
  /// The guide opens by itself until it has been closed once. After that it is
  /// reached from Settings.
  public var dismissed: Bool
  public var requested: Set<EviePermission>

  public init(dismissed: Bool = false, requested: Set<EviePermission> = []) {
    self.dismissed = dismissed
    self.requested = requested
  }
}

/// Reads and writes the guide's record, next to `preferences.json`.
///
/// Its own small file rather than a field in the preferences: what the guide
/// remembers is a fact about this Mac's TCC database, not a comfort setting,
/// and a damaged preferences file must not make the guide reappear or vanish.
/// Every failure resolves to a fresh record, because the worst outcome of that
/// is seeing the checklist once more.
public struct PermissionGuideStore: Sendable {
  public static let supportedSchemaVersion = 1

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() -> PermissionGuideRecord {
    guard
      let data = try? Data(contentsOf: fileURL),
      let document = try? JSONDecoder().decode(Document.self, from: data),
      document.schemaVersion == Self.supportedSchemaVersion
    else {
      return PermissionGuideRecord()
    }
    // Names a newer build wrote and this one does not know are dropped rather
    // than failing the whole file.
    return PermissionGuideRecord(
      dismissed: document.dismissed,
      requested: Set(document.requested.compactMap(EviePermission.init(rawValue:)))
    )
  }

  public func save(_ record: PermissionGuideRecord) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let document = Document(
      schemaVersion: Self.supportedSchemaVersion,
      dismissed: record.dismissed,
      requested: record.requested.map(\.rawValue).sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(document)
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private struct Document: Codable {
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case dismissed
      case requested
    }

    let schemaVersion: Int
    let dismissed: Bool
    let requested: [String]
  }
}
