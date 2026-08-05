import Foundation

/// Reassembles tool calls that arrive across streaming chunks.
///
/// The local server was measured delivering each call whole in a single delta,
/// but that is its implementation detail, not the protocol's: OpenAI's own
/// servers split a call's arguments across many chunks, and the fragment's
/// `index` is the only thing that says which call a piece belongs to. Assembling
/// by index costs nothing when the call arrives whole and is the difference
/// between working and truncated JSON when it does not.
struct EvieToolCallAccumulator {
  private struct Slot {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
  }

  private var slots: [Int: Slot] = [:]
  /// First-seen order, so the calls come back in the order the model asked for
  /// them rather than in whatever order a dictionary yields.
  private var order: [Int] = []

  var isEmpty: Bool {
    slots.isEmpty
  }

  /// Takes one fragment. Identity fields keep the first non-empty value seen;
  /// arguments concatenate, because that is the only field the wire splits.
  mutating func absorb(
    index: Int,
    id: String?,
    name: String?,
    argumentsFragment: String?
  ) {
    if slots[index] == nil {
      slots[index] = Slot()
      order.append(index)
    }
    guard var slot = slots[index] else {
      return
    }

    if let id, !id.isEmpty, slot.id.isEmpty {
      slot.id = id
    }
    if let name, !name.isEmpty, slot.name.isEmpty {
      slot.name = name
    }
    if let argumentsFragment, !argumentsFragment.isEmpty {
      slot.arguments += argumentsFragment
    }
    slots[index] = slot
  }

  /// The assembled calls.
  ///
  /// A call with no name is dropped: there is nothing to dispatch to, and
  /// inventing one would mean guessing. Empty arguments become `{}` so the
  /// decoder downstream always has an object to read.
  func calls() -> [EvieToolCall] {
    order.compactMap { index in
      guard let slot = slots[index], !slot.name.isEmpty else {
        return nil
      }
      let arguments = slot.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
      return EvieToolCall(
        id: slot.id.isEmpty ? "call_\(index)" : slot.id,
        name: slot.name,
        argumentsJSON: arguments.isEmpty ? "{}" : arguments
      )
    }
  }
}
