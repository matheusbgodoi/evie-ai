import Foundation

/// Why a model turn failed, in terms a caller can act on.
///
/// The cases that mean the brain never answered — see `allowsFailover` — are the
/// ones a caller may answer by trying another model, because nothing has been
/// shown yet. After a delta the text is already on screen and any failure is
/// final.
public enum ModelClientError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  /// `ModelTransportPolicy` refused the endpoint; nothing was sent.
  case transportRefused(String)
  /// The endpoint needs a key and none could be read; nothing was sent.
  case credentialUnavailable(String)
  case requestEncoding(String)
  /// The body is over the 60 MB Evie sends (the gateway's own limit is 64 MB),
  /// or the server answered 413.
  case requestTooLarge
  /// No answer from the server, or the gateway (502) could not reach the engine.
  case unreachable(String)
  /// 401. The cached key is dropped, and the request is not retried: the PC's
  /// control plane blocks an address after ten bad keys.
  case unauthorized
  /// The gateway has no route for this model id.
  case modelNotFound(String)
  case server(status: Int, message: String)
  /// An error object inside the stream. `code` is kept as text whether the
  /// server sent a string or a number.
  case streamFailed(message: String, code: String?)
  case malformedStreamEvent
  case emptyStream
  case streamEndedBeforeDone
  /// The output cap ran out before any answer: everything went to reasoning.
  case truncated(completionTokens: Int)
  case headersTimedOut
  case firstTokenTimedOut
  /// The request was cancelled by something other than the caller.
  case cancelled
}

extension ModelClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let detail):
      "A configuração do modelo é inválida: \(detail)"
    case .transportRefused(let detail):
      "A Evie se recusou a enviar a conversa: \(detail)"
    case .credentialUnavailable(let detail):
      "A chave do modelo não está disponível: \(detail)"
    case .requestEncoding(let detail):
      "Não foi possível montar o pedido ao modelo: \(detail)"
    case .requestTooLarge:
      "O pedido ficou grande demais para o modelo. Tente com uma imagem menor ou menos anexos."
    case .unreachable(let detail):
      "O modelo não respondeu (\(detail))."
    case .unauthorized:
      "O servidor recusou a chave salva. Cole ou importe a chave de novo em Configurações › Cérebro."
    case .modelNotFound(let model):
      "O servidor não conhece o modelo \(model)."
    case .server(let status, let message):
      message.isEmpty
        ? "O servidor do modelo respondeu HTTP \(status)."
        : "O servidor do modelo respondeu HTTP \(status): \(message)"
    case .streamFailed(let message, let code):
      if let code, !code.isEmpty {
        "O modelo falhou no meio da resposta (\(code)): \(message)"
      } else {
        "O modelo falhou no meio da resposta: \(message)"
      }
    case .malformedStreamEvent:
      "O modelo mandou um trecho de resposta ilegível."
    case .emptyStream:
      "O modelo terminou sem escrever uma resposta."
    case .streamEndedBeforeDone:
      "A conexão com o modelo caiu antes do fim da resposta."
    case .truncated(let tokens):
      "O modelo gastou todo o limite (\(tokens) tokens) pensando e não chegou a responder. Tente de novo com menos raciocínio."
    case .headersTimedOut:
      "O modelo demorou demais para começar a responder."
    case .firstTokenTimedOut:
      "O modelo aceitou o pedido mas não começou a responder a tempo."
    case .cancelled:
      "O pedido ao modelo foi cancelado."
    }
  }
}

extension ModelClientError {
  /// Whether this failure, before the turn's first delta, may be retried on
  /// another brain: the server could not be reached (502 included, which the
  /// gateway sends when its engine is gone), never sent its headers, refused
  /// the key, or there was no key to send.
  ///
  /// Not a first-token timeout: the server accepted the request and is slow,
  /// and a slow brain is not an absent one. Not a refusal by the transport
  /// policy either, which is a configuration to fix, nor anything about the
  /// request itself, which another brain would refuse the same way.
  public var allowsFailover: Bool {
    switch self {
    case .unreachable, .headersTimedOut, .unauthorized, .credentialUnavailable:
      true
    case .server(let status, _):
      status == 502
    default:
      false
    }
  }
}
