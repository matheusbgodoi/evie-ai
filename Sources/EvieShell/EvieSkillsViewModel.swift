import AppKit
import EvieCore
import Foundation

/// The skills installed, and the only place they are turned on and off.
///
/// A skill that is switched off stays on disk. Deleting is a separate act, and
/// somebody may have spent an hour writing the file — the same reasoning that
/// makes deleting a user's file mean the Trash applies to their own instructions.
@MainActor
final class EvieSkillsViewModel: ObservableObject {
  @Published private(set) var skills: [EvieSkill] = []
  @Published private(set) var feedback: Feedback?

  struct Feedback: Equatable {
    var message: String
    var isError: Bool
  }

  private let store: EvieSkillStore
  private let disabledFileURL: URL

  init(store: EvieSkillStore = EvieSkillStore()) {
    self.store = store
    disabledFileURL = store.directory
      .deletingLastPathComponent()
      .appendingPathComponent("skills-disabled.json", isDirectory: false)
    reload()
  }

  var directory: URL {
    store.directory
  }

  func reload() {
    skills = store.load(disabled: disabledNames())
  }

  /// Opens the folder, creating an example the first time so the format is
  /// obvious from a real file rather than from a paragraph about it.
  func revealFolder() {
    try? FileManager.default.createDirectory(
      at: store.directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    store.createExampleIfEmpty()
    reload()
    NSWorkspace.shared.open(store.directory)
  }

  func install(_ skill: EvieSkill) {
    do {
      try store.save(skill)
      reload()
      feedback = Feedback(message: "Guardei \"\(skill.name)\".", isError: false)
    } catch {
      feedback = Feedback(message: "Não consegui guardar essa habilidade.", isError: true)
    }
  }

  func setEnabled(_ enabled: Bool, for skill: EvieSkill) {
    var names = disabledNames()
    if enabled {
      names.remove(skill.fileName)
    } else {
      names.insert(skill.fileName)
    }
    writeDisabled(names)
    reload()
  }

  func remove(_ skill: EvieSkill) {
    do {
      try store.remove(skill)
      var names = disabledNames()
      names.remove(skill.fileName)
      writeDisabled(names)
      reload()
      feedback = Feedback(
        message: "\"\(skill.name)\" foi para o Lixo — dá para recuperar de lá.",
        isError: false
      )
    } catch {
      feedback = Feedback(message: "Não consegui remover essa habilidade.", isError: true)
    }
  }
}

extension EvieSkillsViewModel {
  /// Which skills are switched off. Kept beside the folder rather than inside the
  /// files, so turning one off does not rewrite something the user authored.
  fileprivate func disabledNames() -> Set<String> {
    guard let data = try? Data(contentsOf: disabledFileURL),
      let names = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return Set(names)
  }

  fileprivate func writeDisabled(_ names: Set<String>) {
    guard let data = try? JSONEncoder().encode(Array(names).sorted()) else {
      return
    }
    try? FileManager.default.createDirectory(
      at: disabledFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: disabledFileURL, options: .atomic)
  }
}
