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
        settingSlider(
          title: "Temperatura",
          value: $viewModel.temperature,
          range: 0...2,
          step: 0.05,
          description:
            "Valores menores deixam respostas mais consistentes; valores maiores, mais variadas.",
          isDisabled: viewModel.usesDefaultTemperature || viewModel.temperatureIsManaged
        )

        Toggle("Usar top-p padrão do servidor", isOn: $viewModel.usesDefaultTopP)
          .disabled(viewModel.topPIsManaged)
        settingSlider(
          title: "Top-p",
          value: $viewModel.topP,
          range: viewModel.topPRange,
          step: 0.001,
          description: "Limita a massa de probabilidade considerada a cada token.",
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
        }

        if viewModel.hasManagedValues {
          Label(
            "Alguns campos são controlados por variáveis EVIE_MODEL_* e estão somente para leitura.",
            systemImage: "terminal"
          )
          .font(.caption)
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
        Spacer()
        Button("Salvar") {
          viewModel.save()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
      .background(.bar)
    }
  }

  private func settingSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    description: String,
    isDisabled: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
        Spacer()
        Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .disabled(isDisabled)
  }
}
