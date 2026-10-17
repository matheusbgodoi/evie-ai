import Foundation

/// Public URL entry points can only open review UI. A URL never authorizes a
/// model turn, screen capture, input event or file operation.
public enum EvieNativeURLRequest: Equatable, Sendable {
  public static let maximumQuestionCharacters = 8_000
  public static let maximumEncodedURLBytes = 1 << 20

  case openConversation
  case prepareQuestion(String)
  case requestCaptureConfirmation

  public enum Problem: Error, LocalizedError {
    case invalidURL
    case emptyQuestion
    case questionTooLong

    public var errorDescription: String? {
      switch self {
      case .invalidURL: "Este link não corresponde a uma ação pública da Evie."
      case .emptyQuestion: "Escreva a pergunta que deseja preparar na Evie."
      case .questionTooLong: "A pergunta precisa ter até 8.000 caracteres."
      }
    }
  }

  public static func parse(_ url: URL) throws -> Self {
    guard url.absoluteString.utf8.count <= maximumEncodedURLBytes,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "evie",
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.percentEncodedPath.isEmpty, parts.fragment == nil
    else { throw Problem.invalidURL }

    switch parts.host?.lowercased() {
    case "open":
      guard parts.query == nil else { throw Problem.invalidURL }
      return .openConversation
    case "capture":
      guard parts.query == nil else { throw Problem.invalidURL }
      return .requestCaptureConfirmation
    case "prepare":
      guard let items = parts.queryItems, items.count == 1,
        items[0].name == "text", let value = items[0].value,
        !value.contains("\0")
      else { throw Problem.invalidURL }
      let question = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !question.isEmpty else { throw Problem.emptyQuestion }
      guard question.count <= maximumQuestionCharacters else { throw Problem.questionTooLong }
      return .prepareQuestion(question)
    default:
      throw Problem.invalidURL
    }
  }
}
