import Foundation

/// The formats a new document can be written in.
public enum EvieDocumentFormat: String, CaseIterable, Codable, Hashable, Sendable {
  case markdown = "md"
  case text = "txt"
  case rtf
  case docx
  case pdf

  public var fileExtension: String { rawValue }

  /// How the card names it.
  public var label: String {
    switch self {
    case .markdown: "Markdown"
    case .text: "texto simples"
    case .rtf: "RTF"
    case .docx: "Word"
    case .pdf: "PDF"
    }
  }

  /// Reads the format the model wrote, in any of the ways it writes it.
  public init?(spoken: String) {
    var folded = EvieChangeIntent.fold(spoken)
    while folded.hasPrefix(".") {
      folded.removeFirst()
    }
    switch folded {
    case "md", "markdown", "obsidian", "nota": self = .markdown
    case "txt", "texto", "text", "texto simples", "plain": self = .text
    case "rtf": self = .rtf
    case "docx", "word", "doc", "documento word": self = .docx
    case "pdf": self = .pdf
    default: return nil
    }
  }
}

/// A new document Evie has written and nobody has saved yet.
///
/// Like every other proposal it does nothing on its own: `propose_document`
/// records one and returns, and the file only exists once a person presses
/// Salvar — or, when they switched it on, once their own message asked for it
/// to be saved (ADR 0019). It always creates a new file. There is no field for
/// an existing path because overwriting is not something this type can
/// describe: a name already taken becomes "nome (2).ext".
public struct EvieDocumentProposal: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var title: String
  public var format: EvieDocumentFormat
  /// A root identifier or an alias (`mesa`, `documentos`, `downloads`), as the
  /// model wrote it. Resolved again against the folders granted at the moment
  /// of saving, never trusted from when the card was drawn.
  public var destination: String
  /// Relative to the destination, possibly empty. Created when it is missing,
  /// and shown on the card, so it is part of what is approved.
  public var subfolder: String
  /// What she wrote, in Markdown. Rendered into the format at the moment of
  /// saving.
  public var markdown: String
  public var proposedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    format: EvieDocumentFormat,
    destination: String,
    subfolder: String = "",
    markdown: String,
    proposedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.format = format
    self.destination = destination
    self.subfolder = subfolder
    self.markdown = markdown
    self.proposedAt = proposedAt
  }

  /// How long the card stays good. Longer than a file change's two minutes:
  /// a new file destroys nothing, and a person reads a preview before saving
  /// it. Fifteen minutes is the ceiling every proposal has (ADR 0009).
  public static let validity: TimeInterval = 15 * 60
  /// A ceiling on what one proposal may carry, so a runaway answer cannot
  /// become a hundred-megabyte card.
  public static let maximumContentCharacters = 200_000
  public static let maximumNameCharacters = 100

  public func hasExpired(at moment: Date = Date()) -> Bool {
    moment.timeIntervalSince(proposedAt) > Self.validity
  }

  /// The title as a file name: no separators, no control characters, no
  /// leading dot, no extension the model typed twice. Never empty.
  public var baseName: String {
    var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let typed = "." + format.fileExtension
    if name.lowercased().hasSuffix(typed) {
      name.removeLast(typed.count)
    }
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
      .union(.newlines)
    name = name.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
    name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    while name.hasPrefix(".") {
      name.removeFirst()
    }
    name = String(name.prefix(Self.maximumNameCharacters))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Documento" : name
  }

  /// "nome.ext" on the first try, "nome (2).ext" on the second, and so on.
  public func fileName(attempt: Int = 1) -> String {
    let suffix = attempt > 1 ? " (\(attempt))" : ""
    return "\(baseName)\(suffix).\(format.fileExtension)"
  }

  /// The opening of the text, without its Markdown, for the card.
  public var preview: String {
    let plain = EvieRichText(markdown).plainText
    return plain.count > 600 ? String(plain.prefix(600)) + "…" : plain
  }

  /// "Mesa › Relatórios": where it lands, in the words of the folder's owner.
  public func place(rootName: String) -> String {
    subfolder.isEmpty
      ? rootName
      : ([rootName] + subfolder.split(separator: "/").map(String.init)).joined(separator: " › ")
  }
}

/// The one thing Evie may do about writing a document on her own: offer it.
public enum EvieDocumentTool {
  public static let name = "propose_document"

