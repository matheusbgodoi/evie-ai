import Foundation
import Testing

@testable import EvieCore

@Suite("Evie conversation export")
struct EvieConversationExportTests {
  private static let created = Date(timeIntervalSince1970: 1_700_000_000)
  private static let updated = Date(timeIntervalSince1970: 1_700_003_600)

  private func conversation(
    title: String = "Conversa de teste",
    messages: [ChatMessage] = []
  ) -> EvieConversation {
    EvieConversation(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
      title: title,
      createdAt: Self.created,
      updatedAt: Self.updated,
      messages: messages
    )
  }

  @Test("opens with YAML front matter carrying the title and both ISO-8601 dates")
  func frontMatter() {
    let markdown = EvieConversationExport.markdown(for: conversation(title: "Plano: semana"))
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(lines.first == "---")
    #expect(lines.contains("title: \"Plano: semana\""))
    #expect(lines.contains("created: 2023-11-14T22:13:20Z"))
    #expect(lines.contains("updated: 2023-11-14T23:13:20Z"))
    // The block has to close, or the whole note is front matter.
    #expect(lines.dropFirst().contains("---"))
  }

  @Test("labels each turn and stamps it")
  func turnsAreLabelled() {
    let markdown = EvieConversationExport.markdown(
      for: conversation(
        messages: [
          ChatMessage(role: .user, content: "Oi", createdAt: Self.created),
          ChatMessage(role: .assistant, content: "Olá", createdAt: Self.updated),
        ]
      )
    )

    #expect(markdown.contains("## Você"))
    #expect(markdown.contains("## Evie"))
    #expect(markdown.contains("*2023-11-14T22:13:20Z*"))
    #expect(markdown.contains("*2023-11-14T23:13:20Z*"))
  }

  @Test("passes assistant Markdown through untouched")
  func assistantContentIsVerbatim() {
    let answer = """
      ## Passos

      1. Primeiro
      2. Segundo

      ```swift
      let x = 1
      ```
      """
    let markdown = EvieConversationExport.markdown(
      for: conversation(
        messages: [ChatMessage(role: .assistant, content: answer, createdAt: Self.created)]
      )
    )

    #expect(markdown.contains(answer))
  }

  @Test("user text that looks like front matter cannot restructure the document")
  func userContentIsContained() {
    let hostile = """
      ---
      title: outra coisa
      ---

      # Cabeçalho falso
      """
    let markdown = EvieConversationExport.markdown(
      for: conversation(
        messages: [ChatMessage(role: .user, content: hostile, createdAt: Self.created)]
      )
    )
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

    // Exactly the two delimiters of the real front matter, and nothing loose that
    // a parser could read as a second block or a rule.
    #expect(lines.filter { $0 == "---" }.count == 2)
    #expect(!lines.contains("title: outra coisa"))
    #expect(!lines.contains("# Cabeçalho falso"))
    #expect(markdown.contains("> ---"))
    #expect(markdown.contains("> # Cabeçalho falso"))
  }

  @Test("a title with a slash cannot become a path")
  func fileNameStripsSeparators() {
    let name = EvieConversationExport.fileName(
      for: conversation(title: "Notas/2024: rascunho")
    )

    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
    #expect(name.hasSuffix(".md"))
    #expect(name == "Notas-2024- rascunho.md")
  }

  @Test("a very long title is cut to something a file system accepts")
  func fileNameIsBounded() {
    let name = EvieConversationExport.fileName(
      for: conversation(title: String(repeating: "á", count: 400))
    )

    #expect(name.hasSuffix(".md"))
    #expect(name.count == EvieConversationExport.maximumBaseNameLength + 3)
    #expect(name.utf8.count < 255)
  }

  @Test("a title of dots and blanks still yields a visible file")
  func fileNameNeverStartsWithADot() {
    #expect(EvieConversationExport.fileName(for: conversation(title: "...")) == "Conversa.md")
    #expect(EvieConversationExport.fileName(for: conversation(title: "   ")) == "Conversa.md")
    #expect(
      EvieConversationExport.fileName(for: conversation(title: ".oculta")) == "oculta.md"
    )
  }

  @Test("a conversation with no messages still produces a real document")
  func emptyConversation() {
    let markdown = EvieConversationExport.markdown(for: conversation(title: "Vazia"))

    #expect(markdown.hasPrefix("---\n"))
    #expect(markdown.contains("# Vazia"))
    #expect(markdown.contains("Esta conversa não tem mensagens salvas."))
    #expect(!markdown.contains("## "))
  }
}
