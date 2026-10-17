import Foundation

/// Opens a file with its default app, or shows it in the Finder. The shell
/// implements it with `NSWorkspace`; the loop only ever holds this protocol.
public protocol EvieFileOpening: Sendable {
  /// Whether the system accepted the request.
  func open(_ url: URL) async -> Bool
  func reveal(_ url: URL) async -> Bool
}

/// Something Evie did to the screen rather than to a file, reported on the
/// transcript as it happens.
public struct EvieFileAction: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case opened
    case revealed
  }

  public var kind: Kind
  /// Relative to the folder, as the model spoke.
  public var path: String
  public var placeName: String

  public init(kind: Kind, path: String, placeName: String) {
    self.kind = kind
    self.path = path
    self.placeName = placeName
  }

  /// The line on the card: "Abri resumo.pdf", "Mostrei resumo.pdf no Finder".
  public var summary: String {
    let name = path.isEmpty ? placeName : (path as NSString).lastPathComponent
    switch kind {
    case .opened: return "Abri \(name)"
    case .revealed: return "Mostrei \(name) no Finder"
    }
  }
}

/// `open_file` and `reveal_in_finder`: the two actions the model may take
/// without a card, because neither changes a file (ADR 0019).
///
/// Three limits, each a refusal:
///
/// - **Inside a granted folder.** The path is resolved through the contained
///   reader (`openat`, `O_RESOLVE_BENEATH`, `O_NOFOLLOW_ANY`) before anything is
///   opened.
/// - **Nothing that runs.** An app, a script, an installer, a disk image, a
///   Terminal file, a configuration profile, a web shortcut, or any file with
///   an execute bit that is not a known document is refused by `open_file`.
///   Opening one of those is running something, and a sentence in a PDF must
///   not be able to cause that. Revealing in the Finder runs nothing, so it is
///   held only to the first limit.
/// - **On the record.** Every action is a status line while it happens and a
///   line in the transcript after (`EvieFileAction`).
public enum EvieOpenTool: String, CaseIterable, Sendable {
  case open = "open_file"
  case reveal = "reveal_in_finder"

  public static var definitions: [EvieToolDefinition] {
    let parameters = [
      EvieToolParameter(
        name: "root_id",
        type: .string,
        summary: "Identificador ou apelido da pasta, vindo de list_roots.",
        isRequired: true
      ),
      EvieToolParameter(
        name: "path",
        type: .string,
        summary: "Caminho do arquivo ou da pasta, relativo à pasta autorizada.",
        isRequired: true
      ),
    ]
    return [
      EvieToolDefinition(
        name: Self.open.rawValue,
        summary: """
          Abre um arquivo de uma pasta autorizada no app padrão do Mac (PDF no \
          Preview, Word no Pages ou no Word). Só quando ELE pedir para abrir. \
          Apps, scripts e instaladores são recusados.
          """,
        parameters: parameters
      ),
      EvieToolDefinition(
        name: Self.reveal.rawValue,
        summary: """
          Mostra um arquivo ou uma pasta no Finder, selecionado. Use quando ele \
          pedir para ver onde está.
          """,
        parameters: parameters
      ),
    ]
  }

  /// Extensions `open_file` never opens: things that run, install, mount or
  /// redirect.
  public static let refusedExtensions: Set<String> = [
    "app", "command", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "tool", "pkg",
    "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle", "xip", "terminal",
    "workflow", "wflow", "action", "shortcut", "scpt", "scptd", "applescript", "jxa", "osax",
    "py", "rb", "pl", "php", "js", "jar", "exe", "msi", "bat", "cmd", "ps1", "vbs",
    "prefpane", "kext", "plugin", "bundle", "framework", "appex", "xpc", "webloc", "inetloc",
    "url", "fileloc", "mobileconfig", "configprofile", "provisionprofile", "safariextz",
  ]

