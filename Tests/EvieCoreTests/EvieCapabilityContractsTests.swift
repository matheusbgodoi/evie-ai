import Foundation
import Testing

@testable import EvieCore

@Suite("Evie capability contracts")
struct EvieCapabilityContractsTests {
  @Test("proposal carries complete immutable binding metadata")
  func proposalMetadata() throws {
    let fixture = try Fixture()

    #expect(fixture.proposal.requestID == fixture.requestID)
    #expect(fixture.proposal.planID == fixture.planID)
    #expect(fixture.proposal.capability == fixture.capability)
    #expect(fixture.proposal.target == fixture.target)
    #expect(fixture.proposal.materialArguments == fixture.arguments)
    #expect(fixture.proposal.revision == fixture.revision)
    #expect(fixture.proposal.createdAt == fixture.createdAt)
    #expect(fixture.proposal.expiresAt == fixture.expiresAt)
    #expect(fixture.proposal.provenance == fixture.provenance)
  }

  @Test("model and tool JSON cannot decode commit authority")
  func serializedInputCannotSupplyAuthority() throws {
    let fixture = try Fixture()
    let encoded = try JSONEncoder().encode(fixture.proposal)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["authority"] = ["token": Fixture.privateSentinel]
    let attemptedForgery = try JSONSerialization.data(withJSONObject: object)

    do {
      _ = try JSONDecoder().decode(CapabilityProposal.self, from: attemptedForgery)
      Issue.record("Expected serialized authority to be rejected")
    } catch {
      #expect(!error.localizedDescription.contains(Fixture.privateSentinel))
      #expect(!String(describing: error).contains(Fixture.privateSentinel))
    }

    let authorityType: Any.Type = CapabilityCommitAuthority.self
    let commitType: Any.Type = CapabilityCommit.self
    #expect((authorityType as? any Decodable.Type) == nil)
    #expect((commitType as? any Decodable.Type) == nil)
  }

  @Test("expired proposals and revision mismatches fail closed")
  func expiryAndRevisionValidation() throws {
    let fixture = try Fixture()

    #expect(throws: CapabilityContractError.proposalExpired) {
      try CapabilityCommitAuthorityFactory.authorize(
        proposal: fixture.proposal,
        approvedRevision: fixture.revision,
        approval: .explicitUser,
        at: fixture.expiresAt
      )
    }

