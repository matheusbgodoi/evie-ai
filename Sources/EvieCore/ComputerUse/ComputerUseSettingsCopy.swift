import Foundation

extension ComputerUseCopy {
  /// What is said when the switch flips, from Settings, the chip's menu or the
  /// menu bar.
  public static func switchMessage(enabled: Bool) -> String {
    enabled
      ? "Modo agente ligado. Cada sessão ainda começa só quando você pede e confirma."
      : "Modo agente desligado. Ela não controla mais o Mac."
  }

  /// The paragraph under "Deixar a Evie controlar o Mac" in Settings › Tela e
  /// modo agente: what the switch does, what it never does, and how to stop
  /// a session, in one place a person reads once.
  ///
  /// - Parameter stopShortcut: the "Parar tudo agora" combination as it is
  ///   bound now ("⌥⇧Esc"), or nil when it is switched off — then only the
  ///   ways that always work are named.
  public static func settingsExplanation(stopShortcut: String?) -> String {
    let stops = ["Esc", stopShortcut, "o botão Parar"].compactMap { $0 }
    let stopList = stops.dropLast().joined(separator: ", ") + " ou " + stops.last!
    return """
      Ligado, a Evie clica, digita e abre apps por você — mas só numa sessão que \
      você começa (segurando o atalho de falar ou em Controlar o Mac…) e confirma \
      no cartão. Cada sessão dura no máximo 15 minutos e, enquanto ela age, a \
      borda da tela fica âmbar. Para parar na hora: \(stopList). Ela pergunta \
      antes de enviar, comprar, apagar ou confirmar algo, e não mexe em Ajustes \
      do Sistema, no Terminal, no Acesso às Chaves nem em gerenciadores de senha. \
      Desligado, ela ainda olha a tela quando você pede, mas não clica, não \
      digita e não abre apps.
      """
  }
}
