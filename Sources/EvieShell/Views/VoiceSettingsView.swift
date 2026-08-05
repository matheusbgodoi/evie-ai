import EvieCore
import SwiftUI

/// How Evie listens and whether she answers out loud.
///
/// The two output switches are genuinely coupled, so the interface says so in
/// place instead of letting the user flip one and watch the other move without
/// explanation.
struct VoiceSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel

  private var voice: EvieVoicePreferences {
    viewModel.preferences.voice
  }

  private var voices: [EvieVoiceOption] {
    EvieSpeechOutput.availableVoices()
  }

  /// Says plainly whether the cloned engine is available, and what it costs.
  @ViewBuilder
  private var engineStatus: some View {
    if viewModel.isVoiceEngineRunning {
      Label(
        "Motor de voz clonada no ar, \(viewModel.clonedVoices.count) voz(es) sua(s). "
          + "Ele segura cerca de 2,4 GB enquanto estiver ligado.",
        systemImage: "waveform.circle.fill"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } else {
      Label(
        "Motor de voz clonada desligado — só as vozes do sistema aparecem. "
          + "Ligue com Scripts/evie-voice start.",
        systemImage: "powerplug"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var rateDescription: String {
    switch voice.resolvedSpeechRate {
    case ..<0.42: "devagar"
    case ..<0.56: "normal"
    case ..<0.66: "rápida"
    default: "bem rápida"
    }
  }

  var body: some View {
    Form {
      Section("Como você chama a Evie") {
        Toggle(
          "Segurar o atalho para falar",
          isOn: Binding(get: { voice.pushToTalkEnabled }, set: viewModel.setPushToTalkEnabled)
        )
        captionRow(
          "Enquanto a tecla estiver pressionada o microfone fica aberto. "
            + "A combinação está em Atalhos, hoje "
            + (viewModel.shortcut(for: .pushToTalk)?.displayString ?? "desativada")
            + "."
        )

        Toggle(
          "Atender quando eu chamar pelo nome",
          isOn: Binding(get: { voice.wakeWordEnabled }, set: viewModel.setWakeWordEnabled)
        )
        captionRow(
          "Exige o microfone permanentemente aberto para um detector minúsculo. "
            + "O indicador do microfone fica visível o tempo todo, e o custo de bateria "
            + "precisa ser medido antes de virar padrão."
        )

        TextField(
          "Frase de ativação",
          text: Binding(get: { voice.wakePhrase }, set: viewModel.setWakePhrase)
        )
        .disabled(!voice.wakeWordEnabled)
      }

      Section {
        Toggle(
          "A Evie responde falando",
          isOn: Binding(get: { voice.speechOutputEnabled }, set: viewModel.setSpeechOutputEnabled)
        )
        captionRow(
          voice.speechOutputEnabled
            ? "Ela responde falando quando você fala com ela. Falar por cima interrompe."
            : "As respostas ficam só escritas, mesmo quando você perguntar falando."
        )

        Toggle(
          "Falar também quando eu digitar",
          isOn: Binding(
            get: { voice.speaksTypedAnswers },
            set: viewModel.setSpeaksTypedAnswers
          )
        )
        .disabled(!voice.speechOutputEnabled)
        captionRow(
          voice.speaksTypedAnswers
            ? "Ela lê toda resposta em voz alta, inclusive as que você pediu escrevendo."
            : "Perguntou escrevendo, ela responde escrevendo. Perguntou falando, ela fala."
        )

        Picker(
          "Capricho da voz treinada",
          selection: Binding(
            get: { viewModel.preferences.voice.resolvedQualitySteps },
            set: viewModel.setVoiceQualitySteps
          )
        ) {
          Text("Rápida").tag(8)
          Text("Equilibrada").tag(16)
          Text("Caprichada").tag(32)
        }
        .pickerStyle(.segmented)
        captionRow(
          "Quantas passadas o motor dá em cada frase. Mais passadas soam mais "
            + "perto da gravação de referência e demoram mais. Só vale para vozes "
            + "treinadas; as do sistema ignoram isto."
        )

        Toggle(
          "Modo ligação",
          isOn: Binding(get: { voice.callModeEnabled }, set: viewModel.setCallModeEnabled)
        )
        captionRow(
          "Com isto ligado, clicar na marca troca a tela inteira por voz — só a "
            + "Evie e as ondas em volta, nada escrito. Clicar de novo volta para o "
            + "texto. Durante a ligação, quando ela para de falar o microfone "
            + "reabre sozinho."
        )

        dependencyNote
      } header: {
        Text("Como ela responde")
      } footer: {
        Text(presentationSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        if voices.isEmpty {
          Label(
            "Este Mac não tem nenhuma voz em português instalada. Ajustes do Sistema › "
              + "Acessibilidade › Conteúdo Falado › Vozes do sistema.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Picker(
            "Voz",
            selection: Binding(
              get: { viewModel.selectedVoiceKey },
              set: { viewModel.selectVoice(key: $0) }
            )
          ) {
            if !viewModel.clonedVoices.isEmpty {
              Section("Clonadas") {
                ForEach(viewModel.clonedVoices) { cloned in
                  Text(cloned.name).tag("cloned:\(cloned.id)")
                }
              }
            }
            Section("Do sistema") {
              ForEach(voices) { option in
                Text(option.displayName).tag("system:\(option.id)")
              }
            }
          }
          .disabled(!voice.speechOutputEnabled)

          engineStatus

          VStack(alignment: .leading, spacing: 7) {
            HStack {
              Text("Velocidade")
              Spacer()
              Text(rateDescription)
                .foregroundStyle(.secondary)
            }
            Slider(
              value: Binding(
                get: { voice.resolvedSpeechRate },
                set: viewModel.setSpeechRate
              ),
              in: 0.3...0.75
            )
          }
          .disabled(!voice.speechOutputEnabled)

          HStack {
            Button("Ouvir uma frase") {
              viewModel.testVoice()
            }
            .disabled(!voice.speechOutputEnabled)
            Spacer()
          }
        }
      } header: {
        Text("A voz dela")
      } footer: {
        Text(
          "As vozes naturais da Siri aparecem no sistema mas o macOS não deixa um "
            + "aplicativo de terceiros usá-las, então a lista do sistema é o que sobra "
            + "e soa datada. Uma voz clonada é criada uma vez e vira um arquivo: a "
            + "referência não é reenviada a cada fala. Medido aqui: 2,3 s até o "
            + "primeiro som contra 0,6 s da voz do sistema."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Privacidade do áudio") {
        Toggle(
          "Guardar o áudio bruto neste Mac",
          isOn: Binding(get: { voice.retainsRawAudio }, set: viewModel.setRetainsRawAudio)
        )
        captionRow(
          voice.retainsRawAudio
            ? "As gravações ficam salvas até você apagar. Use só para diagnóstico."
            : "O áudio é descartado assim que vira texto. Este é o padrão."
        )
      }
    }
    .formStyle(.grouped)
    .task {
      await viewModel.refreshVoiceEngine()
    }
  }

  /// Spelled out rather than enforced silently: the switch the user cannot turn
  /// on is explained where they are looking.
  @ViewBuilder
  private var dependencyNote: some View {
    Label(
      voice.callModeEnabled
        ? "Uma ligação sem voz seria um círculo mudo, então desligar a fala também sai do modo ligação."
        : "Para entrar no modo ligação a fala precisa estar ligada.",
      systemImage: "link"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var presentationSummary: String {
    switch voice.presentation {
    case .textOnly:
      "Agora: tudo escrito. Mesmo perguntando por voz, a resposta aparece como texto."
    case .textAndSpeech:
      "Agora: sua transcrição e a resposta aparecem escritas, e ela também fala."
    case .call:
      "Agora: conversa por voz, sem nada escrito na tela."
    }
  }

  private func captionRow(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
