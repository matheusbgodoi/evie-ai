import Foundation

/// One brain Evie can use: where it is, what it is called there, how much it
/// holds and what it can do.
///
/// Since schema v2 the configuration file is a list of these rather than one
/// endpoint. The client still reads an `EvieConfiguration`; `configuration` is
/// the profile flattened into that shape, so nothing downstream of the loader had
/// to learn about profiles in the same change.
///
/// Like the configuration, a profile holds a *reference* to a key, never a key.
public struct EvieModelProfile: Codable, Sendable, Identifiable, Equatable {
  public static let pcProfileID = "pc-3090"
  public static let macProfileID = "mac-local"
  /// The id a migrated v1 file's single endpoint is kept under.
  public static let customProfileID = "custom"

  public struct Capabilities: Codable, Sendable, Equatable {
    /// Whether the model takes pixels (`image_url` parts). Without it a picture
    /// reaches the model only as OCR text and a description.
    public var vision: Bool
    /// Whether the model is offered tools. Off means no `tools` key at all and
    /// the direct stream with evidence gathered beforehand.
    public var tools: Bool

    public init(vision: Bool, tools: Bool) {
      self.vision = vision
      self.tools = tools
    }
  }

  /// Whether Evie starts the server or only talks to one that already runs.
  public enum Runtime: Sendable, Equatable {
    /// A server Evie does not start: the PC gateway, or any endpoint a person
    /// typed in (a migrated v1 loopback server is one too — `Scripts/evie-runtime`
    /// starts it, not Evie).
    case remoteGateway
    /// A loopback server Evie launches when a turn needs it and stops when idle.
    case localOnDemand(LocalRuntime)
  }

  public let id: String
  public var displayName: String
  public var endpoint: URL
  /// Exactly the id the server answers to. For a local server that is the
  /// `--model` it was launched with, so a request can never make it load another.
  public var model: String
  /// The client's cap, which the context budget uses. Smaller than the server's
  /// on the PC on purpose: an uncached prefill at 150K tokens took 250 s there.
  public var contextTokens: Int
  /// What the server itself holds, for display only; nothing is budgeted on it.
  public var serverContextTokens: Int?
  public var maxCompletionTokens: Int
  public var capabilities: Capabilities
  public var thinkingStyle: ThinkingParameterStyle
  public var defaultReasoning: ReasoningLevel
  public var credential: CredentialReference?
  public var runtime: Runtime
  public var location: ModelLocation
  public var family: ModelFamily
  public var coordinateConvention: CoordinateConvention
  /// Sampling and timeout, per profile because they were per file in v1 and the
  /// settings pane still edits them. The PC gateway overwrites temperature and
  /// top-p for qwen-daily whatever is sent, so `nil` — "the server's" — is the
  /// built-in.
  public var temperature: Double?
  public var topP: Double?
  public var stopSequences: [String]
  public var requestTimeout: TimeInterval

  public init(
    id: String,
    displayName: String,
    endpoint: URL,
    model: String,
    contextTokens: Int,
    serverContextTokens: Int? = nil,
    maxCompletionTokens: Int,
    capabilities: Capabilities,
    thinkingStyle: ThinkingParameterStyle,
    defaultReasoning: ReasoningLevel = .off,
    credential: CredentialReference? = nil,
    runtime: Runtime,
    location: ModelLocation,
    family: ModelFamily,
    coordinateConvention: CoordinateConvention,
    temperature: Double? = nil,
    topP: Double? = nil,
    stopSequences: [String] = [],
    requestTimeout: TimeInterval = 300
  ) {
    self.id = id
    self.displayName = displayName
    self.endpoint = endpoint
    self.model = model
    self.contextTokens = contextTokens
    self.serverContextTokens = serverContextTokens
    self.maxCompletionTokens = maxCompletionTokens
    self.capabilities = capabilities
    self.thinkingStyle = thinkingStyle
    self.defaultReasoning = defaultReasoning
    self.credential = credential
    self.runtime = runtime
    self.location = location
    self.family = family
    self.coordinateConvention = coordinateConvention
    self.temperature = temperature
    self.topP = topP
    self.stopSequences = stopSequences
    self.requestTimeout = requestTimeout
  }

  /// The profile in the shape the model client reads.
  public var configuration: EvieConfiguration {
    EvieConfiguration(
      endpoint: endpoint,
      model: model,
      contextWindowTokens: contextTokens,
      maxCompletionTokens: maxCompletionTokens,
      temperature: temperature,
      topP: topP,
      stopSequences: stopSequences,
      requestTimeout: requestTimeout,
      credential: credential,
      thinkingStyle: thinkingStyle,
      defaultReasoning: defaultReasoning
    )
  }
}

