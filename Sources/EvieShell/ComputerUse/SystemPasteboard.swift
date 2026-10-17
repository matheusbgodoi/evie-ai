import AppKit
import EvieCore

/// The general pasteboard, for `ClipboardSession`, which holds every rule
/// about saving and restoring it.
///
/// A snapshot reads every type of every item, so what comes back is what the
/// person copied, rich text and images included. A type the writing app only
/// promised is produced by that app when it is read here, as a paste would.
@MainActor
final class SystemPasteboard: EviePasteboard {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  var changeCount: Int {
    pasteboard.changeCount
  }

  func items() -> [PasteboardItemSnapshot] {
    (pasteboard.pasteboardItems ?? []).map { item in
      PasteboardItemSnapshot(
        representations: item.types.compactMap { type in
          item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
        })
    }
  }

  func replace(with items: [PasteboardItemSnapshot]) -> Int {
    pasteboard.clearContents()
    let written = items.map { snapshot in
      let item = NSPasteboardItem()
      for representation in snapshot.representations {
        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
      }
      return item
    }
    if !written.isEmpty {
      pasteboard.writeObjects(written)
    }
    return pasteboard.changeCount
  }
}
