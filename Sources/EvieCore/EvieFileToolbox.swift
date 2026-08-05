import Foundation

/// The read-only tools Evie may use on the granted folders.
///
/// Every tool here observes; none of them change anything. That is a deliberate
/// boundary rather than a stage: a document, a filename, or a web page can say
/// "apague os backups", and the only durable defence is that no function capable
/// of it was ever declared. Anything that writes will arrive as a proposal the
/// user confirms, and will still not live in this type.
///
/// The model never sees a filesystem path. It is given opaque root identifiers
/// and speaks in paths relative to them, so a path it was not handed is a path it
/// cannot name.
public struct EvieFileToolbox: Sendable {
  /// How deep a search descends. Four levels covers `Downloads/projeto/docs/x`
  /// and stops a search in a home folder from walking a whole disk.
  public static let maximumSearchDepth = 4
  /// A ceiling on work per search, so a folder with a hundred thousand files
  /// costs a bounded amount of time.
  public static let maximumSearchVisits = 4_000
  public static let maximumSearchResults = 20

  public var reader: EvieScopedFileReader

  public init(reader: EvieScopedFileReader = EvieScopedFileReader()) {
    self.reader = reader
  }

  public enum ToolName: String, CaseIterable, Sendable {
    case listRoots = "list_roots"
    case listFolder = "list_folder"
    case readFile = "read_file"
    case searchFiles = "search_files"
    case fileInfo = "file_info"
  }

  /// What the model is told it can do.
  ///
  /// The descriptions are written for a 26B model: they say when to call the
  /// tool, not only what it does, and they state the one rule the model gets
  /// wrong without being told — that identifiers come from `list_roots` and are
  /// never invented.
  public static var definitions: [EvieToolDefinition] {
    [
      EvieToolDefinition(
        name: ToolName.listRoots.rawValue,
        summary: """
          Lista as pastas que o Matheus autorizou, com o identificador de cada \
          uma. Chame primeiro, sempre: nenhuma outra ferramenta funciona sem um \
          identificador vindo daqui.
          """,
        parameters: []
      ),
      EvieToolDefinition(
        name: ToolName.listFolder.rawValue,
        summary: """
          Mostra o que existe dentro de uma pasta autorizada. Use para descobrir \
          quais arquivos existem antes de ler qualquer um.
          """,
        parameters: [
          EvieToolParameter(
            name: "root_id",
            type: .string,
            summary: "Identificador da pasta, vindo de list_roots.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "path",
            type: .string,
            summary: """
              Subpasta, relativa à pasta autorizada. Deixe vazio para ver a raiz.
              """
          ),
        ]
      ),
      EvieToolDefinition(
        name: ToolName.readFile.rawValue,
        summary: """
          Lê o texto de um arquivo dentro de uma pasta autorizada. Só funciona \
          com arquivos de texto, e devolve no máximo o começo de arquivos longos.
          """,
        parameters: [
          EvieToolParameter(
            name: "root_id",
            type: .string,
            summary: "Identificador da pasta, vindo de list_roots.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "path",
            type: .string,
            summary: "Caminho do arquivo, relativo à pasta autorizada.",
            isRequired: true
          ),
        ]
      ),
      EvieToolDefinition(
        name: ToolName.searchFiles.rawValue,
        summary: """
          Procura arquivos e pastas cujo nome contenha um trecho, dentro de uma \
          pasta autorizada. Use quando o Matheus souber o nome mas não onde está.
          """,
        parameters: [
          EvieToolParameter(
            name: "root_id",
            type: .string,
            summary: "Identificador da pasta, vindo de list_roots.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "query",
            type: .string,
            summary: "Trecho do nome procurado. Maiúsculas e acentos não importam.",
            isRequired: true
          ),
        ]
      ),
      EvieToolDefinition(
        name: ToolName.fileInfo.rawValue,
        summary: """
          Tamanho e data de modificação de um arquivo ou pasta, sem abrir o \
          conteúdo. Use quando a pergunta for sobre quando algo mudou ou o quanto \
          ocupa.
          """,
        parameters: [
          EvieToolParameter(
            name: "root_id",
            type: .string,
            summary: "Identificador da pasta, vindo de list_roots.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "path",
            type: .string,
            summary: "Caminho do arquivo, relativo à pasta autorizada.",
            isRequired: true
          ),
        ]
      ),
    ]
  }

