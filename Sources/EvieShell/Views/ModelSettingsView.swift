import EvieCore
import SwiftUI

/// The "Cérebro" tab: which brain answers, what happens when the PC is out,
/// and each profile's address, model, limits, key and connection test.
///
/// Its own tab rather than a pane under Avançado: since the PC became the
/// default brain this is the first thing a fresh install needs — the key — and
/// the place every "O PC não respondeu" points to.
struct ModelSettingsView: View {
  @ObservedObject var viewModel: ModelSettingsViewModel

  var body: some View {
    Form {
      brainSection
      profileSection
      if viewModel.editingProfile.credential != nil {
        keySection
      }
      connectionSection
      samplingSection

      if let feedback = viewModel.feedback {
        Section {
          feedbackLabel(feedback)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { viewModel.refreshKeyStatus() }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Restaurar amostragem recomendada") {
          viewModel.restoreRecommendedSampling()
        }
        .help("Devolve temperatura e top-p deste cérebro aos valores que a Evie recomenda")
        Spacer()
        Button("Salvar") {
          viewModel.save()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSave)
        .help(
          viewModel.canSave
            ? "Grava estes valores; esta aba não aplica sozinha"
            : "Algum campo tem um valor que o cérebro não aceita"
        )
      }
      .padding(14)
      .background(.bar)
    }
  }

  // MARK: Sections

