import EvieCore
import Foundation

/// The only part of Evie that talks to something other than this Mac.
///
/// It is deliberately small, and deliberately the only one. Everything else in
/// this project refuses a non-loopback address; this is the exception, so it is
/// worth being able to read the whole of it in one sitting and see exactly what
/// leaves: a search query, and a page address the user's own question led to.
///
/// Nothing is sent unless the user switched web search on, and the switch says
/// plainly that turning it on means queries leave the machine.
struct EvieWebClient: EvieWebSearching, Sendable {
  /// No account, no key, no quota. Anything else would mean signing up for
  /// something in order to ask a question.
  static let searchEndpoint = URL(string: "https://html.duckduckgo.com/html/")!

  /// A plausible browser. The endpoint returns an error page to anything that
  /// looks automated, which would otherwise show up as "found nothing".
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  /// Enforced during transfer by the bounded public-web transport.
  static let maximumDownloadBytes = 4 * 1_024 * 1_024

  var timeout: TimeInterval = 20

  enum WebError: LocalizedError, Equatable {
    case offline
    case rejected(Int)
    case notReadable
    case unsafeAddress(String)

    var errorDescription: String? {
      switch self {
      case .offline:
        "Não consegui alcançar a internet agora."
      case .rejected(let status):
        "O site respondeu com um erro (HTTP \(status))."
      case .notReadable:
        "Essa página não veio como texto que eu consiga ler."
      case .unsafeAddress(let address):
        "Não vou abrir \(address)."
      }
    }
  }

  func search(_ query: String) async throws -> [EvieSearchResult] {
    var request = URLRequest(url: Self.searchEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(
      "q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)".utf8
    )

    let html = try await fetchText(request)
    return EvieWebSearch.parseResults(from: html)
  }

  /// Searches, reads the best few results at once, and returns only the passages
  /// that answer the question.
  ///
  /// Three pages instead of one, fetched concurrently so it costs about what one
  /// costs, and a page that fails is simply absent rather than fatal. Reading
  /// more sources is what makes the answer better; sending only the matching
  /// passages is what makes it cheaper at the same time.
  func gather(_ query: String, pages: Int = 3, passages: Int = 6) async throws
    -> [EvieWebPassage]
  {
    let results = try await search(query)
    guard !results.isEmpty else {
      return []
    }

    let candidates = Array(results.prefix(pages))
    let harvested = await withTaskGroup(of: [EvieWebPassage].self) { group in
      for result in candidates {
        group.addTask {
          guard let html = try? await self.fetchPage(result.url) else {
            // One unreachable page must not lose the other two.
            return []
          }
          return EvieWebPassages.extract(fromHTML: html, source: result.url)
        }
      }
      var all: [EvieWebPassage] = []
      for await page in group {
        all.append(contentsOf: page)
      }
      return all
    }

    // Falling back to the snippets is better than falling back to nothing: they
    // are short and written for search, but they are on topic.
    guard !harvested.isEmpty else {
      return results.prefix(passages).map {
        EvieWebPassage(text: "\($0.title). \($0.snippet)", source: $0.url)
      }
    }
    return EviePassageRanker.rank(harvested, for: query, limit: passages)
  }

  /// The raw markup of a page, for the passage extractor to work on.
  func fetchPage(_ address: String) async throws -> String {
    guard let url = Self.validate(address) else {
      throw WebError.unsafeAddress(address)
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    return try await fetchText(request)
  }

  /// Downloads one page and returns its readable text.
  func read(_ address: String) async throws -> String {
    guard let url = Self.validate(address) else {
      throw WebError.unsafeAddress(address)
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

    let body = try await fetchText(request)
    let text = EvieWebSearch.readableText(fromHTML: body)
    guard !text.isEmpty else {
      throw WebError.notReadable
    }
    return text
  }

  /// Refuses anything that is not a public web address.
  ///
  /// A page Evie reads can contain a link, and a model asked to follow one will.
  /// Without this, "read this page" becomes a way to make Evie fetch
  /// `http://127.0.0.1:38433` or a cloud metadata endpoint on the user's behalf —
  /// the request comes from inside the machine, so anything that trusts the
  /// local network trusts it.
  static func validate(_ address: String) -> URL? {
    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      EviePublicWebFetcher.accepts(url)
    else { return nil }
    return url
  }
}

extension EvieWebClient {
  fileprivate func fetchText(_ request: URLRequest) async throws -> String {
    try await EviePublicWebFetcher().text(
      for: request, maximumBytes: Self.maximumDownloadBytes, timeout: timeout)
  }
}
