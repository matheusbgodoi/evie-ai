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

  var body: some View {
    Form {
      Section {
        Label(
          "Nada de voz está ligado ainda neste build: microfone, transcrição e fala "
            + "chegam na próxima etapa. O que você ajustar aqui já fica guardado.",
          systemImage: "hourglass"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

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
            ? "As respostas saem em áudio além do texto."
            : "As respostas ficam só escritas, mesmo quando você perguntar falando."
        )

        Toggle(
          "Modo ligação",
          isOn: Binding(get: { voice.callModeEnabled }, set: viewModel.setCallModeEnabled)
        )
        captionRow(
          "Some com o texto: fica só a marca da Evie e as ondas em volta, "
            + "de um lado quando você fala e de outro quando ela fala."
        )

        dependencyNote
      } header: {
        Text("Como ela responde")
      } footer: {
        Text(presentationSummary)
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
