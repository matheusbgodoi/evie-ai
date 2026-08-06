import EvieCore
import SwiftUI

/// The list of voices Evie can speak with, where they are chosen, removed, and
/// trained.
struct VoiceLibraryView: View {
  @ObservedObject var viewModel: EvieVoiceLibraryViewModel
  var onPreview: (() -> Void)?
  @StateObject private var deletion = VoiceDeletionPrompt()

  var body: some View {
    Form {
      Section {
        if viewModel.entries.filter({ !$0.isHidden }).isEmpty {
          Text("Nenhuma voz disponível.")
            .foregroundStyle(.secondary)
        }
        ForEach(viewModel.entries.filter { !$0.isHidden }) { entry in
          row(for: entry)
        }
        // Offered here because this is where somebody looking at a list with no
        // trained voices in it will be standing.
        if viewModel.canStartEngine {
          Button {
            Task { await viewModel.startEngine() }
          } label: {
            Label("Ligar o motor de voz", systemImage: "power")
          }
          .help("Sobe o motor local de voz clonada, que segura cerca de 2,4 GB enquanto roda")
        }
      } header: {
        Text("Vozes")
      } footer: {
        Text(
          viewModel.isEngineRunning
            ? "As vozes treinadas soam melhor e são apagadas de verdade ao remover. "
              + "As do sistema pertencem ao macOS: remover só tira da lista."
            : EvieVoiceEngineLauncher.isInstalled
              ? "O motor de voz está desligado, então só aparecem as vozes do sistema. "
                + "Ele sobe sozinho quando você pede pra ela falar com uma voz treinada."
              : "O motor de voz não está instalado neste Mac, então só há vozes do sistema."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if !viewModel.entries.filter({ $0.isHidden }).isEmpty {
        Section("Removidas da lista") {
          ForEach(viewModel.entries.filter { $0.isHidden }) { entry in
            HStack {
              Text(entry.name)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Trazer de volta") { viewModel.restore(entry) }
                .buttonStyle(.borderless)
                .help("Devolve esta voz à lista")
            }
          }
        }
      }

      Section {
        HStack {
          Button {
            viewModel.chooseAudio()
          } label: {
            Label("Escolher áudio…", systemImage: "waveform.badge.plus")
          }
          .help("Uma gravação limpa de dez a trinta segundos da voz a ser copiada")
          if let name = viewModel.pendingAudioName {
            Text(name)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        TextField("Nome da voz", text: $viewModel.newVoiceName)
          .help("Como esta voz vai aparecer na lista acima")
        TextField(
          "O que é falado na gravação (opcional, mas acelera muito)",
          text: $viewModel.newVoiceReferenceText,
          axis: .vertical
        )
        .lineLimit(2...4)
        .help("Sem isto, a primeira fala com esta voz gasta uns vinte e três segundos transcrevendo")

        Button {
          viewModel.trainPendingVoice()
        } label: {
          if viewModel.isBusy {
            // A spinner, not an hourglass symbol: an indeterminate wait is what
            // ProgressView is for, and the hourglass sat perfectly still.
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Treinando…")
            }
          } else {
            Label("Treinar esta voz", systemImage: "sparkles")
          }
        }
        .disabled(!viewModel.canTrain)
        .help(
          viewModel.canTrain
            ? "Cria a voz a partir da gravação escolhida"
            : "Escolha um áudio e dê um nome à voz primeiro"
        )
      } header: {
        Text("Adicionar uma voz")
      } footer: {
        Text(
          """
          Uma gravação limpa de dez a trinta segundos basta, sem música nem outra \
          pessoa por cima. Escrever o que é dito na gravação é opcional: sem isso, \
          a primeira vez que ela falar com essa voz gasta uns vinte e três segundos \
          transcrevendo — uma única vez, mas no meio de uma conversa.

          Use sua própria voz, a de alguém que autorizou, ou uma gravação de \
          domínio público. Áudio de serviço comercial de voz não serve: os termos \
          deles proíbem treinar outro modelo com aquilo, e a voz costuma ser de \
          uma pessoa real que consentiu com aquele serviço e não com este.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await viewModel.refresh() }
    // Deleting a trained voice destroys a file that took minutes to make and
    // cannot be undone, so it asks. Hiding a system voice is reversible one
    // section below and deliberately does not.
    .confirmationDialog(
      deletion.pending.map { "Apagar a voz “\($0.name)”?" } ?? "Apagar a voz?",
      isPresented: deletion.isPresented,
      titleVisibility: .visible
    ) {
      Button("Apagar", role: .destructive) {
        if let entry = deletion.pending {
          viewModel.remove(entry)
        }
        deletion.pending = nil
      }
      Button("Cancelar", role: .cancel) { deletion.pending = nil }
    } message: {
      Text("O arquivo treinado sai deste Mac e não tem como ser recuperado.")
    }
    .safeAreaInset(edge: .bottom) {
      if let feedback = viewModel.feedback {
        Label(
          feedback.message,
          systemImage: feedback.isError
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
        )
        .font(.callout)
        .foregroundStyle(feedback.isError ? .red : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
      }
    }
  }

  private func row(for entry: EvieVoiceLibraryViewModel.Entry) -> some View {
    HStack(spacing: 10) {
      // A real Button, not an Image with a tap gesture. A tap gesture is
      // invisible to the keyboard and to VoiceOver: with Full Keyboard Access
      // on there was no way to reach this at all, and VoiceOver read it as a
      // decorative image rather than as the thing that picks the voice.
      Button {
        viewModel.select(entry)
      } label: {
        Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(entry.isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
          // Apple's own swap for a symbol that changes meaning in place. It
          // reads as a no-op under Reduce Motion, so no guard is needed.
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Usar a voz \(entry.name)")
      .accessibilityAddTraits(entry.isSelected ? [.isSelected] : [])
      .help(entry.isSelected ? "Esta é a voz em uso" : "Passar a usar esta voz")

      VStack(alignment: .leading, spacing: 1) {
        Text(entry.name)
        Text(entry.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if entry.isSelected, let onPreview {
        Button("Ouvir", action: onPreview)
          .buttonStyle(.borderless)
          .help("Falar uma frase de exemplo com esta voz")
      }

      // Only a trained voice is actually destroyed. "Remover" on a system voice
      // hides a row the user can bring back below, so it gets neither the
      // destructive role nor the red that promises something irreversible.
      if entry.origin == .cloned {
        Button("Apagar", role: .destructive) {
          deletion.pending = entry
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .disabled(viewModel.isBusy)
        .help("Apaga o arquivo desta voz treinada deste Mac")
      } else {
        Button("Remover") {
          viewModel.remove(entry)
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.isBusy)
        .help("Tira esta voz do sistema da lista; ela continua instalada no macOS")
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { viewModel.select(entry) }
  }
}

/// Which trained voice is waiting on a confirmation.
///
/// This toolchain has no `@State`, and the library view model is shared with the
/// voice preferences pane, which has no business knowing that a sheet is open.
/// So the one piece of throwaway state this pane needs lives here.
@MainActor
private final class VoiceDeletionPrompt: ObservableObject {
  @Published var pending: EvieVoiceLibraryViewModel.Entry?

  var isPresented: Binding<Bool> {
    Binding(
      get: { self.pending != nil },
      set: { presented in
        if !presented {
          self.pending = nil
        }
      }
    )
  }
}
