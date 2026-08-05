import EvieCore
import SwiftUI

/// What Evie has been taught, and where to teach her more.
struct SkillsSettingsView: View {
  @ObservedObject var viewModel: EvieSkillsViewModel

  var body: some View {
    Form {
      Section {
        if viewModel.skills.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Nenhuma habilidade instalada.")
            Text(
              """
              Uma habilidade é um arquivo de texto com instruções suas: como você \
              quer que ela revise um contrato, prepare uma reunião, escreva um \
              commit. Ela carrega só quando a sua pergunta bate com o assunto.
              """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        ForEach(viewModel.skills) { skill in
          row(for: skill)
        }
      } header: {
        Text("O que você ensinou a ela")
      } footer: {
        Text(
          """
          Instruções, não programas: uma habilidade ensina a usar o que ela já \
          sabe fazer, e não dá a ela nenhum poder novo. Desligar mantém o arquivo; \
          remover manda para o Lixo.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Button {
          viewModel.revealFolder()
        } label: {
          Label("Abrir a pasta das habilidades", systemImage: "folder")
        }
        Button {
          viewModel.reload()
        } label: {
          Label("Reler a pasta", systemImage: "arrow.clockwise")
        }
      } footer: {
        Text(
          "Escreva um arquivo .md nessa pasta e ele vira uma habilidade. "
            + "Abrindo pela primeira vez, deixo um exemplo lá para o formato ficar claro."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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

  private func row(for skill: EvieSkill) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { skill.isEnabled },
          set: { viewModel.setEnabled($0, for: skill) }
        )
      )
      .labelsHidden()

      VStack(alignment: .leading, spacing: 2) {
        Text(skill.name)
        Text("carrega quando você falar de: \(skill.when)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Button("Remover") { viewModel.remove(skill) }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
    }
    .padding(.vertical, 2)
  }
}
