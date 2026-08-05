import Foundation

/// The semantic operation represented by a capability.
///
/// The operation is policy metadata, not authorization. A future broker must
/// resolve the capability identifier against its own trusted registry before it
/// issues commit authority.
public enum CapabilityOperation: String, Codable, CaseIterable, Hashable, Sendable {
  case read
  case create
  case update
  case move
  case copy
  case send
  case execute
  case delete
  case custom
}

/// The externally observable effect class of a capability.
public enum CapabilityEffect: String, Codable, CaseIterable, Hashable, Sendable {
  case readOnly
  case stateChanging
  case externalEffect
  case destructive
}

/// The minimum approval policy carried by a capability contract.
public enum CapabilityApprovalRequirement: String, Codable, CaseIterable, Hashable, Sendable {
  case none
  case policy
  case always
}

/// Hard transport limits shared by capability producers and the future broker.
///
/// These limits keep model/tool JSON from turning a proposal into an unbounded
/// memory, decoding, or approval-surface payload. They are protocol ceilings,
/// not authorization policy.
public enum CapabilityContractLimits {
  public static let maximumCapabilityIdentifierBytes = 256
  public static let maximumTargetNamespaceBytes = 128
  public static let maximumTargetIdentifierBytes = 8 * 1_024
  public static let maximumDisplayNameBytes = 1_024
  public static let maximumRevisionBytes = 2 * 1_024
  public static let maximumSourceReferenceBytes = 4 * 1_024
  public static let maximumTopLevelArguments = 64
  public static let maximumCollectionEntries = 128
  public static let maximumArgumentDepth = 8
  public static let maximumArgumentNodes = 1_024
  public static let maximumArgumentStringBytes = 64 * 1_024
  public static let maximumArgumentPayloadBytes = 512 * 1_024
  public static let maximumArgumentKeyBytes = 128
  public static let maximumProposalLifetime: TimeInterval = 15 * 60

  fileprivate static let maximumDecoderCodingPathDepth = 32
}

/// A backend-neutral capability name plus its policy-relevant operation.
public struct CapabilityDescriptor: Codable, Hashable, Sendable {
  public let identifier: String
  public let operation: CapabilityOperation

  public init(identifier: String, operation: CapabilityOperation) {
    self.identifier = identifier
    self.operation = operation
  }

  public var effect: CapabilityEffect {
    switch operation {
    case .read:
      .readOnly
    case .create, .update, .move, .copy:
      .stateChanging
    case .send, .execute, .custom:
      .externalEffect
    case .delete:
      .destructive
    }
  }

  public var approvalRequirement: CapabilityApprovalRequirement {
    switch operation {
    case .read:
      .none
    case .delete:
      .always
    default:
      .policy
    }
  }

  /// Destructive deletion can never be authorized by a standing policy.
  public var alwaysRequiresApproval: Bool {
    approvalRequirement == .always
  }
}

/// A recursive, backend-neutral value used for material tool arguments.
///
/// Its textual representations are deliberately redacted. Trusted broker code
/// can inspect values through pattern matching after it has accepted the
/// surrounding request; logs and errors should use the redacted wrappers instead.
public indirect enum CapabilityArgumentValue: Codable, Hashable, Sendable {
  case string(String)
  case integer(Int64)
  case number(Double)
  case boolean(Bool)
  case array([CapabilityArgumentValue])
  case object([String: CapabilityArgumentValue])
  case null
}

