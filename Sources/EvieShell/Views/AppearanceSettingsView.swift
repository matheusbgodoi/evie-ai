import EvieCore
import SwiftUI

/// Where the overlay sits, how wide it is, and whether the mark moves.
struct AppearanceSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel

  private var appearance: EvieAppearancePreferences {
    viewModel.preferences.appearance
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 7) {
          // LabeledContent rather than a hand-built HStack: inside a grouped
          // Form it lines the readout up with every other value in the window.
          LabeledContent("Largura da janela") {
            Text("\(Int(appearance.resolvedOverlayWidth)) pt")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Slider(
            value: Binding(
              get: { appearance.resolvedOverlayWidth },
              set: viewModel.setOverlayWidth
            ),
            in: EvieAppearancePreferences
              .minimumOverlayWidth...EvieAppearancePreferences.maximumOverlayWidth,
            step: 4
          )
          .accessibilityLabel("Largura da janela")
          .accessibilityValue("\(Int(appearance.resolvedOverlayWidth)) pontos")
          .help("Quão larga a Evie aparece na tela, em pontos")
          Text(
            "Você também pode arrastar as bordas da própria janela; as duas coisas "
              + "mexem no mesmo valor."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Posição")
            Text(
              appearance.isUsingDefaultPlacement
                ? "No rodapé, centralizada — o padrão."
                : "Você moveu ou redimensionou a janela."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Voltar ao padrão") {
            viewModel.resetPlacement()
          }
          .disabled(appearance.isUsingDefaultPlacement)
          // A help tag still shows on a disabled control, so this is where the
          // reason it is greyed out gets said.
          .help(
            appearance.isUsingDefaultPlacement
              ? "A janela já está na posição e no tamanho padrão"
              : "Devolve a Evie ao rodapé da tela principal, centralizada"
          )
        }
      } header: {
        Text("Janela")
      } footer: {
        Text(
          "Arraste pela alça no topo da janela. Se o monitor onde ela estava for "
            + "desconectado, a Evie volta sozinha para o rodapé da tela principal."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(
          "Animar a marca",
          isOn: Binding(
            get: { appearance.animatesLogo },
            set: viewModel.setAnimatesLogo
          )
        )
        .help("Gira a chave devagar e a acende quando a Evie está ouvindo, pensando ou falando")
        Text(
          "A chave gira devagar em três dimensões enquanto a Evie está na tela, e "
            + "acende de verdade quando ela está ouvindo, pensando ou falando. "
            + "Escondida, ela não desenha nada. Reduzir movimento no macOS também "
            + "desliga isso."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("A marca")
      }

      Section {
        Toggle(
          "Deixar a Evie pesquisar na web",
          isOn: Binding(
            get: { viewModel.preferences.webSearchEnabled },
            set: viewModel.setWebSearchEnabled
          )
        )
        .help("A única coisa nesta Evie que envia algo para fora do seu Mac")
      } header: {
        Text("Internet")
      } footer: {
        Text(
          viewModel.preferences.webSearchEnabled
            ? """
              Ligado. Quando ela precisar, o que você perguntar é enviado a um \
              buscador e ela abre as páginas que encontrar. É a única coisa nesta \
              Evie que sai do seu Mac.
              """
            : """
              Desligado. Nada sai do seu Mac. Ela responde só do que sabe e das \
              suas pastas, e diz quando não sabe em vez de inventar.

              Ligando: o que você perguntar vai para um buscador (sem conta, sem \
              cadastro) e ela lê as páginas. É a única coisa aqui que sai da \
              máquina, por isso vem desligado.
              """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

    }
    .formStyle(.grouped)
  }
}