  /// Formats that are data whatever their permission bits say. Files copied
  /// from a Windows disk or a USB stick often carry an execute bit on every
  /// PDF; refusing those would refuse the ordinary case.
  public static let documentExtensions: Set<String> = [
    "pdf", "doc", "docx", "rtf", "rtfd", "odt", "pages", "txt", "text", "md", "markdown",
    "csv", "tsv", "xls", "xlsx", "numbers", "ods", "ppt", "pptx", "key", "odp", "epub",
    "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg",
    "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg",
    "aiff", "zip",
  ]

  /// Why `open_file` will not open this, or nil when it may.
  public static func refusal(forName name: String, status: EvieItemStatus) -> String? {
    let extensionName = (name as NSString).pathExtension.lowercased()
    if refusedExtensions.contains(extensionName) {
      return """
        \(name) é um app, script, instalador ou atalho — abrir isso executaria \
        alguma coisa, e isso eu não faço. Posso mostrar no Finder com \
        reveal_in_finder, e ele abre se quiser.
        """
    }
    if status.isExecutable, !documentExtensions.contains(extensionName) {
      return """
        \(name) está marcado como executável, então não abro. Posso mostrar no \
        Finder com reveal_in_finder.
        """
    }
    return nil
  }

  /// Runs one call: resolves the place, checks the limits, asks the opener.
  public static func run(
    _ call: EvieToolCall,
    roots: [EvieFileRoot],
    toolbox: EvieFileToolbox,
    opener: any EvieFileOpening
  ) async -> (result: EvieToolResult, action: EvieFileAction?) {
    func answer(_ text: String, failed: Bool = true) -> EvieToolResult {
      EvieToolResult(callID: call.id, name: call.name, content: text, isFailure: failed)
    }
    guard let tool = EvieOpenTool(rawValue: call.name) else {
      return (answer("Não existe uma ferramenta chamada \(call.name)."), nil)
    }
    let arguments = (try? call.arguments()) ?? [:]
    guard let identifier = arguments["root_id"], !identifier.isEmpty else {
      return (answer("Faltou root_id. Chame list_roots para obter os identificadores."), nil)
    }

    let root: EvieFileRoot
    switch EvieSuggestedRoot.lookup(identifier, in: roots, home: toolbox.home) {
    case .granted(let found):
      root = found
    case .notGranted(let suggestion):
      return (answer(EvieFileToolbox.notGrantedMessage(suggestion)), nil)
    case .unknown:
      return (
        answer(
          "Não existe pasta autorizada com o identificador \(identifier). Chame list_roots."
        ), nil
      )
    }

    let path = toolbox.normalise(arguments["path"] ?? "")
    let status: EvieItemStatus
    do {
      status = try toolbox.reader.status(root: root.url, relativePath: path)
    } catch let error as EvieScopedFileReader.ReaderError {
      return (answer(EvieFileToolbox.describe(error, in: root)), nil)
    } catch {
      return (answer("Não consegui completar: \(error.localizedDescription)"), nil)
    }

    let name = path.isEmpty ? root.displayName : (path as NSString).lastPathComponent
    let url = path.isEmpty ? root.url : root.url.appendingPathComponent(path)
    let action = EvieFileAction(
      kind: tool == .open ? .opened : .revealed,
      path: path,
      placeName: root.displayName
    )
    switch tool {
    case .open:
      if let refusal = refusal(forName: name, status: status) {
        return (answer(refusal), nil)
      }
      guard await opener.open(url) else {
        return (answer("O macOS não conseguiu abrir \(name)."), nil)
      }
      return (
        answer("Abri \(name) no app padrão. Diga a ele que está aberto.", failed: false),
        action
      )
    case .reveal:
      guard await opener.reveal(url) else {
        return (answer("O Finder não conseguiu mostrar \(name)."), nil)
      }
      return (answer("Mostrei \(name) no Finder, selecionado.", failed: false), action)
    }
  }
}