  /// Runs one call and produces the result to hand back.
  ///
  /// Never throws. A failure the model can read — a wrong identifier, a file that
  /// is not there — is worth more than an exception, because the model can
  /// correct itself from a sentence and cannot from silence.
  public func execute(_ call: EvieToolCall, roots: [EvieFileRoot]) -> EvieToolResult {
    guard let tool = ToolName(rawValue: call.name) else {
      return failure(call, "Não existe uma ferramenta chamada \(call.name).")
    }

    let arguments: [String: String]
    do {
      arguments = try call.arguments()
    } catch {
      return failure(call, "Os argumentos vieram malformados. Tente de novo, com JSON válido.")
    }

    switch tool {
    case .listRoots:
      return listRoots(call, roots: roots)
    case .listFolder:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try listFolder(root: root, path: arguments["path"] ?? "")
      }
    case .readFile:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try readFile(root: root, path: arguments["path"] ?? "")
      }
    case .searchFiles:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try searchFiles(root: root, query: arguments["query"] ?? "")
      }
    case .fileInfo:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try fileInfo(root: root, path: arguments["path"] ?? "")
      }
    }
  }
}

extension EvieFileToolbox {
  fileprivate func listRoots(_ call: EvieToolCall, roots: [EvieFileRoot]) -> EvieToolResult {
    guard !roots.isEmpty else {
      return success(
        call,
        """
        Nenhuma pasta autorizada ainda. Diga ao Matheus para abrir Configurações \
        > Pastas e escolher quais você pode ver.
        """
      )
    }

    let lines = roots.map { "\($0.id)  \($0.displayName)" }
    return success(call, "Pastas autorizadas (id e nome):\n" + lines.joined(separator: "\n"))
  }

  fileprivate func listFolder(root: EvieFileRoot, path: String) throws -> String {
    let listing = try reader.list(root: root.url, relativePath: normalise(path))
    guard !listing.entries.isEmpty else {
      return "A pasta \(label(root: root, path: path)) está vazia."
    }

    var lines = listing.entries.map { entry in
      entry.isDirectory
        ? "\(entry.name)/"
        : "\(entry.name)  \(describeSize(entry.byteSize))"
    }
    if listing.hasMore {
      lines.append("… e mais itens além dos \(listing.entries.count) primeiros.")
    }
    if listing.withheldCount > 0 {
      lines.append(
        "\(listing.withheldCount) item(ns) omitido(s) por serem credenciais ou chaves."
      )
    }
    return "Em \(label(root: root, path: path)):\n" + lines.joined(separator: "\n")
  }

  fileprivate func readFile(root: EvieFileRoot, path: String) throws -> String {
    let excerpt = try reader.read(root: root.url, relativePath: normalise(path))
    let header =
      excerpt.isTruncated
      ? "Começo de \(path) (\(describeSize(excerpt.byteSize)) no total, cortado):"
      : "Conteúdo de \(path):"
    return header + "\n" + excerpt.text
  }

  fileprivate func fileInfo(root: EvieFileRoot, path: String) throws -> String {
    let normalised = normalise(path)
    guard !normalised.isEmpty else {
      return "\(root.displayName) é a própria pasta autorizada."
    }

    let name = (normalised as NSString).lastPathComponent
    let parent = (normalised as NSString).deletingLastPathComponent
    // Asked through a listing of the parent rather than a new syscall path, so
    // containment stays enforced in exactly one place.
    let listing = try reader.list(root: root.url, relativePath: parent)
    guard let entry = listing.entries.first(where: { $0.name == name }) else {
      throw EvieScopedFileReader.ReaderError.notFound(path)
    }

    var parts = [entry.isDirectory ? "pasta" : "arquivo"]
    if !entry.isDirectory {
      parts.append(describeSize(entry.byteSize))
    }
    if let modified = entry.modifiedAt {
      parts.append("modificado em \(Self.dateFormatter.string(from: modified))")
    }
    return "\(path): " + parts.joined(separator: ", ")
  }

