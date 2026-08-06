import SwiftUI

/// Sampling and response limits for the local model.
struct ModelSettingsView: View {
  @ObservedObject var viewModel: ModelSettingsViewModel

  var body: some View {
    Form {
      Section("Modelo local") {
        LabeledContent("Onde roda", value: "Somente neste Mac")
        LabeledContent(
          "Memória de contexto",
          value: "\(viewModel.contextWindowTokens.formatted()) tokens"
        )
      }

      Section("Amostragem") {
        Toggle("Usar temperatura padrão do servidor", isOn: $viewModel.usesDefaultTemperature)
          .disabled(viewModel.temperatureIsManaged)
          .help(managedHelp ?? "Deixa a escolha com o servidor local em vez de fixar um valor aqui")
        settingSlider(
          title: "Temperatura",
          value: $viewModel.temperature,
          range: 0...2,
          step: 0.05,
          description:
            "Valores menores deixam respostas mais consistentes; valores maiores, mais variadas.",
          help: "Quanto a resposta pode variar entre uma pergunta igual e outra",
          isDisabled: viewModel.usesDefaultTemperature || viewModel.temperatureIsManaged
        )

        Toggle("Usar top-p padrão do servidor", isOn: $viewModel.usesDefaultTopP)
          .disabled(viewModel.topPIsManaged)
          .help(managedHelp ?? "Deixa a escolha com o servidor local em vez de fixar um valor aqui")
        settingSlider(
          title: "Top-p",
          value: $viewModel.topP,
          range: viewModel.topPRange,
          step: 0.001,
          description: "Limita a massa de probabilidade considerada a cada token.",
          help: "Quantas das palavras mais prováveis entram no sorteio de cada token",
          isDisabled: viewModel.usesDefaultTopP || viewModel.topPIsManaged
        )

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Limite de resposta")
            Text("Não altera a janela de contexto do servidor.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Stepper(
            "\(viewModel.maxCompletionTokens.formatted()) tokens",
            value: $viewModel.maxCompletionTokens,
            in: viewModel.completionTokenRange,
            step: 256
          )
          .fixedSize()
          .disabled(viewModel.completionLimitIsManaged)
          .help(managedHelp ?? "O maior tamanho que uma resposta pode ter, em tokens")
          .accessibilityLabel("Limite de resposta")
        }

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Tempo limite")
            Text("Quanto esperar por uma resposta local antes de falhar.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Stepper(
            "\(Int(viewModel.requestTimeout)) s",
            value: $viewModel.requestTimeout,
            in: viewModel.timeoutRange,
            step: 1
          )
          .fixedSize()
          .disabled(viewModel.timeoutIsManaged)
          .help(managedHelp ?? "Quanto esperar por uma resposta local antes de desistir")
          .accessibilityLabel("Tempo limite")
        }

        if viewModel.hasManagedValues {
          Label(
            "Alguns campos são controlados por variáveis EVIE_MODEL_* e estão somente para leitura.",
            systemImage: "terminal"
          )
          .font(.caption)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
        }
      }

      if let feedback = viewModel.feedback {
        Section {
          Label(
            feedback.message,
            systemImage: feedback.isError
              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
          )
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(feedback.isError ? .red : .green)
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Restaurar amostragem recomendada") {
          viewModel.restoreRecommendedSampling()
        }
        .help("Devolve temperatura, top-p e limites aos valores que a Evie recomenda")
        Spacer()
        Button("Salvar") {
          viewModel.save()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .help("Grava estes valores; esta é a única aba que não aplica sozinha")
      }
      .padding(14)
      .background(.bar)
    }
  }

  /// The same sentence on every control the environment has taken over. Said in
  /// the help tag as well as in the note at the bottom of the section, because a
  /// greyed-out slider is exactly the thing somebody hovers to ask about.
  private var managedHelp: String? {
    viewModel.hasManagedValues
      ? "Este valor vem de uma variável EVIE_MODEL_* e por isso está travado"
      : nil
  }

  private func settingSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    description: String,
    help: String,
    isDisabled: Bool = false
  ) -> some View {
    let readout = value.wrappedValue.formatted(.number.precision(.fractionLength(2)))
    return VStack(alignment: .leading, spacing: 7) {
      // LabeledContent rather than Text/Spacer/Text: in a grouped Form it puts
      // the readout in the same column as every other value in the window.
      LabeledContent(title) {
        Text(readout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
        .accessibilityLabel(title)
        .accessibilityValue(readout)
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .disabled(isDisabled)
    .help(isDisabled ? (managedHelp ?? help) : help)
  }
}
