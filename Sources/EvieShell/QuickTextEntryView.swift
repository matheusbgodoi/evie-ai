import SwiftUI

struct QuickTextEntryView: View {
  @Binding var text: String
  var state: EvieVisualState = .ready
  var waveformSamples: [CGFloat] = []
  var isAnimating = true
  var onSubmit: () -> Void
  var onCancel: () -> Void
  var onActivateVoice: (() -> Void)? = nil

  @FocusState private var isFocused: Bool

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

        Button(action: onSubmit) {
          Image(systemName: "arrow.up")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(EvieVoiceTint.idle, in: Circle())
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.42 : 1)
        .help("Enviar")
        .accessibilityLabel("Enviar comando")
      }
    }
    .onAppear {
      isFocused = true
    }
    .onExitCommand(perform: onCancel)
  }
}
