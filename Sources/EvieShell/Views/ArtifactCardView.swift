import EvieCore
import SwiftUI

enum ArtifactKind: String, Hashable {
  case answer
  case research
  case email
  case calendar
  case file
  case memory
  case image
  case workflow
  case approval
  case error

  var title: String {
    switch self {
    case .answer: "Resposta"
    case .research: "Pesquisa"
    case .email: "E-mail"
    case .calendar: "Calendário"
    case .file: "Arquivo"
    case .memory: "Memória"
    case .image: "Imagem"
    case .workflow: "Automação"
    case .approval: "Aprovação"
    case .error: "Erro"
    }
  }

  var symbolName: String {
    switch self {
    case .answer: "sparkles"
    case .research: "globe"
    case .email: "envelope.fill"
    case .calendar: "calendar"
    case .file: "doc.fill"
    case .memory: "books.vertical.fill"
    case .image: "photo.fill"
    case .workflow: "point.3.connected.trianglepath.dotted"
    case .approval: "hand.raised.fill"
    case .error: "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .answer: .indigo
    case .research: .cyan
    case .email: .blue
    case .calendar: .purple
    case .file: .teal
    case .memory: .mint
    case .image: .pink
    case .workflow: .orange
    case .approval: .orange
    case .error: .red
    }
  }
}

enum ArtifactActionRole: String, Hashable {
  case primary
  case secondary
  case destructive
}

struct ArtifactActionModel: Identifiable, Hashable {
  var id: String
  var title: String
  var systemImage: String? = nil
  var role: ArtifactActionRole = .secondary
}

struct ArtifactCardModel: Identifiable, Hashable {
  var id: UUID = UUID()
  var kind: ArtifactKind
  var title: String
  /// What was asked to produce this. Shown only when the card is open.
  ///
  /// It lives on the answer rather than in a card of its own. A separate card for
  /// your own question doubles the length of every conversation with text you
  /// already know, and the thing you actually want back later is the answer —
  /// with the question there to confirm you opened the right one.
  var question: String? = nil
  var summary: String

  /// The answer with its markdown and LaTeX resolved. Parsed once here rather
  /// than on every redraw of a streaming card.
  var richSummary: EvieRichText {
    EvieRichText(summary)
  }
  var detail: String? = nil
  var source: String? = nil
  var isExpanded = false
  /// True between asking and the first words of the answer.
  ///
  /// The card used to fill that gap with the sentence "Aguardando o primeiro
  /// trecho…", which is a status report pretending to be content: it sits in the
  /// place the answer will occupy and has to be read to discover it says nothing.
  /// A moving indicator says the same thing without asking to be read.
  var isLoading = false
  var isSensitive = false
  var actions: [ArtifactActionModel] = []

  /// Whether this card is asking something rather than reporting something.
  ///
  /// Its buttons live in the open state, so it must survive the tidying a new
  /// question does. "Copiar" is not a decision; a primary action is.
  var isAwaitingDecision: Bool {
    actions.contains { $0.role == .primary }
  }
}

