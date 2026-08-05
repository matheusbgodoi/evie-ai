import EvieCore
import SwiftUI

/// Renders a parsed answer.
///
/// Headings become headings, bullets become bullets, and emphasis becomes weight
/// — none of it stays on screen as punctuation. What the model wrote as `###` or
/// `**` was always meant as formatting; showing the characters was the bug.
struct EvieRichTextView: View {
  var text: EvieRichText
  var isCompact = false

  var body: some View {
    VStack(alignment: .leading, spacing: isCompact ? 3 : 7) {
      ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func view(for block: EvieRichTextBlock) -> some View {
    switch block {
    case .heading(let level, let content):
      Text(content)
        .font(headingFont(level: level))
        .foregroundStyle(.primary)
        .padding(.top, isCompact ? 0 : 3)

    case .paragraph(let content):
      inline(content)
        .font(.callout)
        .foregroundStyle(.primary.opacity(0.88))

    case .bullet(let level, let content):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text("•")
          .font(.callout)
          .foregroundStyle(.secondary)
        inline(content)
          .font(.callout)
          .foregroundStyle(.primary.opacity(0.88))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(level) * 14)

    case .numbered(let level, let number, let content):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text("\(number).")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        inline(content)
          .font(.callout)
          .foregroundStyle(.primary.opacity(0.88))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(level) * 14)

    case .code(_, let content):
      Text(content)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.9))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

    case .rule:
      Divider().opacity(0.35).padding(.vertical, 2)
    }
  }

  /// Emphasis is rendered rather than shown. If the fragment will not parse as
  /// markdown, the markers are stripped instead — never displayed.
  private func inline(_ content: String) -> Text {
    if let attributed = try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
      return Text(attributed)
    }
    return Text(EvieRichText(content).plainText)
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case 1, 2: .system(size: 15, weight: .bold)
    case 3: .system(size: 13.5, weight: .bold)
    default: .system(size: 12.5, weight: .semibold)
    }
  }
}
