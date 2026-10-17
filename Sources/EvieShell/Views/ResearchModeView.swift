import EvieCore
import SwiftUI

struct ResearchModeView: View {
  @ObservedObject var controller: ResearchModeController

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Pesquisa assistida", systemImage: "viewfinder")
        .font(.title2.weight(.semibold))
      Text(
        "Ative uma sessão, volte à tarefa e use o atalho de executar. A Evie fica em segundo plano entre os pedidos."
      )
      .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        Text("Objetivo autorizado").font(.headline)
        TextEditor(text: $controller.goal)
          .font(.body)
          .frame(height: 90)
          .padding(6)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        Picker("Ao executar", selection: $controller.destination) {
          ForEach(EvieResearchDestination.allCases, id: \.self) { destination in
            Text(destination.title).tag(destination)
          }
        }
      }
      .disabled(controller.isArmed || controller.isRunning)
      Text(
        "Cada pedido captura a tela sob o ponteiro. A captura vai ao cérebro selecionado, no seu PC ou Mac. Capturas e respostas não são salvas no histórico. O clipboard anterior é substituído somente ao concluir a análise."
      )
      .font(.callout)
      Text(
        "A sessão expira em 15 minutos e exige nova ativação. O controle do Mac precisa do modo agente e das permissões do macOS. A captura e as ações mantêm os indicadores; ações sensíveis ainda pedem sua confirmação. Parar tudo cancela imediatamente."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Text(controller.status)
        .font(.callout.weight(.medium))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if !controller.actionLog.isEmpty {
        ScrollView {
          Text(controller.actionLog).font(.caption).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 70)
      }
      Spacer(minLength: 0)
      HStack {
        Button("Exportar medições…") { controller.exportMeasurements() }
        Spacer()
        if controller.isArmed || controller.isRunning {
          Button("Desativar e parar", role: .destructive) { controller.stop() }
        } else {
          Text("Ativar por 15 minutos")
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.tint, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
              HandPressCatcher(title: "Ativar pesquisa por 15 minutos") {
                controller.arm(by: $0)
              })
        }
      }
      Text("Os dois atalhos podem ser alterados em Configurações → Atalhos.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 580, height: 600)
  }
}
