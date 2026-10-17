import Foundation

/// What one turn builds from the brain it runs on: how much history fits, what
/// the persona says, whether tools are declared, whether pictures go, and the
/// options that pick its deadlines.
///
/// Built from a `ResolvedBrain` before the prompt exists, and built again from
/// the new brain after a failover — the PC's 200K budget, tools and pictures do
/// not fit the Mac's 128K, tool-less, possibly blind brain, so a prompt built for
/// one is never resent to the other.
public struct EvieTurnPlan: Sendable, Equatable {
  /// How the turn reaches the model.
  public enum Route: Sendable, Equatable {
    /// One request, no tools: nothing to look up, or nothing to look it up with.
    case directStream
    /// `EvieAgentLoop`: grounding first, then the model — with tools when
    /// `offersTools`, otherwise one request with what grounding found.
    case agentLoop(offersTools: Bool)
  }

  public let profile: EvieModelProfile
  public let readiness: ReadinessRung

  public init(profile: EvieModelProfile, readiness: ReadinessRung) {
    self.profile = profile
    self.readiness = readiness
  }

  public init(_ brain: ResolvedBrain) {
    self.init(profile: brain.profile, readiness: brain.rung)
  }

  /// How many characters of history and question the prompt may hold: about two
  /// per token of the profile's cap, less what the answer may use. This is an estimate, not
  /// a tokenizer count. The reply budget is reserved before history compaction.
  public var characterBudget: Int {
    let framingReserve = min(4_096, max(256, profile.contextTokens / 32))
    return max(0, profile.contextTokens - profile.maxCompletionTokens - framingReserve) * 2
  }

  /// The route for a turn with these sources switched on.
  ///
  /// A profile without tools still searches the folders and the web — before
  /// the request, in the loop's grounding step — and then asks once with no
  /// `tools` key: the Mac's LensVLM returns tool calls as malformed text in the
  /// answer (measured 2026-10-16), so offering it tools would put that text on
  /// screen. Mail and Calendar are reached only through tools, so for such a
  /// profile they add nothing to gather.
  ///
  /// A look at the screen is always one request: the capture is the subject,
  /// looking anything up first answers a different question, and every step of
  /// a loop would send the picture again.
  ///
  /// **A picture never rides with tools.** While the request carries one — a
  /// capture still replayed from an earlier turn, a pasted picture, or their
  /// recognised text (`carriesPicture`) — the turn takes the tool-less route a
  /// brain without tools takes. Text on the screen is whatever a web page, a
  /// message or an ad put there; with tools declared it could steer a web
  /// search (a query is a way out for what the screen shows) or a proposal.
  /// The folders and the web are still searched, before the model is asked,
  /// with the person's own question. The computer-use loop (S5) is the one
  /// exception, under its own policy and confirmations, and does not come
  /// through here.
  ///
  /// `asksAboutFiles` (`EvieFileIntent`) sends a question about the disk to the
  /// tools even when no folder is granted yet: "o que tem na minha mesa?" has
  /// to reach `list_roots` and the card that offers the Desktop, and answered
  /// without tools it could only be told she cannot look.
  public func route(
    hasRoots: Bool,
    searchesTheWeb: Bool,
    readsMailAndCalendar: Bool,
    looksAtScreen: Bool = false,
    carriesPicture: Bool = false,
    asksAboutFiles: Bool = false
  ) -> Route {
    if looksAtScreen {
      return .directStream
    }
    if profile.capabilities.tools, !carriesPicture {
      return hasRoots || searchesTheWeb || readsMailAndCalendar || asksAboutFiles
        ? .agentLoop(offersTools: true) : .directStream
    }
    return hasRoots || searchesTheWeb ? .agentLoop(offersTools: false) : .directStream
  }

