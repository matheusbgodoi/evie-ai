import EvieCore
import SwiftUI

/// What Evie does on her own, and when.
struct SchedulesSettingsView: View {
  @ObservedObject var viewModel: EvieSchedulesViewModel

  var body: some View {
    Form {
      if viewModel.isEditing {
        editor
      } else {
        list
      }
    }
    .formStyle(.grouped)
    .settingsFeedback(
      viewModel.feedback?.message,
      isError: viewModel.feedback?.isError == true
    )
  }

  private var list: some View {
    Group {
      Section {
        if viewModel.schedules.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Nenhum agendamento.")
            Text(
              """
              Um agendamento é um pedido seu com uma hora marcada: "toda manhã às \
              8, resuma meus e-mails não lidos". Ela acorda, faz, avisa e volta \
              a dormir — entre uma vez e outra não fica nada rodando.
              """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        ForEach(viewModel.schedules) { schedule in
          row(for: schedule)
        }
      } header: {
        Text("O que ela faz sozinha")
      } footer: {
        Text(
          """
          Quem guarda a hora é o macOS, não a Evie. Se o Mac estiver dormindo na \
          hora marcada, ela roda assim que ele acordar. Duas coisas marcadas para \
          a mesma hora não rodam juntas: a segunda é pulada, porque o modelo \
          atende uma de cada vez.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Button {
          viewModel.beginNewSchedule()
        } label: {
          Label("Novo agendamento", systemImage: "plus")
        }
      }
    }
  }

  private func row(for schedule: EvieSchedule) -> some View {
    HStack(alignment: .top, spacing: 10) {
      // The name is given to the toggle and then hidden, rather than left empty:
      // `labelsHidden` stops it being drawn but keeps it as the accessibility
      // name, so VoiceOver does not read a column of anonymous switches.
      Toggle(
        schedule.name,
        isOn: Binding(
          get: { schedule.isEnabled },
          set: { viewModel.setEnabled($0, for: schedule) }
        )
      )
      .labelsHidden()
      .help(schedule.isEnabled ? "Desligar sem apagar" : "Voltar a agendar")

      VStack(alignment: .leading, spacing: 2) {
        Text(schedule.name)
        Text(schedule.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(schedule.prompt)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()

      Button("Testar") { viewModel.runNow(schedule) }
        .buttonStyle(.borderless)
        .disabled(viewModel.runningID == schedule.id)
        .help("Roda agora, do mesmo jeito que vai rodar na hora marcada")
        .accessibilityLabel("Testar o agendamento \(schedule.name)")

      Button("Editar") { viewModel.beginEditing(schedule) }
        .buttonStyle(.borderless)
        .accessibilityLabel("Editar o agendamento \(schedule.name)")

      Button("Apagar", role: .destructive) { viewModel.remove(schedule) }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .help("Apaga o agendamento e tira o trabalho do macOS")
        .accessibilityLabel("Apagar o agendamento \(schedule.name)")
    }
    .padding(.vertical, 2)
    .contextMenu {
      Button("Ver o registro da última vez") { viewModel.revealLog(for: schedule) }
    }
  }

  private var editor: some View {
    Group {
      Section {
        TextField("Nome", text: $viewModel.draftName)
          .help("Como este agendamento aparece aqui e no aviso na tela")
        VStack(alignment: .leading, spacing: 4) {
          Text("O que ela deve fazer")
            .font(.caption)
            .foregroundStyle(.secondary)
          // A multi-line field because this is a request written the way it
          // would be typed to her, not a title.
          TextEditor(text: $viewModel.draftPrompt)
            .font(.body)
            .frame(minHeight: 80)
            .accessibilityLabel("O que ela deve fazer")
        }
      } header: {
        Text(viewModel.editingID == nil ? "Novo agendamento" : "Editando")
      } footer: {
        Text(
          "Escreva como você escreveria na janela dela. Ela responde com as mesmas "
            + "ferramentas: as pastas que você liberou e, se estiver ligada, a web."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Picker("Quando", selection: $viewModel.draftKind) {
          Text("Todo dia").tag(0)
          Text("Dias da semana").tag(1)
          Text("Quando uma pasta mudar").tag(2)
        }
        .pickerStyle(.segmented)

        if viewModel.draftKind == 2 {
          HStack {
            Text(viewModel.draftFolder.isEmpty ? "Nenhuma pasta escolhida" : viewModel.draftFolder)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
            Spacer()
            Button("Escolher…") { viewModel.chooseFolder() }
          }
        } else {
          if viewModel.draftKind == 1 {
            weekdayPicker
          }
          HStack {
            Picker("Hora", selection: $viewModel.draftHour) {
              ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d", hour)).tag(hour)
              }
            }
            .frame(maxWidth: 140)
            Picker("Minuto", selection: $viewModel.draftMinute) {
              ForEach(0..<60, id: \.self) { minute in
                Text(String(format: "%02d", minute)).tag(minute)
              }
            }
            .frame(maxWidth: 150)
          }
        }
      } footer: {
        if viewModel.draftKind == 2 {
          Text(
            "Ela roda quando algo aparecer ou mudar nessa pasta, e espera pelo menos "
              + "um minuto entre uma vez e outra — senão dez arquivos de uma vez "
              + "virariam dez execuções."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }

      Section {
        HStack {
          Button("Cancelar") { viewModel.cancelEditing() }
          Spacer()
          Button("Guardar") { viewModel.saveDraft() }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSaveDraft)
        }
      }
    }
  }

  private var weekdayPicker: some View {
    HStack(spacing: 6) {
      // Sunday first, matching the calendar this Mac draws and the numbering
      // `launchd` uses, so the button in position three is the day in position
      // three everywhere else.
      ForEach(Array(Self.weekdayNames.enumerated()), id: \.offset) { index, name in
        Toggle(
          name,
          isOn: Binding(
            get: { viewModel.draftWeekdays.contains(index) },
            set: { chosen in
              if chosen {
                viewModel.draftWeekdays.insert(index)
              } else {
                viewModel.draftWeekdays.remove(index)
              }
            }
          )
        )
        .toggleStyle(.button)
        .accessibilityLabel(Self.weekdayFullNames[index])
      }
    }
  }

  private static let weekdayNames = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
  private static let weekdayFullNames = [
    "domingo", "segunda-feira", "terça-feira", "quarta-feira",
    "quinta-feira", "sexta-feira", "sábado",
  ]
}