/// How a local server is launched (ADR 0015).
public struct LocalRuntime: Codable, Sendable, Equatable {
  /// Which server program the executable is, which decides its argv
  /// (`LocalBrainPolicy.makeArguments`). Only mlx-vlm's: checked 2026-10-16,
  /// `mlx_vlm.server` 0.7.8 serves LensVLM's images, since the vision tower is
  /// in the main safetensors, so the alternatives the design listed
  /// (`optiq serve`, a wrapper of Evie's own) were never needed.
  public enum Launcher: String, Codable, Sendable {
    case mlxVLM
  }

  public var launcher: Launcher
  /// An absolute path, never looked up on `$PATH`, so whatever is first on the
  /// path cannot be launched in its place.
  public var executable: String
  public var port: Int
  /// The server's KV cache cap, matched to the client's context cap: the Mac's
  /// Metal working set is 17.8 GB and the weights take about 8 of it.
  public var maxKVSize: Int

  private enum CodingKeys: String, CodingKey {
    case launcher
    case executable
    case port
    case maxKVSize = "max_kv_size"
  }

  public init(launcher: Launcher, executable: String, port: Int, maxKVSize: Int) {
    self.launcher = launcher
    self.executable = executable
    self.port = port
    self.maxKVSize = maxKVSize
  }
}

/// Where the model runs, which decides what Evie may say about where a
/// conversation goes.
public enum ModelLocation: String, Codable, Sendable {
  case yourPC
  case thisMac
}

/// The model's lineage, for prompt adjustments measured on one family only.
public enum ModelFamily: String, Codable, Sendable {
  case qwen
  case gemma
  case unknown

  /// A guess from the served id, for a profile nobody labelled — a migrated v1
  /// endpoint. Built-in profiles state their family.
  public init(guessingFromModel model: String) {
    let name = model.lowercased()
    if name.contains("qwen") {
      self = .qwen
    } else if name.contains("gemma") {
      self = .gemma
    } else {
      self = .unknown
    }
  }
}

/// How the model writes a screen point: Qwen-VL models answer on a 0–1000 grid,
/// others in pixels of the image they were sent.
public enum CoordinateConvention: String, Codable, Sendable {
  case normalized1000
  case pixels
}

/// What happens when the PC is out before a turn has produced anything.
public enum MacFallback: String, Codable, Sendable {
  case off
  case ask
  case automatic
}

/// Every profile Evie knows, in the order she prefers them.
///
/// A profile can be present without being in `preferenceOrder`: a migrated v1
/// endpoint is kept that way, so it can be selected by name
/// (`EVIE_MODEL_PROFILE`) but never wins over the built-ins by itself.
public struct EvieModelProfileSet: Codable, Sendable, Equatable {
  public var profiles: [EvieModelProfile]
  public var preferenceOrder: [String]
  public var macFallback: MacFallback

  private enum CodingKeys: String, CodingKey {
    case profiles
    case preferenceOrder = "preference_order"
    case macFallback = "mac_fallback"
  }

  public init(
    profiles: [EvieModelProfile],
    preferenceOrder: [String],
    macFallback: MacFallback = .ask
  ) {
    self.profiles = profiles
    self.preferenceOrder = preferenceOrder
    self.macFallback = macFallback
  }

  public func profile(id: String) -> EvieModelProfile? {
    profiles.first { $0.id == id }
  }

  /// The first profile in the preference order, or the first profile at all
  /// when the order names none. A validated set always has one.
  public var preferredProfile: EvieModelProfile {
    preferenceOrder.lazy.compactMap(profile(id:)).first ?? profiles[0]
  }

  public mutating func updateProfile(
    id: String,
    _ edit: (inout EvieModelProfile) -> Void
  ) throws {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
      throw ValidationError.unknownProfile(id)
    }
    edit(&profiles[index])
  }

  public func validate() throws {
    guard !profiles.isEmpty else {
      throw ValidationError.noProfiles
    }
    var seen = Set<String>()
    for profile in profiles {
      guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError.emptyProfileID
      }
      guard seen.insert(profile.id).inserted else {
        throw ValidationError.duplicateProfileID(profile.id)
      }
      do {
        try profile.configuration.validate()
      } catch let reason as EvieConfiguration.ValidationError {
        throw ValidationError.invalidProfile(id: profile.id, reason: reason)
      }
      if case .localOnDemand(let runtime) = profile.runtime {
        guard runtime.executable.hasPrefix("/"),
          (1...65_535).contains(runtime.port),
          runtime.maxKVSize > 0
        else {
          throw ValidationError.invalidLocalRuntime(id: profile.id)
        }
      }
    }
    if let unknown = preferenceOrder.first(where: { !seen.contains($0) }) {
      throw ValidationError.unknownProfileInOrder(unknown)
    }
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case noProfiles
    case emptyProfileID
    case duplicateProfileID(String)
    case unknownProfile(String)
    case unknownProfileInOrder(String)
    case invalidProfile(id: String, reason: EvieConfiguration.ValidationError)
    case invalidLocalRuntime(id: String)
  }
}

