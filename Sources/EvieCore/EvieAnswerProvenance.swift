import Foundation

/// Where an answer came from, worked out from what actually ran.
///
/// The instructions ask Evie to say which source she used. A model asked to
/// report on itself will sometimes say it consulted your notes when it did not,
/// and — worse — will sometimes forget to mention that it was working from
/// memory. That is exactly the case where the reader most needs to know.
///
/// So this is not asked of her. The loop knows which tools ran; the label is
/// computed from that record and cannot disagree with it. The prompt still asks
/// her to cite sources inside the answer, because a citation next to the claim is
/// more useful than a label under it — but the label is the one that is true by
/// construction.
public struct EvieAnswerProvenance: Hashable, Sendable {
  /// She read the user's own authorised folders and notes.
  public var usedLocalKnowledge: Bool
  /// She searched or opened pages on the web.
  public var usedWeb: Bool
  /// Addresses she actually opened, so they can be shown rather than promised.
  public var citedPages: [String]

  public init(
    usedLocalKnowledge: Bool = false,
    usedWeb: Bool = false,
    citedPages: [String] = []
  ) {
    self.usedLocalKnowledge = usedLocalKnowledge
    self.usedWeb = usedWeb
    self.citedPages = citedPages
  }

  /// True when nothing was consulted, which is the case worth warning about.
  public var usedOnlyItsOwnKnowledge: Bool {
    !usedLocalKnowledge && !usedWeb
  }

  /// Reads the record of a turn.
  public static func from(toolCalls names: [String], readAddresses: [String] = [])
    -> EvieAnswerProvenance
  {
    let local = Set(EvieFileToolbox.ToolName.allCases.map(\.rawValue))
    // `list_roots` alone is her finding out what she may look at, not looking.
    let looked = names.filter { local.contains($0) && $0 != EvieFileToolbox.ToolName.listRoots.rawValue }
    let web = names.filter { EvieWebTool(rawValue: $0) != nil }

    return EvieAnswerProvenance(
      usedLocalKnowledge: !looked.isEmpty,
      usedWeb: !web.isEmpty,
      citedPages: readAddresses
    )
  }

  /// The line shown under the answer.
  ///
  /// Never spoken and never part of the copied text: it is a note about the
  /// answer rather than part of it, and having Evie read "usei meu próprio
  /// conhecimento" out loud after every sentence would be unbearable.
  public var note: String {
    if usedLocalKnowledge, usedWeb {
      return "Usei suas anotações e a web" + citation
    }
    if usedLocalKnowledge {
      return "Usei suas anotações e arquivos"
    }
    if usedWeb {
      return "Usei a web" + citation
    }
    return "Usei só o que eu já sabia — pode conter erro, confira antes de usar"
  }

  private var citation: String {
    guard !citedPages.isEmpty else {
      return ""
    }
    let hosts =
      citedPages
      .compactMap { URL(string: $0)?.host }
      .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
      .reduce(into: [String]()) { unique, host in
        if !unique.contains(host) {
          unique.append(host)
        }
      }
    guard !hosts.isEmpty else {
      return ""
    }
    return " · " + hosts.prefix(3).joined(separator: ", ")
  }
}