struct ArtifactCardView: View {
  var artifact: ArtifactCardModel
  var onToggleExpanded: (() -> Void)? = nil
  var onDismiss: (() -> Void)? = nil
  var onAction: ((ArtifactActionModel) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How tall a single answer may get before it scrolls inside its own card.
  ///
  /// This is the whole shape of the fix. The answer used to be laid out at its
  /// full height and the *list* of cards did the scrolling, which meant a long
  /// answer scrolled its own header, its question and its Copiar button off the
  /// screen: to reach the button you scrolled past everything, and while reading
  /// the middle there was no title, no close, no way out. Worse, the card was
  /// taller than the window and the overlay was drawing beyond its own bounds.
  ///
  /// Now the card is the fixed thing and the text moves inside it. The header
  /// and the buttons stay where they are, and the scroll bar sits where the
  /// content it scrolls is.
  private static let readingHeight: CGFloat = 360

  /// The part that scrolls: the question and the answer, and nothing else.
  private var readingArea: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 11) {
        if let question = artifact.question, !question.isEmpty {
          askedRow(question)
        }
        if artifact.isSensitive {
          sensitivePreview
        } else {
          content
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // Room for the indicator, so it never sits on top of a word.
      .padding(.trailing, 4)
    }
    // Shown rather than hidden. A bounded box with no visible bar looks like
    // text that was cut off, which is the complaint this exists to answer.
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.basedOnSize)
    // Only as tall as it needs to be. A short answer must not sit in a
    // half-empty box waiting for text that is not coming.
    .frame(maxHeight: Self.readingHeight)
  }


  var body: some View {
    GlassSurface(
      cornerRadius: 20,
      material: .popover,
      contentPadding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 12),
      tint: artifact.kind.tint
    ) {
      VStack(alignment: .leading, spacing: artifact.isExpanded ? 11 : 0) {
        header

        // Closed, a card is its title and nothing else — a line you can scan
        // down to find the answer you are after. Everything else waits.
        if artifact.isExpanded {
          readingArea
        }

        // Where the answer came from. Derived from the tools that actually ran,
        // so it cannot disagree with what happened, and kept out of the answer
        // text so it is never spoken and never copied.
        if let source = artifact.source, artifact.isExpanded {
          Label(source, systemImage: sourceSymbol(for: source))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }

        if artifact.isExpanded, !artifact.actions.isEmpty {
          actionBar
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: artifact.isExpanded)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(artifact.kind.title): \(artifact.title)")
    .privacySensitive(artifact.isSensitive)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: artifact.kind.symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(artifact.kind.tint)
        .frame(width: 28, height: 28)
        .background(artifact.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 1) {
        if artifact.isExpanded {
          Text(artifact.kind.title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(artifact.kind.tint)
            .tracking(0.75)
        }

        if artifact.isLoading {
          EvieThinkingIndicator(tint: artifact.kind.tint)
        } else {
          Text(artifact.title)
            .font(.subheadline.weight(artifact.isExpanded ? .semibold : .regular))
            .foregroundStyle(Color.primary.opacity(artifact.isExpanded ? 1 : 0.72))
            .lineLimit(artifact.isExpanded ? 3 : 1)
            .truncationMode(.tail)
        }
      }

      Spacer(minLength: 8)

      if onToggleExpanded != nil {
        iconButton(
          // Points the way it will move: down opens, up closes.
          symbol: artifact.isExpanded ? "chevron.up" : "chevron.down",
          label: artifact.isExpanded ? "Recolher" : "Expandir",
          action: { onToggleExpanded?() }
        )
      }

      if onDismiss != nil {
        iconButton(symbol: "xmark", label: "Fechar", action: { onDismiss?() })
      }
    }
  }

  /// The question, small and above the answer, so it is available to confirm you
  /// opened the right card without being read again on every turn.
  private func askedRow(_ question: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "quote.opening")
        .font(.system(size: 9))
        .foregroundStyle(.secondary.opacity(0.7))
      Text(question)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var content: some View {
    EvieRichTextView(text: artifact.richSummary)

    if artifact.isExpanded {
      if let detail = artifact.detail, !detail.isEmpty {
        Divider().opacity(0.42)

        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .transition(.opacity)
      }

    }
  }

  private var sensitivePreview: some View {
    HStack(spacing: 9) {
      Image(systemName: "eye.slash.fill")
        .foregroundStyle(.secondary)

      Text("Conteúdo privado oculto. Expanda para visualizar.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
    .accessibilityLabel("Conteúdo privado oculto")
  }

  private var actionBar: some View {
    HStack(spacing: 7) {
      Spacer(minLength: 0)

      ForEach(artifact.actions) { action in
        Button {
          onAction?(action)
        } label: {
          Label {
            Text(action.title)
          } icon: {
            if let systemImage = action.systemImage {
              Image(systemName: systemImage)
            }
          }
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(actionForeground(action.role))
        .background(actionBackground(action.role), in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(actionBorder(action.role), lineWidth: 0.6)
        }
        .accessibilityLabel(action.title)
      }
    }
  }

  /// A different mark for "I looked it up" and "I am going from memory", because
  /// the second is the one worth noticing at a glance.
  private func sourceSymbol(for source: String) -> String {
    if source.contains("só o que eu já sabia") {
      return "exclamationmark.circle"
    }
    if source.contains("web") {
      return "globe"
    }
    return "folder"
  }

  private func iconButton(
    symbol: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    EvieGlowButton(
      systemImage: symbol,
      label: label,
      tint: artifact.kind.tint,
      diameter: 23,
      glyphSize: 9,
      action: action
    )
    .frame(width: 23, height: 23)
  }

  private func actionForeground(_ role: ArtifactActionRole) -> Color {
    switch role {
    case .primary: .white
    case .secondary: .primary
    case .destructive: .red
    }
  }

  private func actionBackground(_ role: ArtifactActionRole) -> Color {
    switch role {
    case .primary: artifact.kind.tint
    case .secondary: .white.opacity(0.075)
    case .destructive: .red.opacity(0.10)
    }
  }

  private func actionBorder(_ role: ArtifactActionRole) -> Color {
    switch role {
    case .primary: .white.opacity(0.20)
    case .secondary: .white.opacity(0.10)
    case .destructive: .red.opacity(0.24)
    }
  }
}


/// Three dots that travel while she is thinking.
///
/// The shape of the wave lives in `EvieThinkingWave`, where it can be tested;
/// this only draws it.
struct EvieThinkingIndicator: View {
  var tint: Color

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
      let phase =
        timeline.date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: EvieThinkingWave.period) / EvieThinkingWave.period
      HStack(spacing: 4) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(tint)
            .frame(width: 5, height: 5)
            .opacity(EvieThinkingWave.opacity(forDot: index, at: phase))
        }
      }
      .frame(height: 17, alignment: .leading)
    }
    .accessibilityLabel("Pensando")
  }
}
