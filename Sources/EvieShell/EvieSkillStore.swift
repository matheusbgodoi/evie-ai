import EvieCore
import Foundation

/// Where skills live on disk.
///
/// A folder of markdown files rather than a database, because the point of a
/// skill is that a person can write one. A file can be authored in any editor,
/// kept in the vault, copied between machines, and read six months later by
/// somebody who has never heard of this application. A row in a store can do none
/// of that.
struct EvieSkillStore: Sendable {
  /// A ceiling on how many are read, so a folder someone pointed at a thousand
  /// notes does not make every launch slow.
  static let maximumSkills = 60

  let directory: URL

  init(directory: URL = EvieSkillStore.defaultDirectory) {
    self.directory = directory
  }

  static var defaultDirectory: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("Skills", isDirectory: true)
  }

  /// Every skill on disk, by name.
  ///
  /// A file that cannot be parsed is skipped rather than failing the load: one
  /// malformed skill must not take the others with it.
  func load(disabled: Set<String> = []) -> [EvieSkill] {
    guard
      let names = try? FileManager.default.contentsOfDirectory(
        atPath: directory.path
      )
    else {
      return []
    }
    return
      names
      .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
      .sorted()
      .prefix(Self.maximumSkills)
      .compactMap { fileName -> EvieSkill? in
        guard
          let text = try? String(
            contentsOf: directory.appendingPathComponent(fileName),
            encoding: .utf8
          ),
          var skill = EvieSkill.parse(text, fileName: fileName)
        else {
          return nil
        }
        skill.isEnabled = !disabled.contains(fileName)
        return skill
      }
  }

  /// Writes one, creating the folder if this is the first.
  func save(_ skill: EvieSkill) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appendingPathComponent(skill.fileName)
    try Data(skill.markdown().utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  /// Deleting a skill sends the file to the Trash rather than unlinking it.
  ///
  /// Somebody may have spent an hour writing it, and the same rule that applies
  /// to the user's own files applies to this: nothing this application removes
  /// should be unrecoverable.
  func remove(_ skill: EvieSkill) throws {
    let url = directory.appendingPathComponent(skill.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }

  /// Writes an example the first time the folder is opened, so the format is
  /// obvious from a real file rather than from documentation.
  func createExampleIfEmpty() {
    guard load().isEmpty else {
      return
    }
    let example = EvieSkill(
      id: "exemplo.md",
      name: "Exemplo — apague ou edite este arquivo",
      when: "exemplo, como escrever uma skill",
      instructions: """
        Uma skill é um arquivo markdown nesta pasta. O bloco no topo diz o nome \
        dela e as palavras que fazem ela carregar; o resto são as instruções que \
        a Evie segue quando a sua pergunta bate com essas palavras.

        Escreva as instruções como você explicaria para uma pessoa: o que olhar \
        primeiro, o que costuma dar errado, como você gosta que o resultado seja \
        entregue.

        Ela só carrega quando bate — o que não bate não custa nada.
        """,
      fileName: "exemplo.md"
    )
    try? save(example)
  }
}
