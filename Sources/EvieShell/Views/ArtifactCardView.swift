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
  var summary: String

  /// The answer with its markdown and LaTeX resolved. Parsed once here rather
  /// than on every redraw of a streaming card.
  var richSummary: EvieRichText {
    EvieRichText(summary)
  }
  var detail: String? = nil
  var source: String? = nil
  var isExpanded = false
  var isSensitive = false
  var actions: [ArtifactActionModel] = []
}

struct ArtifactCardView: View {
  var artifact: ArtifactCardModel
  var onToggleExpanded: (() -> Void)? = nil
  var onDismiss: (() -> Void)? = nil
  var onAction: ((ArtifactActionModel) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassSurface(
      cornerRadius: 20,
      material: .popover,
      contentPadding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 12),
      tint: artifact.kind.tint
    ) {
      VStack(alignment: .leading, spacing: 11) {
        header

        if artifact.isSensitive, !artifact.isExpanded {
          sensitivePreview
        } else {
          content
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
        Text(artifact.kind.title.uppercased())
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(artifact.kind.tint)
          .tracking(0.75)

        Text(artifact.title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(artifact.isExpanded ? 3 : 1)
      }

      Spacer(minLength: 8)

      if onToggleExpanded != nil {
        iconButton(
          symbol: artifact.isExpanded ? "chevron.down" : "chevron.up",
          label: artifact.isExpanded ? "Recolher" : "Expandir",
          action: { onToggleExpanded?() }
        )
      }

      if onDismiss != nil {
        iconButton(symbol: "xmark", label: "Fechar", action: { onDismiss?() })
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if artifact.isExpanded {
      EvieRichTextView(text: artifact.richSummary)
    } else {
      // Collapsed, the card is a glance: plain text reads better than a stack of
      // headings squeezed into three lines.
      Text(artifact.richSummary.plainText)
        .font(.callout)
        .foregroundStyle(.primary.opacity(0.88))
        .lineLimit(3)
        .textSelection(.enabled)
    }

    if artifact.isExpanded {
      if let detail = artifact.detail, !detail.isEmpty {
        Divider().opacity(0.42)

        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .transition(.opacity)
      }

      if let source = artifact.source, !source.isEmpty {
        Label(source, systemImage: "link")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
