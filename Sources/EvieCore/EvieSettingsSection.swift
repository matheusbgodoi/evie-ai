import Foundation

/// The settings window's sidebar, in the order it is drawn.
///
/// The window used to be six tabs with segmented panes inside them, and the
/// agent-mode switch sat in the fourth pane of Avançado. The owner could not
/// find it ("nem tem na verdade nas configurações", 2026-10-16), so Settings
/// became a sidebar in the style of System Settings: one row per question,
/// with room for as many rows as there are questions. Every pane that existed
/// is still reachable; only where it lives changed.
public enum EvieSettingsSection: String, CaseIterable, Identifiable, Sendable {
  case general
  case brain
  case screenAndAgent
  case filesAndFolders
  case voice
  case shortcuts
  case knowledge
  case appearance
  case permissions
  case advanced

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .general: "Geral"
    case .brain: "Cérebro"
    case .screenAndAgent: "Tela e modo agente"
    case .filesAndFolders: "Arquivos e pastas"
    case .voice: "Voz"
    case .shortcuts: "Atalhos"
    case .knowledge: "O que ela sabe"
    case .appearance: "Aparência"
    case .permissions: "Permissões"
    case .advanced: "Avançado"
    }
  }

  /// The SF Symbol on the row's tile.
  public var systemImage: String {
    switch self {
    case .general: "gearshape.fill"
    case .brain: "brain.head.profile"
    case .screenAndAgent: "macwindow.and.cursorarrow"
    case .filesAndFolders: "folder.fill"
    case .voice: "waveform"
    case .shortcuts: "keyboard.fill"
    case .knowledge: "books.vertical.fill"
    case .appearance: "paintpalette.fill"
    case .permissions: "hand.raised.fill"
    case .advanced: "wrench.and.screwdriver.fill"
    }
  }

  /// "Configurações › Tela e modo agente": how copy elsewhere points here,
  /// so a renamed section cannot leave a sentence pointing at nothing.
  public var path: String {
    "Configurações › \(title)"
  }
}
