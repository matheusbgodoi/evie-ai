import EvieCore
import SwiftUI

struct BrainChipModel {
  var chip: EvieBrainChip
  var menu: EvieBrainMenu
  var onChoose: (EvieBrainChoice) -> Void
  var onTestConnection: () -> Void
  var onNewConversation: () -> Void
  var onSetAgentMode: ((Bool) -> Void)? = nil
  var onOpenSettings: ((EvieSettingsSection) -> Void)? = nil
  var onSetReasoning: ((ReasoningLevel) -> Void)? = nil
  var webEnabled = false
  var onSetWebSearch: ((Bool) -> Void)? = nil
  var isBusy = false
  /// Formatted last-send usage, including its source, e.g. "28.100 tokens
  /// (servidor)" or "~28.100 tokens (estimativa)". Percentage may be included.
  /// Absence means no usage has been reported for this conversation.
  var contextUsage: String? = nil
  var isCompacting = false
}

/// A fixed-width brain button preserves the writing area. Native popover
/// placement anchors the controls above the input without resizing the HUD.
struct BrainChipView: View {
  var model: BrainChipModel
  @State private var isExpanded = false

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: "brain")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(model.chip.isAgentModeOn ? BrainChipPalette.agent : .primary)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .background(.primary.opacity(0.045), in: Circle())
    .overlay {
      Circle().strokeBorder(
        model.chip.isAgentModeOn ? BrainChipPalette.agent.opacity(0.85) : .primary.opacity(0.10),
        lineWidth: model.chip.isAgentModeOn ? 1.25 : 0.5
      )
      .allowsHitTesting(false)
    }
    .overlay(alignment: .bottomTrailing) {
      BrainStateDot(state: model.chip.state)
        .padding(1.5)
        .background(.background, in: Circle())
        .offset(x: 1, y: 1)
        .allowsHitTesting(false)
    }
    .frame(width: 30, height: 30)
    .focusEffectDisabled()
    .help(model.chip.accessibilityLabel + " · modelo, raciocínio e modo agente")
    .accessibilityLabel("Cérebro e controles da Evie")
    .accessibilityValue(model.chip.accessibilityLabel)
    .accessibilityHint("Abre modelo, raciocínio, modo agente e pesquisa web")
    .popover(isPresented: $isExpanded, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      BrainControlsView(model: model)
    }
  }
}

struct BrainControlsView: View {
  var model: BrainChipModel

  private var isWorking: Bool { model.isBusy || model.isCompacting }