extension CapabilityArgumentValue {
  private enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  private enum Kind: String, Codable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
    case null
  }

  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      return nil
    }
  }

  public init(from decoder: any Decoder) throws {
    guard decoder.codingPath.count <= CapabilityContractLimits.maximumDecoderCodingPathDepth else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Capability argument nesting exceeds its limit."
        )
      )
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .string:
      self = .string(try container.decode(String.self, forKey: .value))
    case .integer:
      self = .integer(try container.decode(Int64.self, forKey: .value))
    case .number:
      self = .number(try container.decode(Double.self, forKey: .value))
    case .boolean:
      self = .boolean(try container.decode(Bool.self, forKey: .value))
    case .array:
      var nested = try container.nestedUnkeyedContainer(forKey: .value)
      if let count = nested.count,
        count > CapabilityContractLimits.maximumCollectionEntries
      {
        throw DecodingError.dataCorruptedError(
          forKey: .value,
          in: container,
          debugDescription: "Capability argument collection exceeds its limit."
        )
      }
      var values: [CapabilityArgumentValue] = []
      while !nested.isAtEnd {
        guard values.count < CapabilityContractLimits.maximumCollectionEntries else {
          throw DecodingError.dataCorruptedError(
            forKey: .value,
            in: container,
            debugDescription: "Capability argument collection exceeds its limit."
          )
        }
        values.append(try nested.decode(CapabilityArgumentValue.self))
      }
      self = .array(values)
    case .object:
      let nested = try container.nestedContainer(
        keyedBy: DynamicCodingKey.self,
        forKey: .value
      )
      guard nested.allKeys.count <= CapabilityContractLimits.maximumCollectionEntries else {
        throw DecodingError.dataCorruptedError(
          forKey: .value,
          in: container,
          debugDescription: "Capability argument collection exceeds its limit."
        )
      }
      var values: [String: CapabilityArgumentValue] = [:]
      values.reserveCapacity(nested.allKeys.count)
      for key in nested.allKeys {
        values[key.stringValue] = try nested.decode(
          CapabilityArgumentValue.self,
          forKey: key
        )
      }
      self = .object(values)
    case .null:
      self = .null
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .string(let value):
      try container.encode(Kind.string, forKey: .type)
      try container.encode(value, forKey: .value)
    case .integer(let value):
      try container.encode(Kind.integer, forKey: .type)
      try container.encode(value, forKey: .value)
    case .number(let value):
      try container.encode(Kind.number, forKey: .type)
      try container.encode(value, forKey: .value)
    case .boolean(let value):
      try container.encode(Kind.boolean, forKey: .type)
      try container.encode(value, forKey: .value)
    case .array(let values):
      try container.encode(Kind.array, forKey: .type)
      try container.encode(values, forKey: .value)
    case .object(let values):
      try container.encode(Kind.object, forKey: .type)
      try container.encode(values, forKey: .value)
    case .null:
      try container.encode(Kind.null, forKey: .type)
    }
  }
}

extension CapabilityArgumentValue: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "<redacted capability argument>"
  }

  public var debugDescription: String {
    description
  }
}

/// Material arguments whose values are excluded from default descriptions.
public struct CapabilityMaterialArguments: Codable, Hashable, Sendable {
  private let storage: [String: CapabilityArgumentValue]

  public init(_ values: [String: CapabilityArgumentValue] = [:]) {
    storage = values
  }

  public var count: Int {
    storage.count
  }

  public var keys: [String] {
    storage.keys.sorted()
  }

  public subscript(key: String) -> CapabilityArgumentValue? {
    storage[key]
  }

  /// Returns a presentation-safe copy that preserves field names but no values.
  public func redacted() -> [String: String] {
    Dictionary(uniqueKeysWithValues: storage.keys.map { ($0, "<redacted>") })
  }
}

extension CapabilityMaterialArguments {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let values = try container.decode([String: CapabilityArgumentValue].self)
    self.init(values)
    try CapabilityContractValidator.validate(arguments: self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storage)
  }
}

