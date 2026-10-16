import Foundation

/// What one turn builds from the brain it runs on: how much history fits, what
/// the persona says, whether tools are declared, whether pictures go, and the
/// options that pick its deadlines.
///
/// Built from a `ResolvedBrain` before the prompt exists, and built again from
/// the new brain after a failover — the PC's 135K budget, tools and pictures do
/// not fit the Mac's 32K, tool-less, possibly blind brain, so a prompt built for
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
  /// per token of the profile's cap, less what the answer may use. The PC gets
  /// 237,568 and the Mac 61,440. The floor keeps a tiny custom profile usable.
  public var characterBudget: Int {
    max(8_000, (profile.contextTokens - profile.maxCompletionTokens) * 2)
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
  public func route(
    hasRoots: Bool,
    searchesTheWeb: Bool,
    readsMailAndCalendar: Bool,
    looksAtScreen: Bool = false
  ) -> Route {
    if looksAtScreen {
      return .directStream
    }
    if profile.capabilities.tools {
      return hasRoots || searchesTheWeb || readsMailAndCalendar
        ? .agentLoop(offersTools: true) : .directStream
    }
    return hasRoots || searchesTheWeb ? .agentLoop(offersTools: false) : .directStream
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
