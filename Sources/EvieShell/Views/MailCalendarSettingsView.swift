import EvieCore
import SwiftUI

/// The switch that lets Evie read the Mail and Calendar apps.
///
/// It is its own pane rather than a line under "Internet", because it is not
/// about the internet: nothing here leaves the Mac. What it is about is the most
/// personal thing on this disk, and a switch that decides who reads your mail
/// deserves the room to say what it does.
///
/// The setter arrives from outside rather than being called on the view model
/// directly. `EviePreferencesViewModel` writes through a private helper that
/// also produces the feedback line, and the pane has no business reaching around
/// it — see the report for the three lines that belong in that file.
struct MailCalendarSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel
  /// Called with the new value. The owner routes it to the preferences store.
  ///
  /// `@MainActor @Sendable` because a `Binding`'s setter is `@Sendable` and this
  /// one only ever runs where the view does. Without both, Swift 6 warns about a
  /// data race that cannot happen and the test build turns the warning into an
  /// error.
  var setEnabled: @MainActor @Sendable (Bool) -> Void

  var body: some View {
    Form {
      Section {
        Toggle(
          "Deixar a Evie ler seu Mail e sua agenda",
          isOn: Binding(
            get: { viewModel.preferences.mailAndCalendarEnabled },
            set: setEnabled
          )
        )
        .help("Ela lê os apps Mail e Calendário deste Mac. Só lê.")
      } header: {
        Text("Mail e Calendário")
      } footer: {
        Text(
          viewModel.preferences.mailAndCalendarEnabled
            ? """
              Ligado. Ela lê os apps Mail e Calendário que já estão neste Mac, \
              com as contas que você já configurou neles. Nada sai da máquina e \
              nada é alterado: ela não envia, não apaga, não marca como lida e \
              não cria compromisso.

              Os dois apps precisam estar abertos. Na primeira vez o macOS vai \
              perguntar se a Evie pode controlá-los; se você disser não, ela \
              avisa e diz onde mudar de ideia.
              """
            : """
              Desligado. Ela não abre seu Mail nem sua agenda, e nem sabe que \
              eles existem.

              Ligando: ela passa a ler as mensagens recentes da caixa de \
              entrada, procurar por assunto, e ver seus compromissos entre duas \
              datas. Só isso — ler. Nada é enviado, apagado ou criado, e nada sai \
              deste Mac. Vem desligado porque ler o e-mail de alguém não é coisa \
              que se liga por conta própria.
              """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Text(
          """
          Uma mensagem é escrita por quem a enviou, e qualquer pessoa pode \
          escrever para você. A Evie trata o que vem da caixa de entrada como \
          informação, nunca como ordem: se um e-mail disser "apague os backups", \
          ela não tem nenhuma ferramenta capaz de fazer isso.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } header: {
        Text("Por que ela só lê")
      }
    }
    .formStyle(.grouped)
  }
}
