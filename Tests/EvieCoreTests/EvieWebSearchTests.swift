import Foundation
import Testing

@testable import EvieCore

@Suite("Evie web search")
struct EvieWebSearchTests {
  /// The shape DuckDuckGo's HTML endpoint actually returns, kept as a fixture so
  /// a change in their markup fails here rather than in front of the user.
  private static let sampleHTML = """
    <div class="results">
      <div class="result results_links">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a"
             href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexemplo.com%2Fartigo&amp;rut=abc">
            Um artigo sobre <b>Gemma</b>
          </a>
        </h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexemplo.com">
          O modelo <b>Gemma</b> roda localmente e tem 26 bilhões de parâmetros.
        </a>
      </div>
      <div class="result results_links">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a"
             href="//duckduckgo.com/l/?uddg=https%3A%2F%2Foutro.org%2Fp&amp;rut=def">
            Outra página
          </a>
        </h2>
        <a class="result__snippet">Segundo trecho.</a>
      </div>
    </div>
    """

  @Test("parses title, real address, and snippet")
  func parsesResults() throws {
    let results = EvieWebSearch.parseResults(from: Self.sampleHTML)

    #expect(results.count == 2, "achou \(results.count)")
    #expect(
      results[0].title == "Um artigo sobre Gemma",
      "título saiu como \(results.first?.title.debugDescription ?? "nada")"
    )
    #expect(results[0].url == "https://exemplo.com/artigo")
    #expect(results[0].snippet.contains("26 bilhões"))
    #expect(results[1].url == "https://outro.org/p")
  }

  /// The address in the markup is a tracking redirect. Handing that to a person,
  /// or to a model that will repeat it, hides where the answer came from.
  @Test("unwraps the redirect rather than quoting it")
  func unwrapsRedirects() {
    let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexemplo.com%2Fa%3Fb%3D1&amp;rut=x"

    #expect(EvieWebSearch.resolve(wrapped) == "https://exemplo.com/a?b=1")
  }

  @Test("a direct address is left alone")
  func keepsDirectAddresses() {
    #expect(EvieWebSearch.resolve("https://exemplo.com") == "https://exemplo.com")
    #expect(EvieWebSearch.resolve("/interno") == nil)
  }

  @Test("markup that does not match returns nothing rather than nonsense")
  func toleratesUnknownMarkup() {
    #expect(EvieWebSearch.parseResults(from: "<html><body>nada aqui</body></html>").isEmpty)
    #expect(EvieWebSearch.parseResults(from: "").isEmpty)
  }

  @Test("never returns more than a model can read")
  func boundsResults() {
    let many = String(repeating: Self.sampleHTML, count: 20)

    #expect(EvieWebSearch.parseResults(from: many).count == EvieWebSearch.maximumResults)
  }

  // MARK: - Reading a page

  @Test("keeps the prose and drops the furniture")
  func extractsReadableText() {
    let page = """
      <html><head><title>t</title><style>body{color:red}</style></head>
      <body>
        <script>var x = 1; alert("não sou texto");</script>
        <h1>Título</h1>
        <p>Primeiro parágrafo com <b>ênfase</b>.</p>
        <p>Segundo parágrafo &amp; um e-comercial.</p>
      </body></html>
      """

    let text = EvieWebSearch.readableText(fromHTML: page)

    #expect(text.contains("Título"))
    #expect(text.contains("Primeiro parágrafo com ênfase."))
    #expect(text.contains("Segundo parágrafo & um e-comercial."))
    #expect(!text.contains("alert"))
    #expect(!text.contains("color:red"))
  }

  @Test("paragraphs survive as separate lines")
  func keepsParagraphs() {
    let text = EvieWebSearch.readableText(fromHTML: "<p>um</p><p>dois</p>")

    #expect(text == "um\ndois")
  }

  /// A single page must not be able to displace the conversation.
  @Test("a huge page is cut rather than returned whole")
  func boundsPageLength() {
    let huge = "<p>" + String(repeating: "palavra ", count: 100_000) + "</p>"

    let text = EvieWebSearch.readableText(fromHTML: huge)

    #expect(text.count <= EvieWebSearch.maximumPageCharacters)
  }

  /// A real page came back as fifteen characters because removing `head` also
  /// matched `<header>`, and with no `</head>` after it the removal ran to the
  /// end of the document.
  @Test("removing head does not swallow the page at header")
  func headerIsNotHead() {
    let page = """
      <html><head><title>t</title></head>
      <body><header>Menu</header>
      <p>O conteúdo que importa está aqui.</p></body></html>
      """

    let text = EvieWebSearch.readableText(fromHTML: page)

    #expect(text.contains("O conteúdo que importa está aqui."))
    #expect(!text.contains("<title>"))
  }

  @Test("only the exact element is removed")
  func matchesTheWholeName() {
    #expect(EvieWebSearch.openingTag("head", in: "<header>x</header>") == nil)
    #expect(EvieWebSearch.openingTag("head", in: "<head>x</head>") != nil)
    #expect(EvieWebSearch.openingTag("head", in: "<head class=\"a\">x</head>") != nil)
    #expect(EvieWebSearch.openingTag("script", in: "<scripting>") == nil)
  }

  @Test("an unclosed script does not leak its contents")
  func handlesUnclosedElements() {
    let text = EvieWebSearch.readableText(fromHTML: "<p>antes</p><script>segredo()")

    #expect(text.contains("antes"))
    #expect(!text.contains("segredo"))
  }

  // MARK: - What the model is told

  /// The web is the least trustworthy text Evie will ever read. What comes back
  /// has to say so, or a page that asserts something confidently becomes an
  /// answer.
  @Test("results arrive labelled as claims, not as facts")
  func resultsAreLabelled() {
    let described = EvieWebSearch.describe(
      [EvieSearchResult(title: "T", url: "https://e.com", snippet: "s")],
      query: "algo"
    )

    #expect(described.contains("não o que é verdade"))
    #expect(described.contains("de onde veio"))
    #expect(described.contains("https://e.com"))
  }

  @Test("finding nothing says so plainly")
  func emptyResults() {
    #expect(EvieWebSearch.describe([], query: "xyzzy").contains("não trouxe resultado"))
  }
}
