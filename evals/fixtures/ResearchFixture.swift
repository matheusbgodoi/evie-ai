import AppKit

/// A deliberately small, offline target. Only synthetic answers leave this
/// process, in the temporary file explicitly supplied by the diagnostic.
@MainActor
final class ResearchFixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  private var window: NSWindow!
  private let answer = NSTextField()
  private var buttons: [NSButton] = []
  private var selected = ""
  private let output: URL
  private let nonce: String

  init(output: URL, nonce: String) {
    self.output = output
    self.nonce = nonce
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Evie Research Fixture — offline"
    window.isReleasedWhenClosed = false
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 20
    for text in [
      "TESTE SINTÉTICO LOCAL", "Quanto é 17 × 4?",
      "Escreva o resultado e selecione a alternativa correspondente.",
    ] {
      let label = NSTextField(labelWithString: text)
      label.font = .systemFont(ofSize: text.count < 30 ? 26 : 18)
      stack.addArrangedSubview(label)
    }
    answer.placeholderString = "Resposta numérica"
    answer.setAccessibilityLabel("Resposta numérica")
    answer.font = .systemFont(ofSize: 25)
    answer.delegate = self
    answer.widthAnchor.constraint(equalToConstant: 300).isActive = true
    stack.addArrangedSubview(answer)
    for title in ["A) 64", "B) 68", "C) 72"] {
      let button = NSButton(
        radioButtonWithTitle: title, target: self, action: #selector(choose(_:)))
      button.font = .systemFont(ofSize: 24)
      buttons.append(button)
      stack.addArrangedSubview(button)
    }
    let content = window.contentView!
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
    ])
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(answer)
    NSApp.activate()
    writeState()
  }

  @objc private func choose(_ sender: NSButton) {
    selected = sender.title
    for button in buttons { button.state = button === sender ? .on : .off }
    writeState()
  }

  func controlTextDidChange(_ notification: Notification) { writeState() }
  func controlTextDidEndEditing(_ notification: Notification) { writeState() }

  private func writeState() {
    let displayedAnswer = answer.currentEditor()?.string ?? answer.stringValue
    let state: [String: Any] = [
      "nonce": nonce, "pid": ProcessInfo.processInfo.processIdentifier,
      "answer": displayedAnswer, "selected": selected,
    ]
    do {
      try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        .write(to: output, options: .atomic)
    } catch {
      fputs("fixture state write failed: \(error.localizedDescription)\n", stderr)
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count == 3 else { fatalError("Expected state-file and nonce") }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ResearchFixture(
  output: URL(fileURLWithPath: CommandLine.arguments[1]), nonce: CommandLine.arguments[2])
app.delegate = delegate
app.run()
