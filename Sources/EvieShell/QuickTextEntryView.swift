import SwiftUI

struct QuickTextEntryView: View {
  @Binding var text: String
  var state: EvieVisualState = .ready
  var waveformSamples: [CGFloat] = []
  var isAnimating = true
  /// While true the send button is a stop button, because the thing you most
  /// want to do to a running answer is end it.
  var isProcessing = false
  var onSubmit: () -> Void
  var onCancel: () -> Void
  var onStop: (() -> Void)? = nil
  var onActivateVoice: (() -> Void)? = nil
  var onBrowseForFiles: (() -> Void)? = nil

  @FocusState private var isFocused: Bool

  private var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    GlassSurface(
      cornerRadius: 24,
      material: .hudWindow,
      contentPadding: EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 10),
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

        TextField("Pergunte à Evie…", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1...3)
          .focused($isFocused)
          .onSubmit(onSubmit)
          .accessibilityLabel("Comando para Evie")

        if let onBrowseForFiles {
          EvieGlowButton(
            systemImage: "paperclip",
            label: "Anexar uma imagem ou PDF — ou solte o arquivo aqui",
            tint: EvieVoiceTint.idle,
            diameter: 25,
            glyphSize: 11,
            action: onBrowseForFiles
          )
          .frame(width: 25, height: 25)
        }

        trailingButton
      }
    }
    .onAppear {
      isFocused = true
    }
    .onExitCommand(perform: onCancel)
  }

  @ViewBuilder
  private var trailingButton: some View {
    if isProcessing, let onStop {
      EvieGlowButton(
        systemImage: "stop.fill",
        label: "Parar a resposta",
        tint: .red,
        style: .filled,
        diameter: 27,
        glyphSize: 9,
        action: onStop
      )
      .frame(width: 27, height: 27)
      .transition(.scale.combined(with: .opacity))
    } else {
      EvieGlowButton(
        systemImage: "arrow.up",
        label: "Enviar",
        tint: EvieVoiceTint.idle,
        style: .filled,
        diameter: 27,
        glyphSize: 10,
        isEnabled: !isEmpty,
        action: onSubmit
      )
      .frame(width: 27, height: 27)
      .transition(.scale.combined(with: .opacity))
    }
  }
}
