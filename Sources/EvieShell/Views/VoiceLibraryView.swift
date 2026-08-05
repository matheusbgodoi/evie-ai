import EvieCore
import SwiftUI

/// The list of voices Evie can speak with, where they are chosen, removed, and
/// trained.
struct VoiceLibraryView: View {
  @ObservedObject var viewModel: EvieVoiceLibraryViewModel
  var onPreview: (() -> Void)?

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
      } header: {
        Text("Vozes")
      } footer: {
        Text(
          viewModel.isEngineRunning
            ? "As vozes treinadas soam melhor e são apagadas de verdade ao remover. "
              + "As do sistema pertencem ao macOS: remover só tira da lista."
            : "O motor de voz está desligado, então só aparecem as vozes do sistema. "
              + "Rode Scripts/evie-voice start para treinar ou usar uma voz sua."
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
            }
          }
        }
      }

      Section {
        TextField(
          "Descreva a voz que você quer: \"feminina, jovem, grave, enérgica\"",
          text: $viewModel.wantedVoice
        )
        if !viewModel.wantedVoice.isEmpty {
          Text("Entendi: \(viewModel.design.summary)")
            .font(.caption)
            .foregroundStyle(.secondary)
          if !viewModel.ignoredFromDescription.isEmpty {
            Text(
              "Ignorei: \(viewModel.ignoredFromDescription.joined(separator: ", ")) — "
                + "o motor só entende gênero, idade, tom e estilo."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        ForEach(viewModel.suggestedArchetypes.prefix(8)) { archetype in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
              Text(archetype.name)
              Text(archetype.instruction.isEmpty ? archetype.useCase : archetype.instruction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button("Usar esta") { viewModel.adopt(archetype) }
              .buttonStyle(.borderless)
              .disabled(viewModel.isBusy)
          }
          .padding(.vertical, 1)
        }
      } header: {
        Text("Vozes prontas")
      } footer: {
        Text(
          """
          Estas vozes são desenhadas a partir de atributos, não copiadas de \
          ninguém — por isso podem ser usadas à vontade. Descreva o que você \
          gostou numa voz e a lista se ajusta.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Button {
            viewModel.chooseAudio()
          } label: {
            Label("Escolher áudio…", systemImage: "waveform.badge.plus")
          }
          if let name = viewModel.pendingAudioName {
            Text(name)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        TextField("Nome da voz", text: $viewModel.newVoiceName)
        TextField(
          "O que é falado na gravação (opcional, mas acelera muito)",
          text: $viewModel.newVoiceReferenceText,
          axis: .vertical
        )
        .lineLimit(2...4)

        Button {
          viewModel.trainPendingVoice()
        } label: {
          if viewModel.isBusy {
            Label("Treinando…", systemImage: "hourglass")
          } else {
            Label("Treinar esta voz", systemImage: "sparkles")
          }
        }
        .disabled(!viewModel.canTrain)
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
      Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(entry.isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
        .onTapGesture { viewModel.select(entry) }

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
      }

      Button(entry.origin == .cloned ? "Apagar" : "Remover") {
        viewModel.remove(entry)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .disabled(viewModel.isBusy)
    }
    .contentShape(Rectangle())
    .onTapGesture { viewModel.select(entry) }
  }
}
