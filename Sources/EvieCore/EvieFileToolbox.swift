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
  /// The home folder the well-known aliases (`mesa`, `documentos`,
  /// `downloads`, `obsidian`) are resolved against. Absent means no alias is
  /// understood and `list_roots` suggests nothing: the schedule runner and the
  /// diagnostics see exactly the identifiers they were given. Only the shell's
  /// own turn sets it, and tests set it to a temporary folder.
  public var home: URL?

  public init(reader: EvieScopedFileReader = EvieScopedFileReader(), home: URL? = nil) {
    self.reader = reader
    self.home = home
  }

  /// How many text files a content search will open. The Obsidian vault this was
  /// designed against holds 197 notes; the ceiling is set well above that so a
  /// normal vault is searched completely, and low enough that pointing Evie at a
  /// source tree does not turn one question into a minute of disk work.
  public static let maximumFilesSearched = 600
  /// How much of each file is scanned. A note longer than this has its opening
  /// searched, which is where a note says what it is about.
  public static let maximumSearchBytesPerFile = 64 * 1_024
  public static let maximumContentMatches = 12

  public enum ToolName: String, CaseIterable, Sendable {
    case listRoots = "list_roots"
    case listFolder = "list_folder"
    case readFile = "read_file"
    case searchFiles = "search_files"
    case searchContent = "search_content"
    case fileInfo = "file_info"
    case analyzeFolder = "analyze_folder"
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
          uma, e os apelidos mesa, documentos e downloads. Chame primeiro, \
          sempre: nenhuma outra ferramenta funciona sem um identificador ou \
          apelido vindo daqui.
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
        name: ToolName.searchContent.rawValue,
        summary: """
          Procura dentro do texto dos arquivos, não só no nome. Use para achar \
          o que o Matheus escreveu sobre um assunto quando ele não souber em \
          qual arquivo está — anotações, notas do Obsidian, documentos. Devolve \
          os trechos com o arquivo de cada um; leia o arquivo depois se precisar \
          do contexto inteiro.
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
            summary: """
              Palavra ou expressão procurada. Maiúsculas e acentos não importam. \
              Prefira uma ou duas palavras específicas a uma frase inteira.
              """,
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
      EvieToolDefinition(
        name: ToolName.analyzeFolder.rawValue,
        summary: """
          Faz uma visão geral de uma pasta de uma vez: quantos arquivos de cada \
          tipo, quanto ocupam, os mais novos e os mais antigos, alguns nomes e o \
          começo de alguns documentos (PDF, Word, RTF, texto). Use quando ele \
          pedir para analisar uma pasta ou perguntar o que tem nela.
          """,
        parameters: [
          EvieToolParameter(
            name: "root_id",
            type: .string,
            summary: "Identificador ou apelido da pasta, vindo de list_roots.",
            isRequired: true
          ),
          EvieToolParameter(
            name: "path",
            type: .string,
            summary: "Subpasta, relativa à pasta autorizada. Deixe vazio para a raiz."
          ),
          EvieToolParameter(
            name: "documents",
            type: .integer,
            summary: "Quantos documentos ler o começo, de 0 a 8. Padrão 4."
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
  ///
  /// - Parameter correctingNearMisses: whether a `search_content` term that
  ///   matches nothing gets one retry with the nearest word the files hold
  ///   (`EvieNearestTerm`). On for the person's own words; for a term the model
  ///   wrote, only when its family is known to misspell them
  ///   (`ModelFamily.misspellsSearchTerms`).
  public func execute(
    _ call: EvieToolCall,
    roots: [EvieFileRoot],
    correctingNearMisses: Bool = true
  ) -> EvieToolResult {
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
    case .searchContent:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try searchContent(
          root: root,
          query: arguments["query"] ?? "",
          correctingNearMisses: correctingNearMisses
        )
      }
    case .fileInfo:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        try fileInfo(root: root, path: arguments["path"] ?? "")
      }
    case .analyzeFolder:
      return withRoot(call, arguments: arguments, roots: roots) { root in
        let path = normalise(arguments["path"] ?? "")
        let requested = arguments["documents"].flatMap { Int($0) }
        return try EvieFolderAnalyzer(reader: reader)
          .analyze(
            root: root.url,
            relativePath: path,
            extracts: requested ?? EvieFolderAnalyzer.defaultExtracts
          )
          .overview(of: label(root: root, path: path))
      }
    }
  }
}

extension EvieFileToolbox {
  fileprivate func listRoots(_ call: EvieToolCall, roots: [EvieFileRoot]) -> EvieToolResult {
    var sections: [String] = []
    if !roots.isEmpty {
      sections.append(
        "Pastas autorizadas (id e nome):\n"
          + roots.map { "\($0.id)  \($0.displayName)" }.joined(separator: "\n")
      )
    }

    if let home {
      let reachable = EvieSuggestedRoot.allCases.compactMap { suggestion -> String? in
        guard let location = suggestion.location(in: roots, home: home),
          location.id == suggestion.alias
        else {
          return nil
        }
        return "\(suggestion.alias)  \(suggestion.displayName)"
      }
      if !reachable.isEmpty {
        sections.append(
          "Apelidos que também servem de root_id:\n" + reachable.joined(separator: "\n")
        )
      }
      let ungranted = EvieSuggestedRoot.ungranted(in: roots, home: home)
      if !ungranted.isEmpty {
        sections.append(
          """
          Ainda não autorizadas: \(ungranted.map(\.alias).joined(separator: ", ")). Se ele \
          pedir algo lá, use o apelido como root_id: aparece um cartão para ele \
          permitir com um clique, e então ele pede de novo.
          """
        )
      }
    }

    guard !sections.isEmpty else {
      return success(
        call,
        """
        Nenhuma pasta autorizada ainda. Diga ao Matheus para abrir Configurações \
        > Pastas e escolher quais você pode ver.
        """
      )
    }
    return success(call, sections.joined(separator: "\n\n"))
  }

  fileprivate func listFolder(root: EvieFileRoot, path: String) throws -> String {
    let listing = try reader.list(root: root.url, relativePath: normalise(path))
    guard !listing.entries.isEmpty else {
      return "A pasta \(label(root: root, path: path)) está vazia."
    }

    var lines = listing.entries.map { entry in
      entry.isDirectory
        ? "\(entry.name)/"
        : "\(entry.name)  \(Self.describeSize(entry.byteSize))"
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
    if EvieDocumentText.isExtracted(path) {
      return try readDocument(root: root, path: path)
    }
    let excerpt = try reader.read(root: root.url, relativePath: normalise(path))
    let header =
      excerpt.isTruncated
      ? "Começo de \(path) (\(Self.describeSize(excerpt.byteSize)) no total, cortado):"
      : "Conteúdo de \(path):"
    return header + "\n" + excerpt.text
  }

  /// A PDF, Word or RTF file, read for its text. A PDF with no text layer —
  /// a scan — says so rather than pretending it is empty.
  fileprivate func readDocument(root: EvieFileRoot, path: String) throws -> String {
    let data = try reader.readData(root: root.url, relativePath: normalise(path))
    guard
      let extract = EvieDocumentText.extract(
        from: data,
        fileExtension: (path as NSString).pathExtension
      )
    else {
      return """
        \(path) não tem texto que eu consiga tirar daqui — pode ser um PDF \
        escaneado. Se ele anexar o arquivo na conversa, eu leio a imagem das páginas.
        """
    }
    let pages = extract.pageCount.map { ", \($0) página(s)" } ?? ""
    let header =
      extract.isTruncated
      ? "Começo do texto de \(path) (\(Self.describeSize(data.count))\(pages), cortado):"
      : "Texto de \(path) (\(Self.describeSize(data.count))\(pages)):"
    return header + "\n" + extract.text
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
      parts.append(Self.describeSize(entry.byteSize))
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
    let root: EvieFileRoot
    switch EvieSuggestedRoot.lookup(identifier, in: roots, home: home) {
    case .granted(let found):
      root = found
    case .notGranted(let suggestion):
      return failure(call, Self.notGrantedMessage(suggestion))
    case .unknown:
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
  static func describe(
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
    case .tooLarge(let path):
      "\(path) é grande demais para eu abrir aqui (mais de 16 MB)."
    }
  }

  /// What the model hears when it names a well-known folder that has not been
  /// granted. The card is the shell's job; this sentence makes sure the model
  /// says the right thing about it instead of claiming it looked.
  static func notGrantedMessage(_ suggestion: EvieSuggestedRoot) -> String {
    """
    \(suggestion.displayName) ainda não está autorizada. Apareceu um cartão para o \
    Matheus permitir com um clique ("\(suggestion.grantTitle)"). Diga isso a ele em \
    uma frase e que, depois de permitir, é só pedir de novo. Não diga que olhou.
    """
  }

  /// The well-known folder a call names that has not been granted, so the
  /// shell can offer the card. `nil` for every other call.
  public func requestedSuggestion(in call: EvieToolCall, roots: [EvieFileRoot]) -> EvieSuggestedRoot? {
    let arguments = (try? call.arguments()) ?? [:]
    guard let identifier = arguments["root_id"] ?? arguments["destination"],
      case .notGranted(let suggestion) = EvieSuggestedRoot.lookup(identifier, in: roots, home: home)
    else {
      return nil
    }
    return suggestion
  }

  fileprivate func success(_ call: EvieToolCall, _ content: String) -> EvieToolResult {
    EvieToolResult(callID: call.id, name: call.name, content: content)
  }

  fileprivate func failure(_ call: EvieToolCall, _ content: String) -> EvieToolResult {
    EvieToolResult(callID: call.id, name: call.name, content: content, isFailure: true)
  }

  /// The model writes `/Downloads/x`, `./x`, and `x` for the same thing.
  func normalise(_ path: String) -> String {
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

  func label(root: EvieFileRoot, path: String) -> String {
    let normalised = normalise(path)
    return normalised.isEmpty ? root.displayName : "\(root.displayName)/\(normalised)"
  }

  static func describeSize(_ bytes: Int?) -> String {
    guard let bytes else {
      return "tamanho desconhecido"
    }
    if bytes < 1_024 {
      return "\(bytes) B"
    }
    if bytes < 1_024 * 1_024 {
      return "\(bytes / 1_024) KB"
    }
    if bytes < 1_024 * 1_024 * 1_024 {
      return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
    return String(format: "%.1f GB", Double(bytes) / (1_024 * 1_024 * 1_024))
  }

  /// Case and accents both get in the way of finding a file by name in
  /// Portuguese, so neither is allowed to matter.
  static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = "d 'de' MMMM 'de' yyyy"
    return formatter
  }()
}

extension EvieFileToolbox {
  /// Searches inside the text of the files in a granted folder.
  ///
  /// This is what makes a folder of notes usable as a source rather than a list
  /// of filenames. It is a plain substring scan rather than an embedding index,
  /// and that is a deliberate choice: an index would need building, keeping in
  /// sync with every edit, and storing a second copy of everything the user
  /// wrote. Reading the files is slower per query and always current, needs no
  /// storage, and cannot answer from a stale copy of a note that has changed.
  ///
  /// Bounded in every direction that can run away, and it says so when it stops
  /// early — a search that silently gave up looks exactly like a search that
  /// found nothing.
  fileprivate func searchContent(
    root: EvieFileRoot,
    query: String,
    correctingNearMisses: Bool
  ) throws -> String {
    let needle = Self.fold(query)
    guard needle.count >= 2 else {
      return "Preciso de pelo menos duas letras para procurar."
    }
    let found = try scan(root: root, needle: needle, query: query)
    if correctingNearMisses, found.matches.isEmpty,
      let near = EvieNearestTerm.best(of: found.nearMisses)
    {
      // The term does not appear and something one letter away does. See
      // `EvieNearestTerm`: this is not a hypothetical typo, it is what Gemma
      // sends when it is asked about `cluemed`, and what a person types in a
      // hurry.
      let retry = try scan(root: root, needle: near, query: near)
      if !retry.matches.isEmpty {
        return render(retry, query: near, corrected: query, root: root)
      }
    }
    return render(found, query: query, corrected: nil, root: root)
  }

  /// What one pass of the scan found, and the text it read looking.
  fileprivate struct ContentScan {
    var matches: [String] = []
    /// Words seen that are within one edit of what was asked for, counted as the
    /// scan goes. Only these, never the text itself.
    var nearMisses: [String: Int] = [:]
    var filesRead = 0
    var stoppedEarly = false
  }

  fileprivate func render(
    _ scan: ContentScan,
    query: String,
    corrected: String?,
    root: EvieFileRoot
  ) -> String {
    guard !scan.matches.isEmpty else {
      return """
        Não achei "\(query)" no texto de nenhum arquivo de \(root.displayName) \
        (procurei em \(scan.filesRead)).
        """
    }
    // When the term was corrected, say so in the result rather than silently.
    // The model has to be able to tell the owner which word actually matched,
    // and a correction nobody is told about is a different kind of wrong answer.
    var answer =
      corrected.map {
        "Não achei \"\($0)\", mas achei \"\(query)\" em \(root.displayName) "
          + "— provavelmente é a mesma coisa escrita errada. Trechos:\n"
      } ?? "Trechos com \"\(query)\" em \(root.displayName):\n"
    answer += scan.matches.joined(separator: "\n")
    if scan.stoppedEarly {
      answer += "\n(parei aqui; pode haver mais)"
    }
    return answer
  }

  fileprivate func scan(
    root: EvieFileRoot,
    needle: String,
    query: String
  ) throws -> ContentScan {

    var result = ContentScan()
    var queue: [(path: String, depth: Int)] = [("", 0)]

    search: while !queue.isEmpty {
      let (path, depth) = queue.removeFirst()
      guard let listing = try? reader.list(root: root.url, relativePath: path) else {
        continue
      }

      for entry in listing.entries {
        if entry.isDirectory {
          if depth + 1 < Self.maximumSearchDepth {
            queue.append((path.isEmpty ? entry.name : "\(path)/\(entry.name)", depth + 1))
          }
          continue
        }
        guard Self.isProbablyText(entry.name) else {
          continue
        }
        if result.filesRead >= Self.maximumFilesSearched {
          result.stoppedEarly = true
          break search
        }

        let entryPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
        guard let excerpt = try? reader.read(root: root.url, relativePath: entryPath) else {
          continue
        }
        result.filesRead += 1
        EvieNearestTerm.accumulate(
          from: excerpt.text, for: needle, into: &result.nearMisses)

        for line in Self.matchingLines(in: excerpt.text, needle: needle) {
          result.matches.append("\(entryPath): \(line)")
          if result.matches.count >= Self.maximumContentMatches {
            result.stoppedEarly = true
            break search
          }
        }
      }
    }
    return result
  }

  /// Lines containing the term, trimmed to something a model can read.
  ///
  /// One line of context is enough to decide whether the file is worth opening,
  /// which is the decision this tool exists to support. Handing back whole
  /// paragraphs for a dozen matches would fill the context with text that mostly
  /// is not the answer.
  static func matchingLines(in text: String, needle: String, limit: Int = 3) -> [String] {
    var found: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard fold(String(line)).contains(needle) else {
        continue
      }
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.count > 220 {
        trimmed = String(trimmed.prefix(220)) + "…"
      }
      guard !trimmed.isEmpty else {
        continue
      }
      found.append(trimmed)
      if found.count >= limit {
        break
      }
    }
    return found
  }

  /// Whether a name is worth opening as text.
  ///
  /// By extension rather than by sniffing content, because the point is to avoid
  /// opening the file at all. The reader still refuses binary it is handed.
  public static func isProbablyText(_ name: String) -> Bool {
    let searchable: Set<String> = [
      "md", "markdown", "txt", "text", "org", "rst", "canvas",
      "json", "yaml", "yml", "toml", "csv", "tsv",
      "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt",
      "c", "h", "cpp", "hpp", "m", "sh", "zsh", "sql", "html", "css", "xml",
    ]
    let extensionName = (name as NSString).pathExtension.lowercased()
    // An extensionless file is skipped: it is as likely to be a binary or a
    // token file as prose, and the denylist already refuses the worst of those.
    return !extensionName.isEmpty && searchable.contains(extensionName)
  }
}
