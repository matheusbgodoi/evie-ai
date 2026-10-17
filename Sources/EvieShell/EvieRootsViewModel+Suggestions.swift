import EvieCore
import Foundation

// The well-known folders (Mesa, Documentos, Downloads, the Obsidian vault)
// offered as one-click grants, and the switch that lets a new document be
// saved without its card. ADR 0019.

extension EvieRootsViewModel {
  /// The suggestions that exist on this Mac and cannot be reached yet, in the
  /// order they are offered.
  var suggestedRoots: [EvieSuggestedRoot] {
    EvieSuggestedRoot.ungranted(in: roots, home: Self.homeURL)
  }

  /// Grants one well-known folder, after a person pressed the button for it.
  ///
  /// The path is the fixed one in `EvieSuggestedRoot`, never one a model
  /// produced. Right after recording it the folder is listed once, off the main
  /// thread, so macOS asks its own question (Desktop, Documents and Downloads
  /// are TCC folders) while the person is still looking — rather than in the
  /// middle of the next answer.
  @discardableResult
  func grantSuggested(_ suggestion: EvieSuggestedRoot) -> Bool {
    let url = suggestion.url(home: Self.homeURL)
    add(url, displayName: suggestion.displayName)
    let granted = suggestion.location(in: roots, home: Self.homeURL) != nil
    if granted {
      let path = url.path
      Task.detached(priority: .userInitiated) {
        _ = try? FileManager.default.contentsOfDirectory(atPath: path)
      }
    }
    return granted
  }

  func setSavesDocumentsWhenAsked(_ enabled: Bool) {
    savesDocumentsWhenAsked = enabled
    onDocumentPolicyChanged?(enabled)
    objectWillChange.send()
  }
}
