import Foundation

/// Stable interaction phases understood by the UI regardless of the active
/// model, speech, retrieval, or agent backend.
public enum EvieInteractionPhase: String, Codable, CaseIterable, Hashable, Sendable {
  case sleeping
  case idle
  case listening
  case transcribing
  case thinking
  case usingTool
  case awaitingApproval
  case speaking
  case completed
  case cancelled
  case failed

  public var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .failed:
      true
    default:
      false
    }
  }
}

/// A serializable failure suitable for presentation and persistence.
public struct EvieFailure: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case invalidRequest
    case permissionDenied
    case timeout
    case backend
    case cancelled
    case unknown
  }

  public var kind: Kind
  public var message: String
  public var recoverySuggestion: String?

  public init(
    kind: Kind,
    message: String,
    recoverySuggestion: String? = nil
  ) {
    self.kind = kind
    self.message = message
    self.recoverySuggestion = recoverySuggestion
  }
}

/// Token accounting normalized across OpenAI-compatible agent backends.
public struct AgentUsage: Codable, Hashable, Sendable {
  public var promptTokens: Int
  public var completionTokens: Int
  public var totalTokens: Int
  public var cachedPromptTokens: Int?

  public init(
    promptTokens: Int,
    completionTokens: Int,
    totalTokens: Int,
    cachedPromptTokens: Int? = nil
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.cachedPromptTokens = cachedPromptTokens
  }
}

/// Events emitted by any Evie backend and consumed by the native shell.
public enum EvieInteractionEvent: Codable, Hashable, Sendable {
  case phaseChanged(EvieInteractionPhase)
  case transcriptUpdated(text: String, isFinal: Bool)
  case responseTextDelta(String)
  case status(message: String)
  case artifactCreated(EvieArtifact)
  case usage(AgentUsage)
  case completed(message: ChatMessage, finishReason: String?)
  case failed(EvieFailure)
}

/// A value-type projection of an interaction event stream.
///
/// Keeping the reducer in EvieCore lets SwiftUI, a future XPC process, and tests
/// agree on state transitions without importing a backend SDK.
public struct EvieInteractionState: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var phase: EvieInteractionPhase
  public var transcript: String
  public var responseText: String
  public var statusMessage: String?
  public var artifacts: [EvieArtifact]
  public var usage: AgentUsage?
  public var completedMessage: ChatMessage?
  public var failure: EvieFailure?

  public init(
    id: UUID = UUID(),
    phase: EvieInteractionPhase = .idle,
    transcript: String = "",
    responseText: String = "",
    statusMessage: String? = nil,
    artifacts: [EvieArtifact] = [],
    usage: AgentUsage? = nil,
    completedMessage: ChatMessage? = nil,
    failure: EvieFailure? = nil
  ) {
    self.id = id
    self.phase = phase
    self.transcript = transcript
    self.responseText = responseText
    self.statusMessage = statusMessage
    self.artifacts = artifacts
    self.usage = usage
    self.completedMessage = completedMessage
    self.failure = failure
  }

  public mutating func apply(_ event: EvieInteractionEvent) {
    switch event {
    case .phaseChanged(let phase):
      self.phase = phase

    case .transcriptUpdated(let text, _):
      transcript = text

    case .responseTextDelta(let delta):
      responseText += delta

    case .status(let message):
      statusMessage = message

    case .artifactCreated(let artifact):
      artifacts.append(artifact)

    case .usage(let usage):
      self.usage = usage

    case .completed(let message, _):
      completedMessage = message
      responseText = message.content
      phase = .completed

    case .failed(let failure):
      self.failure = failure
      phase = failure.kind == .cancelled ? .cancelled : .failed
    }
  }
}
