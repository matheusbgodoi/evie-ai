import Foundation
import UniformTypeIdentifiers

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
/// - **Only documents.** `open_file` opens a regular file whose kind is on an
///   allowlist — the known document extensions, or a PDF, image, audio, video
///   or plain-text type that is none of executable, bundle, package,
///   application, script, source code or web content — and nothing else. Web
///   documents (HTML, SVG, XML, web archives) are reveal-only. A list of what to refuse always misses the
///   next launcher type (`.terminal`, `.workflow`, `.saver`, `.xpc`…), and a
///   sentence in a PDF must not be able to run anything. Folders, bundles and
///   packages are never opened, only revealed; a file with an execute bit that
///   is not a known document is refused too. Revealing in the Finder runs
///   nothing, so it is held only to the first limit.
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

  /// Extensions refused even if their type looked like content: things that
  /// run, install, mount or redirect. A second fence behind the allowlist,
  /// never the only one.
  public static let refusedExtensions: Set<String> = [
    "app", "command", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "tool", "pkg",
    "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle", "xip", "terminal",
    "workflow", "wflow", "action", "shortcut", "scpt", "scptd", "applescript", "jxa", "osax",
    "py", "rb", "pl", "php", "js", "jar", "exe", "msi", "bat", "cmd", "ps1", "vbs",
    "prefpane", "saver", "kext", "plugin", "bundle", "framework", "appex", "xpc", "webloc",
    "inetloc", "url", "fileloc", "mobileconfig", "configprofile", "provisionprofile",
    "safariextz",
  ]

  /// Web documents: a browser runs the script inside them, so they are never
  /// opened — only revealed. SVG is an image to `UTType` and still a web page
  /// to Safari, which is why the image fallback below cannot admit it.
  public static let webExtensions: Set<String> = [
    "html", "htm", "xhtml", "xht", "shtml", "svg", "svgz", "xml", "xsl", "xslt",
    "webarchive", "mht", "mhtml", "php", "asp", "aspx", "jsp",
  ]

  /// The documents `open_file` opens by extension. Files copied from a Windows
  /// disk or a USB stick often carry an execute bit on every PDF; these open
  /// whatever their permission bits say.
  public static let documentExtensions: Set<String> = [
    "pdf", "doc", "docx", "rtf", "odt", "txt", "text", "md", "markdown",
    "csv", "tsv", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "epub",
    "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
    "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aac", "flac", "ogg",
    "aiff",
  ]

  /// The only types the fallback admits, for an extension not listed above:
  /// a PDF, an image, audio or video, plain text.
  static let admittedTypes: [UTType] = [.pdf, .image, .audiovisualContent, .plainText]

  /// Types that disqualify a file whatever else it conforms to.
  static let disqualifyingTypes: [UTType] = [
    .executable, .bundle, .package, .application, .script, .shellScript, .unixExecutable,
    .applicationBundle, .applicationExtension, .pluginBundle, .systemPreferencesPane,
    .html, .xml, .webArchive, .svg, .sourceCode,
  ]

  /// Whether a regular file's type is one `open_file` may open: a known
  /// document, or — for an extension not listed — a PDF, image, audio, video or
  /// plain-text type that is none of the disqualifying ones. There is no
  /// open-ended fallback: `public.content` admits HTML, SVG and web archives,
  /// which a browser would run.
  public static func isOpenableDocument(_ name: String) -> Bool {
    let extensionName = (name as NSString).pathExtension.lowercased()
    guard !extensionName.isEmpty, !refusedExtensions.contains(extensionName),
      !webExtensions.contains(extensionName)
    else {
      return false
    }
    if documentExtensions.contains(extensionName) {
      return true
    }
    guard let type = UTType(filenameExtension: extensionName),
      admittedTypes.contains(where: { type.conforms(to: $0) })
    else {
      return false
    }
    return !disqualifyingTypes.contains { type.conforms(to: $0) }
  }

  /// Why `open_file` will not open this, or nil when it may.
  public static func refusal(forName name: String, status: EvieItemStatus) -> String? {
    if status.isDirectory {
      return """
        \(name) é uma pasta, um app ou um pacote, e isso eu não abro. Posso mostrar \
        no Finder com reveal_in_finder.
        """
    }
    guard isOpenableDocument(name) else {
      return """
        \(name) não é um documento que eu abra — pode ser um app, um script, um \
        instalador ou um atalho, e abrir isso executaria alguma coisa. Posso \
        mostrar no Finder com reveal_in_finder, e ele abre se quiser.
        """
    }
    let extensionName = (name as NSString).pathExtension.lowercased()
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
