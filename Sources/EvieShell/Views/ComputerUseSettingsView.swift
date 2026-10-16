import EvieCore
import SwiftUI

/// The switch for agent mode: Evie clicking, typing and opening apps on this
/// Mac.
///
/// It comes on, because the owner asked for it, so the pane says plainly
/// what the switch does not do: it never starts anything. Each session still
/// begins with a key held or a button clicked and a confirm on the session
/// card, and lasts at most 15 minutes (ADR 0016). `EVIE_COMPUTER_USE=0` turns
/// it off for one launch, whatever is set here, and the pane says so.
///
/// The setter arrives from outside, as in `MailCalendarSettingsView`, so the
/// write goes through the view model's feedback line.
struct ComputerUseSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel
  var setEnabled: @MainActor @Sendable (Bool) -> Void
  var environment: [String: String] = ProcessInfo.processInfo.environment

  private var forcedOff: Bool {
    ComputerUseSwitch.forcedOff(environment: environment)
  }

  var body: some View {
    Form {
      Section {
        Toggle(
          "Deixar a Evie controlar o Mac (modo agente)",
          isOn: Binding(
            get: { viewModel.preferences.computerUseEnabled },
            set: setEnabled
          )
        )
        .help("Ela clica, digita e abre apps por você, só numa sessão que você começa.")
        if forcedOff {
          Text(
            "Desligado nesta execução por EVIE_COMPUTER_USE=0, seja qual for este ajuste."
          )
          .font(.footnote)
          .foregroundStyle(.orange)
        }
      } header: {
        Text("Controle do Mac")
      } footer: {
        Text(
          viewModel.preferences.computerUseEnabled
            ? """
              Ligado. Isso não começa nada sozinho: cada sessão começa só quando \
              você segura o atalho de falar ou clica num botão e confirma no \
              cartão, e dura no máximo 15 minutos. Enquanto ela age, a borda da \
              tela fica âmbar; Esc, Parar ou ⌥⇧Esc encerram na hora.

              Ela pergunta antes de enviar, comprar, apagar ou confirmar algo, e \
              não mexe em Ajustes do Sistema, no Terminal, no Acesso às Chaves \
              nem em gerenciadores de senha. Campos de senha, você digita.
              """
            : """
              Desligado. Ela pode olhar a tela quando você pede, mas não clica, \
              não digita e não abre apps.
              """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Text(
          """
          O que aparece na tela é escrito por quem fez a página ou o app. A \
          Evie trata isso como informação, nunca como ordem, e as regras que \
          decidem o que ela pode fazer estão no código, não no modelo — isso \
          reduz o risco de uma página tentar comandá-la, mas não o elimina.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } header: {
        Text("O que a tela pode tentar")
      }
    }
    .formStyle(.grouped)
  }
}
