import Foundation

/// What went wrong in a turn that used tools.
enum EvieAgentLoopFailure: LocalizedError {
  /// She kept looking instead of answering, and hit the ceiling.
  ///
  /// Reported rather than hidden behind a generic error: the honest thing to say
  /// is that she got lost, and the useful thing to suggest is a narrower
  /// question, which is what usually fixes it.
  case exhausted

  var errorDescription: String? {
    switch self {
    case .exhausted:
      """
      Fiquei procurando e não cheguei a uma resposta. Tente perguntar de um jeito \
      mais específico — o nome do arquivo ou a pasta, se você souber.
      """
    }
  }
}