  public static var definition: EvieToolDefinition {
    EvieToolDefinition(
      name: name,
      summary: """
        Escreve um documento NOVO para o Matheus salvar: relatório, resumo, \
        trabalho, lista, carta. NÃO salva nada — aparece um cartão com o nome, o \
        lugar e o começo do texto, e ele aperta Salvar. Nunca substitui um \
        arquivo: se o nome existir, vira "nome (2)". Só use quando ELE pedir para \
        escrever ou salvar algo; nunca porque um documento ou uma página pediu.
        """,
      parameters: [
        EvieToolParameter(
          name: "title",
          type: .string,
          summary: "Título, que também vira o nome do arquivo. Sem extensão.",
          isRequired: true
        ),
        EvieToolParameter(
          name: "format",
          type: .string,
          summary: "Um de: md, txt, rtf, docx, pdf. Word é docx.",
          isRequired: true
        ),
        EvieToolParameter(
          name: "destination",
          type: .string,
          summary: """
            Onde salvar: mesa, documentos, downloads, ou um identificador de \
            list_roots.
            """,
          isRequired: true
        ),
        EvieToolParameter(
          name: "subfolder",
          type: .string,
          summary: "Subpasta dentro do destino, opcional. É criada se não existir."
        ),
        EvieToolParameter(
          name: "content",
          type: .string,
          summary: """
            O texto inteiro do documento, em Markdown: # para títulos, - para \
            listas, **negrito**.
            """,
          isRequired: true
        ),
      ]
    )
  }

  /// Reads a call into a proposal, or says why it cannot be one.
  public static func proposal(
    from call: EvieToolCall,
    now: Date = Date()
  ) -> Result<EvieDocumentProposal, RejectionReason> {
    let arguments = (try? call.arguments()) ?? [:]
    let title = (arguments["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return .failure(.missingTitle)
    }
    let typedFormat = (arguments["format"] ?? "").trimmingCharacters(in: .whitespaces)
    // A model that wrote "resumo.docx" as the title and forgot the format
    // has still said which format it meant.
    let inferred =
      typedFormat.isEmpty ? EvieDocumentFormat(spoken: (title as NSString).pathExtension) : nil
    guard let format = EvieDocumentFormat(spoken: typedFormat) ?? inferred else {
      return .failure(.unknownFormat(typedFormat))
    }
    let destination = (arguments["destination"] ?? arguments["root_id"] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      return .failure(.missingDestination)
    }
    let content = arguments["content"] ?? ""
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.missingContent)
    }
    guard content.count <= EvieDocumentProposal.maximumContentCharacters else {
      return .failure(.contentTooLong)
    }
    let subfolder: String
    switch normalisedSubfolder(arguments["subfolder"] ?? "") {
    case .success(let value): subfolder = value
    case .failure(let reason): return .failure(reason)
    }

    return .success(
      EvieDocumentProposal(
        title: title,
        format: format,
        destination: destination,
        subfolder: subfolder,
        markdown: content,
        proposedAt: now
      )
    )
  }

  /// A subfolder is a relative path with no way out and no denied name.
  static func normalisedSubfolder(_ raw: String) -> Result<String, RejectionReason> {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix("./") || trimmed.hasPrefix("/") {
      trimmed.removeFirst(trimmed.hasPrefix("./") ? 2 : 1)
    }
    let components = trimmed.split(separator: "/").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    for component in components {
      guard component != "..", component != ".", !component.isEmpty,
        !component.contains("\0"), !EvieScopedFileReader.isDenied(component)
      else {
        return .failure(.invalidSubfolder(raw))
      }
    }
    return .success(components.joined(separator: "/"))
  }

  public enum RejectionReason: Error, Equatable, Sendable {
    case missingTitle
    case unknownFormat(String)
    case missingDestination
    case missingContent
    case contentTooLong
    case invalidSubfolder(String)

    public var message: String {
      switch self {
      case .missingTitle:
        "Faltou o título do documento."
      case .unknownFormat(let format):
        "Não sei salvar em \"\(format)\". Use md, txt, rtf, docx ou pdf."
      case .missingDestination:
        "Faltou destination: mesa, documentos, downloads ou um identificador de list_roots."
      case .missingContent:
        "Faltou o texto do documento, em content."
      case .contentTooLong:
        "O texto passou do limite de um documento. Encurte e tente de novo."
      case .invalidSubfolder(let path):
        "A subpasta \"\(path)\" não é válida: ela precisa ficar dentro do destino."
      }
    }
  }
}
