import EvieCore
import SwiftUI

/// Everything the brain chip draws and does, bundled so the input bar takes
/// one value instead of seven.
struct BrainChipModel {
  var chip: EvieBrainChip
  var menu: EvieBrainMenu
  var onChoose: (EvieBrainChoice) -> Void
  var onTestConnection: () -> Void
  var onNewConversation: () -> Void
  /// Nil when agent mode cannot be switched from here.
  var onSetAgentMode: ((Bool) -> Void)? = nil
  var onOpenSettings: ((EvieSettingsSection) -> Void)? = nil
}

/// The chip in the input bar: which brain the next question goes to, a dot for
/// whether it can answer, and agent mode when it is on. Clicking it opens the
/// menu that pins the brain for the next conversation.
///
/// Small and quiet on purpose: it is read when wanted, like the clock in the
/// menu bar, and the field beside it is what the bar is for.
struct BrainChipView: View {
  var model: BrainChipModel

  private var chip: EvieBrainChip { model.chip }

  var body: some View {
    Menu {
      menuContent
    } label: {
      label
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .focusEffectDisabled()
    .fixedSize()
    .help(help)
    .accessibilityLabel("Cérebro")
    .accessibilityValue(chip.accessibilityLabel)
    .accessibilityHint("Abre o menu para escolher o cérebro das próximas conversas")
  }

  private var help: String {
    var lines = [
      "\(chip.profile.displayModelName) \(chip.profile.location.answerPlace): \(chip.stateDescription)"
    ]
    if chip.isAgentModeOn {
      lines.append("Modo agente ligado: ela pode controlar o Mac numa sessão que você começar.")
    }
    lines.append("Clique para escolher o cérebro ou testar a conexão.")
    return lines.joined(separator: "\n")
  }

  /// A capsule drawn as a continuous rounded rectangle: `Capsule`'s stroke
  /// left a hairline tick at each end at this size.
  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 11, style: .continuous)
  }

  private var label: some View {
    HStack(spacing: 0) {
      if chip.isAgentModeOn {
        // A pill inside the pill: agent mode is a state of its own, not part
        // of the brain's name.
        HStack(spacing: 4) {
          Image(systemName: "cursorarrow.click.2")
            .font(.system(size: 9, weight: .semibold))
          Text("Agente")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(BrainChipPalette.agent)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(BrainChipPalette.agent.opacity(0.16), in: Capsule())
        .padding(.leading, 2)
        .accessibilityHidden(true)
      }

      HStack(spacing: 6) {
        BrainStateDot(state: chip.state)
        Text(chip.title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.primary.opacity(0.82))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(.tertiary)
      }
      .padding(.leading, chip.isAgentModeOn ? 6 : 8)
      .padding(.trailing, 8)
    }
    .frame(height: 22)
    .background(.primary.opacity(0.06), in: shape)
    .overlay {
      shape.strokeBorder(
        chip.isAgentModeOn ? BrainChipPalette.agent.opacity(0.5) : .primary.opacity(0.10),
        lineWidth: 0.75
      )
    }
    .contentShape(shape)
  }

  @ViewBuilder
  private var menuContent: some View {
    Section("Próximas conversas") {
      ForEach(model.menu.items) { item in
        Toggle(
          item.title,
          isOn: Binding(
            get: { item.isSelected },
            set: { if $0 { model.onChoose(item.choice) } }
          )
        )
        .disabled(!item.isAvailable)
      }
    }

    if let note = model.menu.pinnedNote {
      Section {
        Text(note)
        Button(
          "Começar nova conversa", systemImage: "square.and.pencil", action: model.onNewConversation
        )
      }
    }

    Section {
      Button(
        "Testar conexão", systemImage: "antenna.radiowaves.left.and.right",
        action: model.onTestConnection)
      if let onOpenSettings = model.onOpenSettings {
        Button("\(model.menu.reasoningLine)…", systemImage: "brain") {
          onOpenSettings(.brain)
        }
      }
    }

    if let onSetAgentMode = model.onSetAgentMode {
      Section {
        Toggle(
          "Modo agente (controlar o Mac)",
          isOn: Binding(get: { chip.isAgentModeOn }, set: { onSetAgentMode($0) })
        )
        if let onOpenSettings = model.onOpenSettings {
          Button("Tela e modo agente…", systemImage: "macwindow.and.cursorarrow") {
            onOpenSettings(.screenAndAgent)
          }
        }
      }
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