extension EvieModelProfileSet.ValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noProfiles:
      "The configuration must list at least one model profile."
    case .emptyProfileID:
      "Every model profile needs an id."
    case .duplicateProfileID(let id):
      "The model profile id \(id) appears more than once."
    case .unknownProfile(let id):
      "There is no model profile with the id \(id)."
    case .unknownProfileInOrder(let id):
      "The preference order names \(id), which is not a profile."
    case .invalidProfile(let id, let reason):
      "Model profile \(id): \(reason.localizedDescription)"
    case .invalidLocalRuntime(let id):
      "Model profile \(id) needs an absolute executable path, a valid port and a positive KV cache size."
    }
  }
}

// MARK: - Built-in profiles

extension EvieModelProfileSet {
  /// What Evie uses with no file, and whenever the file cannot be used.
  ///
  /// The PC first: it holds qwen-daily resident with vision and tools. The Mac
  /// second, as the brain that wakes when the PC is out — and only after asking.
  public static let builtIn = EvieModelProfileSet(
    profiles: [.builtInPC, .builtInMac],
    preferenceOrder: [EvieModelProfile.pcProfileID, EvieModelProfile.macProfileID],
    macFallback: .ask
  )
}

extension EvieModelProfile {
  static let pcGatewayHost = "ai-node-3090.tail6146ef.ts.net"

  /// The owner's RTX 3090 gateway. Server figures are the gateway's own
  /// `GET /v1/models` metadata for qwen-daily, read 2026-10-16:
  /// `contextWindow` 200704, `maxTokens` 32768, vision and tools true. The client
  /// cap of 135168 is the PC stack's own client figure, chosen because an
  /// uncached 150K prefill measured 250 s; the output cap of 16384 is what a
  /// maximum-reasoning turn needs (`ReasoningLevel.thinkingOutputCap`), and
  /// ordinary turns ask for far less through `TurnOptions`.
  static let builtInPC = EvieModelProfile(
    id: pcProfileID,
    displayName: "PC RTX 3090",
    endpoint: URL(string: "https://\(pcGatewayHost)/v1")!,
    model: "qwen-daily",
    contextTokens: 135_168,
    serverContextTokens: 200_704,
    maxCompletionTokens: 16_384,
    capabilities: Capabilities(vision: true, tools: true),
    thinkingStyle: .templateKwargs,
    defaultReasoning: .off,
    credential: CredentialReference(
      service: "com.matheusbgodoi.evie.model",
      account: pcProfileID,
      boundHost: pcGatewayHost
    ),
    runtime: .remoteGateway,
    location: .yourPC,
    family: .qwen,
    // Unverified for qwen-daily; the grounding probe in S5 settles it.
    coordinateConvention: .normalized1000
  )

  /// LensVLM on this Mac, started on demand by `EvieLocalBrainLauncher`. Port
  /// 38480 had no listener on 2026-10-16. Its 262144-token nominal context is
  /// capped at 32768 on both sides for memory. It looks but is offered no
  /// tools: measured 2026-10-16, its tool calls come back as malformed XML in
  /// the content. `.topLevel` sends `enable_thinking` on every request. It
  /// sees: under `mlx_vlm.server` 0.7.8 it described a synthetic test image
  /// exactly (shapes, colours and the text "ZEBRA 4817"), and a 32×32 red
  /// square came back "vermelho".
  static let builtInMac = EvieModelProfile(
    id: macProfileID,
    displayName: "Mac local",
    endpoint: URL(string: "http://127.0.0.1:38480/v1")!,
    model: "mlx-community/LensVLM-9B-OptiQ-4bit",
    contextTokens: 32_768,
    serverContextTokens: 262_144,
    maxCompletionTokens: 2_048,
    capabilities: Capabilities(vision: true, tools: false),
    thinkingStyle: .topLevel,
    defaultReasoning: .off,
    credential: nil,
    runtime: .localOnDemand(
      LocalRuntime(
        launcher: .mlxVLM,
        executable: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".local/bin/mlx_vlm.server", isDirectory: false)
          .path,
        port: 38_480,
        maxKVSize: 32_768
      )
    ),
    location: .thisMac,
    family: .qwen,
    // Never used: act mode needs tools, which this profile does not have.
    coordinateConvention: .normalized1000
  )
}

// MARK: - Coding

// Keys are named by hand: `convertToSnakeCase` and `convertFromSnakeCase` are not
// inverses around an acronym (`maxKVSize` would come back as `maxKvSize`), the
// same trap `EviePreferencesStore` documents.