  private var brainSection: some View {
    Section {
      Picker("Cérebro principal", selection: $viewModel.preferredProfileID) {
        ForEach(viewModel.profiles.profiles) { profile in
          Text(profile.displayName).tag(profile.id)
        }
      }
      .help("O cérebro que responde primeiro em cada conversa nova")
      .onChange(of: viewModel.preferredProfileID) { _, id in
        viewModel.editingProfileID = id
      }

      Picker("Quando o PC estiver fora", selection: $viewModel.macFallback) {
        ForEach([MacFallback.off, .ask, .automatic], id: \.self) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .help("O cérebro do Mac ocupa cerca de 8 GB de memória enquanto está acordado")

      if let chosen = viewModel.profileChosenByEnvironment {
        note(
          "EVIE_MODEL_PROFILE escolhe \(chosen) nesta execução; a escolha acima vale a partir "
            + "da próxima vez que a Evie abrir sem essa variável.",
          systemImage: "terminal"
        )
      }
    } header: {
      Text("Cérebro")
    } footer: {
      Text(
        "Uma conversa fica no cérebro em que começou. Se o PC não responder antes da "
          + "primeira palavra, a Evie segue a escolha acima."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var profileSection: some View {
    let index = viewModel.editingIndex
    let managed = viewModel.managedFields
    return Section {
      if viewModel.profiles.profiles.count > 1 {
        Picker("Ajustar", selection: $viewModel.editingProfileID) {
          ForEach(viewModel.profiles.profiles) { profile in
            Text(profile.displayName).tag(profile.id)
          }
        }
        .pickerStyle(.segmented)
      }

      LabeledContent("Onde roda", value: viewModel.editingProfile.location.placeDescription)
      TextField("Nome exibido", text: $viewModel.drafts[index].displayName)
        .help("Seu nome para este cérebro, mostrado na barra e nas respostas")

      VStack(alignment: .leading, spacing: 4) {
        let fixedEndpoint = viewModel.editingProfile.fixedEndpointExplanation
        TextField("Endereço", text: $viewModel.drafts[index].endpoint)
          .font(.system(.body, design: .monospaced))
          .disabled(managed.contains(.endpoint) || fixedEndpoint != nil)
          .help(
            fixedEndpoint ?? managedHelp(managed, .endpoint)
              ?? "O endereço da API do servidor, terminado em /v1")
        if let problem = viewModel.endpointProblem {
          problemLabel(problem)
        }
      }

      HStack {
        TextField("Modelo", text: $viewModel.drafts[index].model)
          .font(.system(.body, design: .monospaced))
          .disabled(managed.contains(.model))
          .help(managedHelp(managed, .model) ?? "Exatamente o nome que o servidor dá ao modelo")
        Menu("Lista") {
          ForEach(viewModel.availableModels, id: \.self) { model in
            Button(model) { viewModel.drafts[index].model = model }
          }
        }
        .fixedSize()
        .disabled(viewModel.availableModels.isEmpty || managed.contains(.model))
        .help(
          viewModel.availableModels.isEmpty
            ? "Use Testar conexão para trazer a lista de modelos do servidor"
            : "Os modelos que o servidor listou no último teste"
        )
      }

      tokenStepper(
        title: "Contexto",
        caption: viewModel.contextLine,
        value: $viewModel.drafts[index].contextTokens,
        range: viewModel.contextTokenRange,
        step: 1_024,
        help: managedHelp(managed, .contextTokens)
          ?? "Quanto da conversa a Evie manda; o servidor pode guardar mais",
        isDisabled: managed.contains(.contextTokens)
      )

      tokenStepper(
        title: "Resposta máxima",
        caption: "O teto de uma resposta; perguntas comuns pedem bem menos.",
        value: $viewModel.drafts[index].maxCompletionTokens,
        range: viewModel.completionTokenRange,
        step: 256,
        help: managedHelp(managed, .maxCompletionTokens)
          ?? "O maior tamanho que uma resposta pode ter, em tokens",
        isDisabled: managed.contains(.maxCompletionTokens)
      )

      Picker("Raciocínio padrão", selection: $viewModel.drafts[index].defaultReasoning) {
        ForEach(ReasoningLevel.allCases, id: \.self) { level in
          Text(level.title).tag(level)
        }
      }
      .disabled(viewModel.editingProfile.thinkingStyle == .none)
      .help(
        viewModel.editingProfile.thinkingStyle == .none
          ? "Este servidor não recebe pedido de raciocínio"
          : "Pensar antes de responder custa segundos antes da primeira palavra"
      )

      if let problem = viewModel.draftProblem, viewModel.endpointProblem == nil {
        problemLabel(problem)
      }
      if !managed.isEmpty {
        note(
          "Alguns campos são controlados por variáveis EVIE_MODEL_* e estão somente para leitura.",
          systemImage: "terminal"
        )
      }
    } header: {
      Text(viewModel.editingProfile.displayName)
    }
  }

  private var keySection: some View {
    Section {
      LabeledContent("Chave") {
        Text(viewModel.editingKeyStatus?.text ?? "sem chave")
          .foregroundStyle(viewModel.editingKeyStatus == .saved ? .green : .secondary)
      }

      HStack {
        // Never filled from the keychain: what is saved is not shown back.
        SecureField("Colar chave", text: $viewModel.pastedKey)
          .textContentType(.password)
        Button("Salvar chave") {
          Task { await viewModel.saveKey() }
        }
        .disabled(viewModel.pastedKey.isEmpty || viewModel.isSavingKey || viewModel.isImportingKey)
      }

      if viewModel.offersKeyImport {
        VStack(alignment: .leading, spacing: 8) {
          // Said before the button is pressed; the first-run guide says the same.
          Text(EvieModelKeys.importPromptExplanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Importar da configuração do PC") {
              Task { await viewModel.importKey() }
            }
            .disabled(viewModel.isImportingKey || viewModel.isSavingKey)
            if viewModel.isImportingKey {
              ProgressView().controlSize(.small)
            }
          }
        }
      }

      if let feedback = viewModel.keyFeedback {
        feedbackLabel(feedback)
      }
    } header: {
      Text("Chave do gateway")
    } footer: {
      Text(
        "A chave fica no Keychain deste Mac, no item da Evie. Nunca vai para o "
          + "config.json, para os registros ou para o diagnóstico."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var connectionSection: some View {
    let profile = viewModel.editingProfile
    return Section("Conexão") {
      HStack {
        Button("Testar conexão") {
          Task { await viewModel.testConnection() }
        }
        .disabled(viewModel.testingProfileID != nil)
        .help(
          "Pergunta ao servidor se ele responde, se aceita a chave e se o modelo está carregado")
        if viewModel.testingProfileID == profile.id {
          ProgressView().controlSize(.small)
        }
      }

      if let report = viewModel.editingReport {
        ForEach(report.lines, id: \.step) { line in
          LabeledContent {
            HStack(spacing: 6) {
              if let elapsed = line.elapsed {
                Text(ModelConnectionReport.formatted(elapsed))
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
              }
              outcomeMark(line.outcome)
            }
          } label: {
            Text(report.title(of: line.step, for: profile))
          }
        }
        Text(report.summary(for: profile))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var samplingSection: some View {
    let index = viewModel.editingIndex
    let managed = viewModel.managedFields
    return Section("Amostragem") {
      Text(viewModel.editingProfile.samplingExplanation)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Aplicar receita recomendada deste perfil") { viewModel.restoreRecommendedSampling() }
        .disabled(managed.contains(.temperature) || managed.contains(.topP))
      Toggle(
        "Usar temperatura padrão do servidor",
        isOn: $viewModel.drafts[index].usesServerTemperature
      )
      .disabled(managed.contains(.temperature))
      .help(managedHelp(managed, .temperature) ?? "Deixa a escolha com o servidor")
      settingSlider(
        title: "Temperatura",
        value: $viewModel.drafts[index].temperature,
        range: 0...2,
        step: 0.05,
        description:
          "Valores menores deixam respostas mais consistentes; valores maiores, mais variadas.",
        help: managedHelp(managed, .temperature)
          ?? "Quanto a resposta pode variar entre uma pergunta igual e outra",
        isDisabled: viewModel.drafts[index].usesServerTemperature
          || managed.contains(.temperature)
      )

      Toggle("Usar top-p padrão do servidor", isOn: $viewModel.drafts[index].usesServerTopP)
        .disabled(managed.contains(.topP))
        .help(managedHelp(managed, .topP) ?? "Deixa a escolha com o servidor")
      settingSlider(
        title: "Top-p",
        value: $viewModel.drafts[index].topP,
        range: viewModel.topPRange,
        step: 0.001,
        description: "Limita a massa de probabilidade considerada a cada token.",
        help: managedHelp(managed, .topP)
          ?? "Quantas das palavras mais prováveis entram no sorteio de cada token",
        isDisabled: viewModel.drafts[index].usesServerTopP || managed.contains(.topP)
      )

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Tempo limite")
          Text("Quanto esperar por uma resposta antes de falhar.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Stepper(
          "\(Int(viewModel.drafts[index].requestTimeout)) s",
          value: $viewModel.drafts[index].requestTimeout,
          in: viewModel.timeoutRange,
          step: 1
        )
        .fixedSize()
        .disabled(managed.contains(.requestTimeout))
        .help(managedHelp(managed, .requestTimeout) ?? "Quanto esperar antes de desistir")
        .accessibilityLabel("Tempo limite")
      }
    }
  }

  // MARK: Pieces

  /// The same sentence on every control the environment has taken over: a
  /// greyed-out control is exactly the thing somebody hovers to ask about.
  private func managedHelp(_ managed: Set<EvieManagedField>, _ field: EvieManagedField)
    -> String?
  {
    managed.contains(field)
      ? "Este valor vem de \(field.rawValue) e por isso está travado"
      : nil
  }

  private func tokenStepper(
    title: String,
    caption: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    step: Int,
    help: String,
    isDisabled: Bool
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer()
      Stepper(
        "\(value.wrappedValue.formatted()) tokens",
        value: value,
        in: range,
        step: step
      )
      .fixedSize()
      .disabled(isDisabled)
      .help(help)
      .accessibilityLabel(title)
    }
  }

  /// A distinct shape per outcome, so colour is never the only signal.
  private func outcomeMark(_ outcome: ModelConnectionReport.Outcome) -> some View {
    let (symbol, color, label): (String, Color, String) =
      switch outcome {
      case .passed: ("checkmark.circle.fill", .green, "ok")
      case .failed: ("xmark.octagon.fill", .red, "falhou")
      case .notRun: ("minus.circle", .secondary, "não testado")
      case .notNeeded: ("circle.dashed", .secondary, "não precisa")
      }
    return Image(systemName: symbol)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
      .accessibilityLabel(label)
  }

  private func problemLabel(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.orange)
  }

  private func note(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.secondary)
  }

  private func feedbackLabel(_ feedback: ModelSettingsViewModel.Feedback) -> some View {
    Label(
      feedback.message,
      systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    )
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(feedback.isError ? .red : .green)
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
    .help(help)
  }
}