    #expect(throws: CapabilityContractError.revisionMismatch) {
      try CapabilityCommitAuthorityFactory.authorize(
        proposal: fixture.proposal,
        approvedRevision: CapabilityRevision("changed-before-approval"),
        approval: .explicitUser,
        at: fixture.activeDate
      )
    }

    let commit = try fixture.authorizedCommit()
    #expect(throws: CapabilityContractError.revisionMismatch) {
      try CapabilityCommitAuthorityFactory.validate(
        commit,
        against: fixture.proposal,
        currentRevision: CapabilityRevision("changed-before-commit"),
        at: fixture.activeDate
      )
    }
  }

  @Test("read, proposal, and commit remain nominally separate")
  func nominalSeparation() throws {
    let fixture = try Fixture()
    let read = try CapabilityReadRequest(
      requestID: fixture.requestID,
      capability: CapabilityDescriptor(
        identifier: "filesystem.read",
        operation: .read
      ),
      target: fixture.target,
      materialArguments: fixture.arguments,
      provenance: fixture.provenance
    )

    #expect(((read as Any) as? CapabilityProposal) == nil)
    #expect(((read as Any) as? CapabilityCommit) == nil)
    #expect(((fixture.proposal as Any) as? CapabilityCommit) == nil)

    #expect(throws: CapabilityContractError.invalidReadCapability) {
      try CapabilityReadRequest(
        capability: fixture.capability,
        target: fixture.target,
        provenance: fixture.provenance
      )
    }
    #expect(throws: CapabilityContractError.invalidProposalCapability) {
      try CapabilityProposal(
        requestID: fixture.requestID,
        capability: read.capability,
        target: fixture.target,
        revision: fixture.revision,
        createdAt: fixture.createdAt,
        expiresAt: fixture.expiresAt,
        provenance: fixture.provenance
      )
    }
  }

  @Test("delete is destructive and always needs explicit approval")
  func deletePolicy() throws {
    let fixture = try Fixture()

    #expect(fixture.capability.effect == .destructive)
    #expect(fixture.capability.approvalRequirement == .always)
    #expect(fixture.capability.alwaysRequiresApproval)
    #expect(throws: CapabilityContractError.approvalRequired) {
      try CapabilityCommitAuthorityFactory.authorize(
        proposal: fixture.proposal,
        approvedRevision: fixture.revision,
        approval: .documentedPolicy,
        at: fixture.activeDate
      )
    }

    _ = try fixture.authorizedCommit()
  }

  @Test("descriptions and validation errors redact private material")
  func descriptionsAndErrorsAreRedacted() throws {
    let fixture = try Fixture()
    let commit = try fixture.authorizedCommit()
    let sensitiveValues: [Any] = [
      fixture.arguments,
      fixture.target.canonicalIdentity,
      fixture.target,
      fixture.provenance,
      fixture.revision,
      fixture.proposal,
      commit.authority,
      commit,
    ]

    for value in sensitiveValues {
      #expect(!String(describing: value).contains(Fixture.privateSentinel))
      #expect(!String(reflecting: value).contains(Fixture.privateSentinel))
    }
    #expect(!fixture.arguments.redacted().values.contains(Fixture.privateSentinel))

    let changedTarget = CapabilityTarget(
      displayName: Fixture.privateSentinel,
      canonicalIdentity: CapabilityCanonicalTargetIdentity(
        namespace: "fixture",
        identifier: "different-\(Fixture.privateSentinel)",
        metadata: fixture.arguments
      )
    )
    let changedProposal = try CapabilityProposal(
      requestID: fixture.requestID,
      planID: fixture.planID,
      capability: fixture.capability,
      target: changedTarget,
      materialArguments: fixture.arguments,
      revision: fixture.revision,
      createdAt: fixture.createdAt,
      expiresAt: fixture.expiresAt,
      provenance: fixture.provenance
    )

    do {
      try CapabilityCommitAuthorityFactory.validate(
        commit,
        against: changedProposal,
        currentRevision: fixture.revision,
        at: fixture.activeDate
      )
      Issue.record("Expected authority mismatch")
    } catch {
      #expect(error as? CapabilityContractError == .authorityMismatch)
      #expect(!error.localizedDescription.contains(Fixture.privateSentinel))
      #expect(!String(describing: error).contains(Fixture.privateSentinel))
      #expect(!String(reflecting: error).contains(Fixture.privateSentinel))
    }
  }

  @Test("rejects oversized, over-nested, non-finite, and long-lived contracts")
  func boundedTransportMetadata() throws {
    let fixture = try Fixture()
    let oversized = CapabilityMaterialArguments([
      "payload": .string(
        String(
          repeating: "x",
          count: CapabilityContractLimits.maximumArgumentStringBytes + 1
        )
      )
    ])

    #expect(throws: CapabilityContractError.contractLimitsExceeded) {
      try CapabilityProposal(
        requestID: fixture.requestID,
        capability: fixture.capability,
        target: fixture.target,
        materialArguments: oversized,
        revision: fixture.revision,
        createdAt: fixture.createdAt,
        expiresAt: fixture.expiresAt,
        provenance: fixture.provenance
      )
    }

    var nested: CapabilityArgumentValue = .string("leaf")
    for _ in 0...CapabilityContractLimits.maximumArgumentDepth {
      nested = .array([nested])
    }
    #expect(throws: CapabilityContractError.contractLimitsExceeded) {
      try CapabilityReadRequest(
        capability: CapabilityDescriptor(identifier: "filesystem.read", operation: .read),
        target: fixture.target,
        materialArguments: CapabilityMaterialArguments(["nested": nested]),
        provenance: fixture.provenance
      )
    }

    #expect(throws: CapabilityContractError.contractLimitsExceeded) {
      try CapabilityProposal(
        requestID: fixture.requestID,
        capability: fixture.capability,
        target: fixture.target,
        materialArguments: CapabilityMaterialArguments(["score": .number(.infinity)]),
        revision: fixture.revision,
        createdAt: fixture.createdAt,
        expiresAt: fixture.expiresAt,
        provenance: fixture.provenance
      )
    }

    #expect(throws: CapabilityContractError.contractLimitsExceeded) {
      try CapabilityProposal(
        requestID: fixture.requestID,
        capability: fixture.capability,
        target: fixture.target,
        revision: fixture.revision,
        createdAt: fixture.createdAt,
        expiresAt: fixture.createdAt.addingTimeInterval(
          CapabilityContractLimits.maximumProposalLifetime + 1
        ),
        provenance: fixture.provenance
      )
    }
  }

  @Test("serialized material arguments are validated while decoding")
  func decodedArgumentsAreBounded() throws {
    let oversized = CapabilityMaterialArguments([
      "payload": .string(
        String(
          repeating: Fixture.privateSentinel,
          count: CapabilityContractLimits.maximumArgumentStringBytes
        )
      )
    ])
    let encoded = try JSONEncoder().encode(oversized)

    do {
      _ = try JSONDecoder().decode(CapabilityMaterialArguments.self, from: encoded)
      Issue.record("Expected decoded arguments to be bounded.")
    } catch {
      #expect(!error.localizedDescription.contains(Fixture.privateSentinel))
      #expect(!String(describing: error).contains(Fixture.privateSentinel))
    }
  }
}

extension EvieCapabilityContractsTests {
  fileprivate struct Fixture {
    static let privateSentinel = "PRIVATE-CAPABILITY-ARGUMENT-MUST-NOT-LEAK"

    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let capability = CapabilityDescriptor(
      identifier: "filesystem.delete",
      operation: .delete
    )
    let arguments = CapabilityMaterialArguments([
      "path": .string(privateSentinel),
      "options": .object(["reason": .string(privateSentinel)]),
    ])
    let target: CapabilityTarget
    let revision = CapabilityRevision("revision-\(privateSentinel)")
    let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let activeDate = Date(timeIntervalSinceReferenceDate: 10_030)
    let expiresAt = Date(timeIntervalSinceReferenceDate: 10_060)
    let provenance = CapabilityProvenance(
      origin: .localDocument,
      trust: .untrustedContent,
      sourceReference: privateSentinel
    )
    let proposal: CapabilityProposal

    init() throws {
      target = CapabilityTarget(
        displayName: Self.privateSentinel,
        canonicalIdentity: CapabilityCanonicalTargetIdentity(
          namespace: "fixture",
          identifier: "target-\(Self.privateSentinel)",
          metadata: arguments
        )
      )
      proposal = try CapabilityProposal(
        requestID: requestID,
        planID: planID,
        capability: capability,
        target: target,
        materialArguments: arguments,
        revision: revision,
        createdAt: createdAt,
        expiresAt: expiresAt,
        provenance: provenance
      )
    }

    func authorizedCommit() throws -> CapabilityCommit {
      try CapabilityCommitAuthorityFactory.authorize(
        proposal: proposal,
        approvedRevision: revision,
        approval: .explicitUser,
        at: activeDate,
        nonce: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
      )
    }
  }
}