  /// Whether a picture rides in `messages`, as pixels or as what was read or
  /// said about it (`ChatMessage.derivedFromPicture`): the recognised text and
  /// description a brain without vision gets, or a replayed picture turn
  /// whose picture became a marker. A marker in a message the conversation
  /// kept, the question as it was typed, does not count.
  public static func carriesPicture(_ messages: [ChatMessage]) -> Bool {
    messages.contains { !($0.images ?? []).isEmpty || $0.derivedFromPicture }
  }

  /// Whether a change may be applied without its card being clicked: only when
  /// the person turned that on, asked for a change, and no picture is in the
  /// request — the screen's text cannot be what approves a change.
  public static func autoApprovesChanges(_ requested: Bool, carriesPicture: Bool) -> Bool {
    requested && !carriesPicture
  }

  /// Whether a new document may be saved without its card being clicked
  /// (ADR 0019): the person switched "Salvar direto quando eu pedir
  /// explicitamente" on, their own message asked to save, and no picture is in
  /// the request — text on the screen never counts as asking.
  public static func savesDocumentsDirectly(_ requested: Bool, carriesPicture: Bool) -> Bool {
    requested && !carriesPicture
  }

  /// The capabilities the persona announces on this brain: where it runs, and
  /// nothing that needs a tool when it has none.
  public func capabilities(from base: EvieCapabilitySnapshot) -> EvieCapabilitySnapshot {
    var capabilities = base
    capabilities.whereItRuns = profile.location
    // A brain with vision sees the picture itself. Without it the system
    // describer may still say what a picture shows, which is what the base
    // snapshot reports.
    capabilities.seesImages = profile.capabilities.vision || base.seesImages
    if !profile.capabilities.tools {
      capabilities.usesTools = false
      capabilities.calculates = false
      capabilities.readsMailAndCalendar = false
    }
    return capabilities
  }

  /// A spoken or written answer's options, with the rung the brain was resolved
  /// at, which switches on the readiness deadlines.
  ///
  /// `looking` (a capture of the screen rides with the question) turns thinking
  /// off whatever the profile's default: the picture already costs the first
  /// token most of its wait on the PC.
  public func options(spoken: Bool, looking: Bool = false) -> TurnOptions {
    var configuration = profile.configuration
    if looking {
      configuration.defaultReasoning = .off
    }
    var options = spoken ? TurnOptions.voice(configuration) : .chat(configuration)
    options.readiness = readiness
    return options
  }

  /// The question as this brain receives it: the moment it was asked, then the
  /// words as typed — with `EvieBrevityPreamble`'s reminder only when the
  /// profile's family is the one that needs it.
  public func question(_ typed: String, askedAt timestamp: String) -> String {
    "[\(timestamp)] \(EvieBrevityPreamble.annotated(typed, for: profile.family))"
  }

  /// `history` (system prompt first) trimmed to the budget, oldest turns first,
  /// followed by `tail` — the messages this turn adds. Only the newest message
  /// with pictures keeps them, and none does when the profile does not take
  /// them; a picture left out becomes a marker in its message.
  public func prefix(_ history: [ChatMessage], then tail: [ChatMessage]) -> [ChatMessage] {
    let pictured = Self.keepingNewestPictures(history + tail, sees: profile.capabilities.vision)
    var kept = Array(pictured.prefix(history.count))
    let added = Array(pictured.suffix(tail.count))
    let tailLength = Self.characters(in: added)
    while kept.count > 1, Self.characters(in: kept) + tailLength > characterBudget {
      Self.removeOldestTurn(from: &kept)
    }
    return kept + added
  }

  /// Text by its length, each picture by `charactersPerImage`.
  static func characters(in messages: [ChatMessage]) -> Int {
    messages.reduce(0) { total, message in
      total + message.content.count + (message.images?.count ?? 0) * charactersPerImage
    }
  }

  /// Drops the oldest question and the answer after it, leaving the system
  /// prompt at index 0.
  static func removeOldestTurn(from messages: inout [ChatMessage]) {
    guard messages.count > 1 else {
      return
    }
    messages.remove(at: 1)
    if messages.count > 1, messages[1].role == .assistant {
      messages.remove(at: 1)
    }
  }
}
