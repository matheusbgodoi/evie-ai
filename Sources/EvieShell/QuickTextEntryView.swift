import SwiftUI

struct QuickTextEntryView: View {
  @Binding var text: String
  var endpointDescription: String
  var onSubmit: () -> Void
  var onCancel: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    GlassSurface(
      cornerRadius: 24,
      material: .hudWindow,
      contentPadding: EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 10),
      tint: .indigo
    ) {
      HStack(spacing: 11) {
        Image(systemName: "sparkles")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 27, height: 27)
          .background(.indigo, in: Circle())
          .accessibilityHidden(true)

        TextField("Pergunte à Evie…", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1...3)
          .focused($isFocused)
          .onSubmit(onSubmit)
          .accessibilityLabel("Comando para Evie")

        Text(endpointDescription)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityLabel("Servidor local \(endpointDescription)")

        Button(action: onSubmit) {
          Image(systemName: "arrow.up")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.indigo, in: Circle())
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