  var body: some View {
    ScrollView {
      controls
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(width: 330)
    .frame(maxHeight: 680)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "brain").font(.title2).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.chip.title).font(.headline)
          HStack(spacing: 5) {
            BrainStateDot(state: model.chip.state)
            Text(model.chip.stateDescription).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button(action: model.onTestConnection) {
          Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .help("Testar conexão com este cérebro")
        .accessibilityLabel("Testar conexão")
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("CÉREBRO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(model.menu.items) { item in
          Button {
            model.onChoose(item.choice)
          } label: {
            HStack(spacing: 9) {
              Image(systemName: item.choice.symbol).frame(width: 18)
              Text(item.title).font(.callout)
              Spacer(minLength: 4)
              if item.isSelected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
              .primary.opacity(item.isSelected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
          .disabled(!item.isAvailable || isWorking)
          .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
        }
        Text(
          isWorking
            ? "Pare a tarefa atual para trocar o cérebro."
            : "A escolha vale para a próxima resposta desta conversa."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      contextSummary
      if let setReasoning = model.onSetReasoning {
        VStack(alignment: .leading, spacing: 7) {
          Text("Raciocínio").font(.callout.weight(.medium))
          Picker(
            "Raciocínio",
            selection: Binding(
              get: { model.chip.profile.defaultReasoning }, set: { setReasoning($0) })
          ) {
            ForEach(ReasoningLevel.allCases, id: \.self) { level in
              Text(level.title).tag(level)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .disabled(isWorking || model.chip.profile.thinkingStyle == .none)
          Text("Desligado responde mais rápido; Máximo pode levar mais tempo.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      if let setAgent = model.onSetAgentMode {
        VStack(alignment: .leading, spacing: 5) {
          Toggle(
            "Permitir modo agente",
            isOn: Binding(
              get: { model.chip.isAgentModeOn }, set: { setAgent($0) })
          )
          .toggleStyle(.switch)
          Text(
            "Habilita sessões de controle do Mac. Só age quando você inicia uma tarefa; não fica controlando o computador o tempo todo."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let setWeb = model.onSetWebSearch {
        VStack(alignment: .leading, spacing: 5) {
          Toggle("Pesquisa na web", isOn: Binding(get: { model.webEnabled }, set: { setWeb($0) }))
            .toggleStyle(.switch)
          Text("Envia termos de busca ao DuckDuckGo e lê páginas públicas.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(18)
  }

  private var contextSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Contexto").font(.callout.weight(.medium))
        Spacer()
        Text("\(tokenCount(model.chip.profile.contextTokens)) tokens")
          .font(.callout.monospacedDigit())
      }
      Text("Saída: até \(tokenCount(model.chip.profile.maxCompletionTokens)) tokens")
        .font(.caption).foregroundStyle(.secondary)
      if let usage = model.contextUsage {
        Text("Último envio: \(usage)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 6) {
        if model.isCompacting {
          ProgressView().controlSize(.small)
            .accessibilityLabel("Compactando a conversa")
        } else {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        Text(model.isCompacting ? "Compactando a conversa…" : "Compactação automática")
      }
      .font(.caption).foregroundStyle(.secondary)
      Text("Histórico, entrada e resposta compartilham o limite de contexto.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func tokenCount(_ count: Int) -> String {
    count.formatted(.number.locale(Locale(identifier: "pt_BR")))
  }
}

extension EvieBrainChoice {
  fileprivate var symbol: String {
    switch self {
    case .automatic: "arrow.triangle.branch"
    case .alwaysPC: "desktopcomputer"
    case .alwaysMac: "laptopcomputer"
    }
  }
}

/// The chip's colours, in one place.
enum BrainChipPalette {
  /// The presence's acting amber, so "Agente" reads as the same act as the
  /// amber edge a session draws.
  static let agent = Color(nsColor: EviePresenceTint.acting)

  static func dot(_ state: EvieBrainChipState) -> Color {
    switch state {
    case .checking: .secondary
    case .ready: .green
    case .cold, .waking: .yellow
    case .unreachable: .red
    }
  }
}

/// The dot. Each state has its own shape as well as its own colour, so colour
/// is never the only signal: filled for ready and unreachable (with a cross
/// for the second), a ring for cold or not yet known, and a breathing dot while
/// the Mac brain wakes.
struct BrainStateDot: View {
  var state: EvieBrainChipState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      switch state {
      case .ready:
        Circle().fill(BrainChipPalette.dot(state))
      case .unreachable:
        Circle().fill(BrainChipPalette.dot(state))
        Image(systemName: "xmark")
          .font(.system(size: 4, weight: .black))
          .foregroundStyle(.white)
      case .cold, .checking:
        Circle().strokeBorder(BrainChipPalette.dot(state), lineWidth: 1.5)
      case .waking:
        if reduceMotion {
          Circle().fill(BrainChipPalette.dot(state))
        } else {
          // A 1.6 s breath: slow enough to read as "working", not as an
          // alarm, and only while the Mac brain starts.
          TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase =
              timeline.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: 1.6) / 1.6
            Circle()
              .fill(BrainChipPalette.dot(state))
              .opacity(0.35 + 0.65 * (0.5 + 0.5 * cos(phase * 2 * .pi)))
          }
        }
      }
    }
    .frame(width: 7, height: 7)
    .accessibilityHidden(true)
  }
}