  /// Walks the granted folder looking for names that contain the query.
  ///
  /// Bounded in three directions at once — depth, items visited, and results —
  /// because the folder the user granted may be their home, and an unbounded walk
  /// there would take minutes and return more than a model can read.
  fileprivate func searchFiles(root: EvieFileRoot, query: String) throws -> String {
    let needle = Self.fold(query)
    guard !needle.isEmpty else {
      return "Preciso de um trecho de nome para procurar."
    }

    var matches: [String] = []
    var queue: [(path: String, depth: Int)] = [("", 0)]
    var visits = 0
    var reachedLimit = false

    while !queue.isEmpty, matches.count < Self.maximumSearchResults {
      let (path, depth) = queue.removeFirst()
      guard let listing = try? reader.list(root: root.url, relativePath: path) else {
        // An unreadable subfolder is skipped rather than failing the search: one
        // permission-denied folder should not lose every other result.
        continue
      }

      for entry in listing.entries {
        visits += 1
        if visits > Self.maximumSearchVisits {
          reachedLimit = true
          break
        }
        let entryPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
        if Self.fold(entry.name).contains(needle) {
          matches.append(entry.isDirectory ? "\(entryPath)/" : entryPath)
          if matches.count >= Self.maximumSearchResults {
            reachedLimit = true
            break
          }
        }
        if entry.isDirectory, depth + 1 < Self.maximumSearchDepth {
          queue.append((entryPath, depth + 1))
        }
      }
      if reachedLimit {
        break
      }
    }

    guard !matches.isEmpty else {
      return "Nada com \"\(query)\" no nome, dentro de \(root.displayName)."
    }
    var answer = "Em \(root.displayName), com \"\(query)\" no nome:\n"
    answer += matches.joined(separator: "\n")
    if reachedLimit {
      answer += "\n(parei aqui; pode haver mais)"
    }
    return answer
  }
}

extension EvieFileToolbox {
  /// Resolves the identifier and turns any reader failure into a readable result.
  fileprivate func withRoot(
    _ call: EvieToolCall,
    arguments: [String: String],
    roots: [EvieFileRoot],
    body: (EvieFileRoot) throws -> String
  ) -> EvieToolResult {
    guard let identifier = arguments["root_id"], !identifier.isEmpty else {
      return failure(call, "Faltou root_id. Chame list_roots para obter os identificadores.")
    }
    guard let root = roots.first(where: { $0.id == identifier }) else {
      return failure(
        call,
        """
        Não existe pasta autorizada com o identificador \(identifier). Chame \
        list_roots e use um dos identificadores de lá — não invente nenhum.
        """
      )
    }

    do {
      return success(call, try body(root))
    } catch let error as EvieScopedFileReader.ReaderError {
      return failure(call, Self.describe(error, in: root))
    } catch {
      return failure(call, "Não consegui completar: \(error.localizedDescription)")
    }
  }

  /// Reader failures, said in a way that tells the model what to do next.
  fileprivate static func describe(
    _ error: EvieScopedFileReader.ReaderError,
    in root: EvieFileRoot
  ) -> String {
    switch error {
    case .invalidPath(let path):
      "O caminho \(path) não é válido."
    case .escapesRoot(let path):
      """
      \(path) sai de \(root.displayName), e você só pode olhar dentro das pastas \
      autorizadas.
      """
    case .notFound(let path):
      "Não existe \(path) em \(root.displayName). Use list_folder para ver o que existe."
    case .denied(let path):
      "\(path) é credencial ou chave, e fica fora do seu alcance mesmo aqui dentro."
    case .notReadable(let path):
      "Não tenho permissão de ler \(path)."
    case .notADirectory(let path):
      "\(path) não é uma pasta. Use read_file para ler um arquivo."
    case .isADirectory(let path):
      "\(path) é uma pasta. Use list_folder para ver o que tem dentro."
    case .notText(let path):
      "\(path) não é texto — não consigo ler como texto."
    case .rootUnavailable:
      """
      A pasta \(root.displayName) não está acessível agora. Talvez tenha sido \
      movida, renomeada, ou seja um disco que não está conectado.
      """
    }
  }

  fileprivate func success(_ call: EvieToolCall, _ content: String) -> EvieToolResult {
    EvieToolResult(callID: call.id, name: call.name, content: content)
  }

  fileprivate func failure(_ call: EvieToolCall, _ content: String) -> EvieToolResult {
    EvieToolResult(callID: call.id, name: call.name, content: content, isFailure: true)
  }

  /// The model writes `/Downloads/x`, `./x`, and `x` for the same thing.
  fileprivate func normalise(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix("./") {
      trimmed.removeFirst(2)
    }
    while trimmed.hasPrefix("/") {
      trimmed.removeFirst()
    }
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed
  }

  fileprivate func label(root: EvieFileRoot, path: String) -> String {
    let normalised = normalise(path)
    return normalised.isEmpty ? root.displayName : "\(root.displayName)/\(normalised)"
  }

  fileprivate func describeSize(_ bytes: Int?) -> String {
    guard let bytes else {
      return "tamanho desconhecido"
    }
    if bytes < 1_024 {
      return "\(bytes) B"
    }
    if bytes < 1_024 * 1_024 {
      return "\(bytes / 1_024) KB"
    }
    return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
  }

  /// Case and accents both get in the way of finding a file by name in
  /// Portuguese, so neither is allowed to matter.
  fileprivate static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = "d 'de' MMMM 'de' yyyy"
    return formatter
  }()
}