extension CapabilityMaterialArguments: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityMaterialArguments(count: \(count), values: <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// Stable identity for a target, independent of its user-facing label.
public struct CapabilityCanonicalTargetIdentity: Codable, Hashable, Sendable {
  public let namespace: String
  public let identifier: String
  public let metadata: CapabilityMaterialArguments

  public init(
    namespace: String,
    identifier: String,
    metadata: CapabilityMaterialArguments = CapabilityMaterialArguments()
  ) {
    self.namespace = namespace
    self.identifier = identifier
    self.metadata = metadata
  }
}

extension CapabilityCanonicalTargetIdentity:
  CustomStringConvertible, CustomDebugStringConvertible
{
  public var description: String {
    "CapabilityCanonicalTargetIdentity(<redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// User-facing and canonical identity metadata for an operation target.
public struct CapabilityTarget: Codable, Hashable, Sendable {
  public let displayName: String
  public let canonicalIdentity: CapabilityCanonicalTargetIdentity

  public init(
    displayName: String,
    canonicalIdentity: CapabilityCanonicalTargetIdentity
  ) {
    self.displayName = displayName
    self.canonicalIdentity = canonicalIdentity
  }
}

extension CapabilityTarget: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityTarget(<redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// The kind of source that contributed data to a capability request or plan.
public enum CapabilityProvenanceOrigin: String, Codable, CaseIterable, Hashable, Sendable {
  case user
  case deterministicRule
  case model
  case tool
  case localDocument
  case web
  case email
  case calendar
  case message
  case unknown
}

/// The trust classification asserted for content from a provenance source.
///
/// This serialized value is context, not authority. A trusted broker must derive
/// or verify it from the actual channel and must not accept a model-authored trust
/// promotion.
public enum CapabilityTrust: String, Codable, CaseIterable, Hashable, Sendable {
  case trustedUser
  case trustedLocalPolicy
  case untrustedContent
  case mixed
}

/// Provenance and trust carried with every capability request or proposal.
public struct CapabilityProvenance: Codable, Hashable, Sendable {
  public let origin: CapabilityProvenanceOrigin
  public let trust: CapabilityTrust
  public let sourceReference: String?

  public init(
    origin: CapabilityProvenanceOrigin,
    trust: CapabilityTrust,
    sourceReference: String? = nil
  ) {
    self.origin = origin
    self.trust = trust
    self.sourceReference = sourceReference
  }
}

extension CapabilityProvenance: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityProvenance(origin: \(origin.rawValue), trust: \(trust.rawValue), source: <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// An opaque source revision or ETag used for optimistic commit validation.
public struct CapabilityRevision: Codable, Hashable, Sendable {
  public let value: String

  public init(_ value: String) {
    self.value = value
  }
}

extension CapabilityRevision: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityRevision(<redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// A read-only request. It cannot be converted into a proposal or commit.
public struct CapabilityReadRequest: Codable, Hashable, Sendable {
  public let requestID: UUID
  public let capability: CapabilityDescriptor
  public let target: CapabilityTarget
  public let materialArguments: CapabilityMaterialArguments
  public let provenance: CapabilityProvenance

  public init(
    requestID: UUID = UUID(),
    capability: CapabilityDescriptor,
    target: CapabilityTarget,
    materialArguments: CapabilityMaterialArguments = CapabilityMaterialArguments(),
    provenance: CapabilityProvenance
  ) throws {
    guard capability.operation == .read else {
      throw CapabilityContractError.invalidReadCapability
    }
    try CapabilityContractValidator.validate(
      capability: capability,
      target: target,
      materialArguments: materialArguments,
      revision: nil,
      provenance: provenance
    )

    self.requestID = requestID
    self.capability = capability
    self.target = target
    self.materialArguments = materialArguments
    self.provenance = provenance
  }

  private enum CodingKeys: String, CodingKey {
    case requestID
    case capability
    case target
    case materialArguments
    case provenance
    case authority
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard !container.contains(.authority) else {
      throw DecodingError.dataCorruptedError(
        forKey: .authority,
        in: container,
        debugDescription: "Serialized requests cannot supply commit authority."
      )
    }

    try self.init(
      requestID: container.decode(UUID.self, forKey: .requestID),
      capability: container.decode(CapabilityDescriptor.self, forKey: .capability),
      target: container.decode(CapabilityTarget.self, forKey: .target),
      materialArguments: container.decode(
        CapabilityMaterialArguments.self,
        forKey: .materialArguments
      ),
      provenance: container.decode(CapabilityProvenance.self, forKey: .provenance)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(capability, forKey: .capability)
    try container.encode(target, forKey: .target)
    try container.encode(materialArguments, forKey: .materialArguments)
    try container.encode(provenance, forKey: .provenance)
  }
}

extension CapabilityReadRequest: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityReadRequest(requestID: \(requestID), capability: \(capability.identifier), target: <redacted>, arguments: <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// A proposed state change with no authority to execute it.
///
/// Proposals are serializable so they can cross backend and process boundaries.
/// A serialized proposal can never contain or recreate commit authority.
public struct CapabilityProposal: Codable, Hashable, Sendable {
  public let requestID: UUID
  public let planID: UUID
  public let capability: CapabilityDescriptor
  public let target: CapabilityTarget
  public let materialArguments: CapabilityMaterialArguments
  public let revision: CapabilityRevision
  public let createdAt: Date
  public let expiresAt: Date
  public let provenance: CapabilityProvenance

  public init(
    requestID: UUID,
    planID: UUID = UUID(),
    capability: CapabilityDescriptor,
    target: CapabilityTarget,
    materialArguments: CapabilityMaterialArguments = CapabilityMaterialArguments(),
    revision: CapabilityRevision,
    createdAt: Date,
    expiresAt: Date,
    provenance: CapabilityProvenance
  ) throws {
    guard capability.operation != .read else {
      throw CapabilityContractError.invalidProposalCapability
    }
    guard createdAt < expiresAt else {
      throw CapabilityContractError.invalidProposalLifetime
    }
    try CapabilityContractValidator.validate(
      capability: capability,
      target: target,
      materialArguments: materialArguments,
      revision: revision,
      provenance: provenance
    )
    guard
      createdAt.timeIntervalSinceReferenceDate.isFinite,
      expiresAt.timeIntervalSinceReferenceDate.isFinite,
      expiresAt.timeIntervalSince(createdAt) <= CapabilityContractLimits.maximumProposalLifetime
    else {
      throw CapabilityContractError.contractLimitsExceeded
    }

    self.requestID = requestID
    self.planID = planID
    self.capability = capability
    self.target = target
    self.materialArguments = materialArguments
    self.revision = revision
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.provenance = provenance
  }

  private enum CodingKeys: String, CodingKey {
    case requestID
    case planID
    case capability
    case target
    case materialArguments
    case revision
    case createdAt
    case expiresAt
    case provenance
    case authority
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard !container.contains(.authority) else {
      throw DecodingError.dataCorruptedError(
        forKey: .authority,
        in: container,
        debugDescription: "Serialized proposals cannot supply commit authority."
      )
    }

    try self.init(
      requestID: container.decode(UUID.self, forKey: .requestID),
      planID: container.decode(UUID.self, forKey: .planID),
      capability: container.decode(CapabilityDescriptor.self, forKey: .capability),
      target: container.decode(CapabilityTarget.self, forKey: .target),
      materialArguments: container.decode(
        CapabilityMaterialArguments.self,
        forKey: .materialArguments
      ),
      revision: container.decode(CapabilityRevision.self, forKey: .revision),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      expiresAt: container.decode(Date.self, forKey: .expiresAt),
      provenance: container.decode(CapabilityProvenance.self, forKey: .provenance)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(planID, forKey: .planID)
    try container.encode(capability, forKey: .capability)
    try container.encode(target, forKey: .target)
    try container.encode(materialArguments, forKey: .materialArguments)
    try container.encode(revision, forKey: .revision)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encode(provenance, forKey: .provenance)
  }
}

extension CapabilityProposal: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityProposal(requestID: \(requestID), planID: \(planID), capability: \(capability.identifier), target: <redacted>, arguments: <redacted>, revision: <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// An opaque, process-local proof that trusted broker code authorized a plan.
///
/// There is deliberately no public initializer and no `Codable` conformance.
/// Model output, tool JSON, IPC payloads, and persisted data cannot create one.
public struct CapabilityCommitAuthority: Hashable, Sendable {
  fileprivate struct Binding: Hashable, Sendable {
    let requestID: UUID
    let planID: UUID
    let capabilityIdentifier: String
    let revision: CapabilityRevision
  }

  fileprivate let nonce: UUID
  fileprivate let binding: Binding
}

extension CapabilityCommitAuthority: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityCommitAuthority(<opaque>)"
  }

  public var debugDescription: String {
    description
  }
}

/// A nominal commit value that can only be created by trusted in-module broker code.
///
/// It is intentionally not serializable. The proposal remains available for an
/// executor to revalidate, while the authority value is opaque to callers.
public struct CapabilityCommit: Hashable, Sendable {
  public let proposal: CapabilityProposal
  public let authority: CapabilityCommitAuthority

  fileprivate init(
    proposal: CapabilityProposal,
    authority: CapabilityCommitAuthority
  ) {
    self.proposal = proposal
    self.authority = authority
  }
}

extension CapabilityCommit: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "CapabilityCommit(planID: \(proposal.planID), authority: <opaque>, target: <redacted>, arguments: <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

/// Failures emitted by capability contract validation.
///
/// Cases intentionally carry no material argument, target, or revision values so
/// they are safe to present and log by default.
public enum CapabilityContractError: Error, Equatable, Sendable {
  case invalidReadCapability
  case invalidProposalCapability
  case invalidProposalLifetime
  case contractLimitsExceeded
  case proposalNotActive
  case proposalExpired
  case revisionMismatch
  case approvalRequired
  case authorityMismatch
}

extension CapabilityContractError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidReadCapability:
      "A read request requires a read-only capability."
    case .invalidProposalCapability:
      "A proposal requires a state-changing capability."
    case .invalidProposalLifetime:
      "The proposal validity interval is invalid."
    case .contractLimitsExceeded:
      "The capability request exceeds its safe transport limits."
    case .proposalNotActive:
      "The proposal is not active yet."
    case .proposalExpired:
      "The proposal has expired."
    case .revisionMismatch:
      "The target revision changed before commit."
    case .approvalRequired:
      "This operation requires explicit user approval."
    case .authorityMismatch:
      "Commit authority does not match the current proposal."
    }
  }
}

private enum CapabilityContractValidator {
  static func validate(
    capability: CapabilityDescriptor,
    target: CapabilityTarget,
    materialArguments: CapabilityMaterialArguments,
    revision: CapabilityRevision?,
    provenance: CapabilityProvenance
  ) throws {
    guard
      validIdentifier(
        capability.identifier,
        maximumBytes: CapabilityContractLimits.maximumCapabilityIdentifierBytes
      ),
      validIdentifier(
        target.canonicalIdentity.namespace,
        maximumBytes: CapabilityContractLimits.maximumTargetNamespaceBytes
      ),
      validIdentifier(
        target.canonicalIdentity.identifier,
        maximumBytes: CapabilityContractLimits.maximumTargetIdentifierBytes
      ),
      validDisplayName(target.displayName),
      validOptionalText(
        provenance.sourceReference,
        maximumBytes: CapabilityContractLimits.maximumSourceReferenceBytes
      ),
      revision.map({
        validIdentifier(
          $0.value,
          maximumBytes: CapabilityContractLimits.maximumRevisionBytes
        )
      }) ?? true
    else {
      throw CapabilityContractError.contractLimitsExceeded
    }

    try validate(arguments: target.canonicalIdentity.metadata)
    try validate(arguments: materialArguments)
  }

  static func validate(arguments: CapabilityMaterialArguments) throws {
    guard arguments.count <= CapabilityContractLimits.maximumTopLevelArguments else {
      throw CapabilityContractError.contractLimitsExceeded
    }

    var nodes = 0
    var bytes = 0
    for key in arguments.keys {
      try accumulateKey(key, bytes: &bytes)
      guard let value = arguments[key] else {
        throw CapabilityContractError.contractLimitsExceeded
      }
      try accumulate(value, depth: 1, nodes: &nodes, bytes: &bytes)
    }
  }

  private static func accumulate(
    _ value: CapabilityArgumentValue,
    depth: Int,
    nodes: inout Int,
    bytes: inout Int
  ) throws {
    nodes += 1
    guard
      depth <= CapabilityContractLimits.maximumArgumentDepth,
      nodes <= CapabilityContractLimits.maximumArgumentNodes
    else {
      throw CapabilityContractError.contractLimitsExceeded
    }

    switch value {
    case .string(let value):
      let count = value.lengthOfBytes(using: .utf8)
      guard
        count <= CapabilityContractLimits.maximumArgumentStringBytes,
        !value.contains("\0")
      else {
        throw CapabilityContractError.contractLimitsExceeded
      }
      bytes += count
    case .number(let value):
      guard value.isFinite else {
        throw CapabilityContractError.contractLimitsExceeded
      }
    case .array(let values):
      guard values.count <= CapabilityContractLimits.maximumCollectionEntries else {
        throw CapabilityContractError.contractLimitsExceeded
      }
      for nested in values {
        try accumulate(nested, depth: depth + 1, nodes: &nodes, bytes: &bytes)
      }
    case .object(let values):
      guard values.count <= CapabilityContractLimits.maximumCollectionEntries else {
        throw CapabilityContractError.contractLimitsExceeded
      }
      for key in values.keys.sorted() {
        try accumulateKey(key, bytes: &bytes)
        guard let nested = values[key] else {
          throw CapabilityContractError.contractLimitsExceeded
        }
        try accumulate(nested, depth: depth + 1, nodes: &nodes, bytes: &bytes)
      }
    case .integer, .boolean, .null:
      break
    }

    guard bytes <= CapabilityContractLimits.maximumArgumentPayloadBytes else {
      throw CapabilityContractError.contractLimitsExceeded
    }
  }

  private static func accumulateKey(_ key: String, bytes: inout Int) throws {
    guard validIdentifier(key, maximumBytes: CapabilityContractLimits.maximumArgumentKeyBytes)
    else {
      throw CapabilityContractError.contractLimitsExceeded
    }
    bytes += key.lengthOfBytes(using: .utf8)
    guard bytes <= CapabilityContractLimits.maximumArgumentPayloadBytes else {
      throw CapabilityContractError.contractLimitsExceeded
    }
  }

  private static func validDisplayName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && value.lengthOfBytes(using: .utf8) <= CapabilityContractLimits.maximumDisplayNameBytes
      && !containsForbiddenControl(value)
  }

  private static func validOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
    guard let value else { return true }
    return value.lengthOfBytes(using: .utf8) <= maximumBytes && !value.contains("\0")
  }

  private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed == value
      && value.lengthOfBytes(using: .utf8) <= maximumBytes
      && !containsForbiddenControl(value)
  }

  private static func containsForbiddenControl(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

/// Approval evidence accepted by the trusted in-module authority factory.
///
/// This type is internal and non-serializable so model/tool data cannot claim
/// that approval occurred. A future UI/policy broker supplies it after its own
/// independent checks.
enum CapabilityApprovalEvidence: Hashable, Sendable {
  case explicitUser
  case documentedPolicy
}

/// The only factory for `CapabilityCommitAuthority` and `CapabilityCommit`.
///
/// This is contract validation, not a tool executor. It performs no filesystem,
/// network, credential, or external-state operation.
enum CapabilityCommitAuthorityFactory {
  static func authorize(
    proposal: CapabilityProposal,
    approvedRevision: CapabilityRevision,
    approval: CapabilityApprovalEvidence,
    at now: Date,
    nonce: UUID = UUID()
  ) throws -> CapabilityCommit {
    try validateLifetime(of: proposal, at: now)

    guard approvedRevision == proposal.revision else {
      throw CapabilityContractError.revisionMismatch
    }
    if proposal.capability.alwaysRequiresApproval,
      approval != .explicitUser
    {
      throw CapabilityContractError.approvalRequired
    }

    let binding = CapabilityCommitAuthority.Binding(
      requestID: proposal.requestID,
      planID: proposal.planID,
      capabilityIdentifier: proposal.capability.identifier,
      revision: proposal.revision
    )
    let authority = CapabilityCommitAuthority(nonce: nonce, binding: binding)
    return CapabilityCommit(proposal: proposal, authority: authority)
  }

  /// Revalidates immutable plan identity, current revision, and expiry immediately
  /// before a future executor performs the state change.
  static func validate(
    _ commit: CapabilityCommit,
    against currentProposal: CapabilityProposal,
    currentRevision: CapabilityRevision,
    at now: Date
  ) throws {
    try validateLifetime(of: currentProposal, at: now)

    guard currentRevision == currentProposal.revision,
      currentRevision == commit.proposal.revision
    else {
      throw CapabilityContractError.revisionMismatch
    }

    let expectedBinding = CapabilityCommitAuthority.Binding(
      requestID: currentProposal.requestID,
      planID: currentProposal.planID,
      capabilityIdentifier: currentProposal.capability.identifier,
      revision: currentProposal.revision
    )
    guard commit.proposal == currentProposal,
      commit.authority.binding == expectedBinding
    else {
      throw CapabilityContractError.authorityMismatch
    }
  }

  private static func validateLifetime(
    of proposal: CapabilityProposal,
    at now: Date
  ) throws {
    guard now >= proposal.createdAt else {
      throw CapabilityContractError.proposalNotActive
    }
    guard now < proposal.expiresAt else {
      throw CapabilityContractError.proposalExpired
    }
  }
}