extension EvieModelProfile {
  private enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case endpoint
    case model
    case contextTokens = "context_tokens"
    case serverContextTokens = "server_context_tokens"
    case maxCompletionTokens = "max_completion_tokens"
    case capabilities
    case thinkingStyle = "thinking_style"
    case defaultReasoning = "default_reasoning"
    case credential
    case runtime
    case location
    case family
    case coordinateConvention = "coordinate_convention"
    case temperature
    case topP = "top_p"
    case stopSequences = "stop_sequences"
    case requestTimeout = "request_timeout_seconds"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      displayName: try container.decode(String.self, forKey: .displayName),
      endpoint: try container.decode(URL.self, forKey: .endpoint),
      model: try container.decode(String.self, forKey: .model),
      contextTokens: try container.decode(Int.self, forKey: .contextTokens),
      serverContextTokens: try container.decodeIfPresent(Int.self, forKey: .serverContextTokens),
      maxCompletionTokens: try container.decode(Int.self, forKey: .maxCompletionTokens),
      capabilities: try container.decode(Capabilities.self, forKey: .capabilities),
      thinkingStyle: try container.decode(ThinkingParameterStyle.self, forKey: .thinkingStyle),
      defaultReasoning: try container.decode(ReasoningLevel.self, forKey: .defaultReasoning),
      credential: try container.decodeIfPresent(CredentialDocument.self, forKey: .credential)?
        .reference,
      runtime: try container.decode(Runtime.self, forKey: .runtime),
      location: try container.decode(ModelLocation.self, forKey: .location),
      family: try container.decode(ModelFamily.self, forKey: .family),
      coordinateConvention: try container.decode(
        CoordinateConvention.self,
        forKey: .coordinateConvention
      ),
      temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
      topP: try container.decodeIfPresent(Double.self, forKey: .topP),
      stopSequences: try container.decode([String].self, forKey: .stopSequences),
      requestTimeout: try container.decode(TimeInterval.self, forKey: .requestTimeout)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(model, forKey: .model)
    try container.encode(contextTokens, forKey: .contextTokens)
    try container.encodeIfPresent(serverContextTokens, forKey: .serverContextTokens)
    try container.encode(maxCompletionTokens, forKey: .maxCompletionTokens)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encode(thinkingStyle, forKey: .thinkingStyle)
    try container.encode(defaultReasoning, forKey: .defaultReasoning)
    try container.encodeIfPresent(credential.map(CredentialDocument.init), forKey: .credential)
    try container.encode(runtime, forKey: .runtime)
    try container.encode(location, forKey: .location)
    try container.encode(family, forKey: .family)
    try container.encode(coordinateConvention, forKey: .coordinateConvention)
    try container.encodeIfPresent(temperature, forKey: .temperature)
    try container.encodeIfPresent(topP, forKey: .topP)
    try container.encode(stopSequences, forKey: .stopSequences)
    try container.encode(requestTimeout, forKey: .requestTimeout)
  }
}

/// `CredentialReference` as the file spells it. The reference's own coding keeps
/// its Swift names (`boundHost`), which other code and tests rely on; the file
/// uses snake_case like every other key in it.
private struct CredentialDocument: Codable {
  let service: String
  let account: String
  let boundHost: String

  enum CodingKeys: String, CodingKey {
    case service
    case account
    case boundHost = "bound_host"
  }

  init(_ reference: CredentialReference) {
    service = reference.service
    account = reference.account
    boundHost = reference.boundHost
  }

  var reference: CredentialReference {
    CredentialReference(service: service, account: account, boundHost: boundHost)
  }
}

extension EvieModelProfile.Runtime: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case launcher
    case executable
    case port
    case maxKVSize = "max_kv_size"
  }

  private enum Kind: String, Codable {
    case remoteGateway
    case localOnDemand
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .remoteGateway:
      self = .remoteGateway
    case .localOnDemand:
      self = .localOnDemand(
        LocalRuntime(
          launcher: try container.decode(LocalRuntime.Launcher.self, forKey: .launcher),
          executable: try container.decode(String.self, forKey: .executable),
          port: try container.decode(Int.self, forKey: .port),
          maxKVSize: try container.decode(Int.self, forKey: .maxKVSize)
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .remoteGateway:
      try container.encode(Kind.remoteGateway, forKey: .kind)
    case .localOnDemand(let runtime):
      try container.encode(Kind.localOnDemand, forKey: .kind)
      try container.encode(runtime.launcher, forKey: .launcher)
      try container.encode(runtime.executable, forKey: .executable)
      try container.encode(runtime.port, forKey: .port)
      try container.encode(runtime.maxKVSize, forKey: .maxKVSize)
    }
  }
}
