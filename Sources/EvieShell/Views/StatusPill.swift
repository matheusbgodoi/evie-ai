import SwiftUI

enum EvieVisualState: String, CaseIterable, Hashable {
  case ready
  case listening
  case transcribing
  case thinking
  case usingTool
  case speaking
  case awaitingApproval
  case completed
  case error

  var title: String {
    switch self {
    case .ready: "Evie"
    case .listening: "Ouvindo"
    case .transcribing: "Transcrevendo"
    case .thinking: "Pensando"
    case .usingTool: "Executando"
    case .speaking: "Falando"
    case .awaitingApproval: "Sua aprovação"
    case .completed: "Concluído"
    case .error: "Algo deu errado"
    }
  }

  var symbolName: String {
    switch self {
    case .ready: "key.fill"
    case .listening: "mic.fill"
    case .transcribing: "text.bubble.fill"
    case .thinking: "ellipsis"
    case .usingTool: "gearshape.2.fill"
    case .speaking: "waveform"
    case .awaitingApproval: "hand.raised.fill"
    case .completed: "checkmark"
    case .error: "exclamationmark"
    }
  }

  /// Listening and speaking deliberately reuse the two voice hues so the same
  /// colour always means the same direction of audio, wherever it appears.
  var tint: Color {
    switch self {
    case .ready: EvieVoiceTint.idle
    case .listening: EvieVoiceTint.input
    case .transcribing: .cyan
    case .thinking: EvieVoiceTint.idle
    case .usingTool: .blue
    case .speaking: EvieVoiceTint.output
    case .awaitingApproval: .orange
    case .completed: .green
    case .error: .red
    }
  }

  var waveformDirection: WaveformDirection? {
    switch self {
    case .listening: .input
    case .speaking: .output
    default: nil
    }
  }
}

/// The compact, bottom-anchored interaction surface. Voice activity can update
/// the samples while text/status changes remain concise and transient.
struct CommandCapsule: View {
  var state: EvieVisualState
  var primaryText: String
  var secondaryText: String? = nil
  var waveformSamples: [CGFloat] = []
  var isMuted = false
  var isAnimating = true
  var onToggleMute: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  var onOpenDetails: (() -> Void)? = nil
  var onActivateVoice: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassSurface(
      cornerRadius: 24,
      material: .hudWindow,
      contentPadding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10),
      tint: state.tint
    ) {
      HStack(spacing: 11) {
        EvieMarkView(
          state: state,
          waveformSamples: waveformSamples,
          diameter: 30,
          isAnimating: isAnimating,
          onActivate: onActivateVoice
        )

        capsuleContent
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          if let onToggleMute, state == .listening || state == .speaking {
            capsuleButton(
              symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
              label: isMuted ? "Ativar áudio" : "Silenciar áudio",
              action: onToggleMute
            )
          }

          if let onCancel, cancellableStates.contains(state) {
            capsuleButton(
              symbol: "xmark",
              label: "Cancelar",
              action: onCancel
            )
          }

          if let onOpenDetails {
            capsuleButton(
              symbol: "arrow.up.left.and.arrow.down.right",
              label: "Abrir detalhes",
              action: onOpenDetails
            )
          }
        }
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.26), value: state)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var capsuleContent: some View {
    if let direction = state.waveformDirection, !waveformSamples.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        WaveformView(
          samples: waveformSamples,
          direction: direction,
          tint: state.tint,
          isActive: !isMuted,
          barCount: 24
        )
        .frame(height: 25)

        if !primaryText.isEmpty {
          Text(primaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 2) {
        Text(primaryText.isEmpty ? state.title : primaryText)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
          .contentTransition(.opacity)

        if let secondaryText, !secondaryText.isEmpty {
          Text(secondaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func capsuleButton(
    symbol: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(.white.opacity(0.06), in: Circle())
    .help(label)
    .accessibilityLabel(label)
  }

  private var cancellableStates: Set<EvieVisualState> {
    [.listening, .transcribing, .thinking, .usingTool, .speaking]
  }
}
