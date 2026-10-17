import Foundation
import Synchronization
import Testing

@testable import EvieCore

@Suite("Nonblocking Keychain status refresh", .serialized)
@MainActor
struct EvieModelKeyStatusRefreshTests {
  private let saved = CredentialReference(
    service: "synthetic", account: "saved", boundHost: "saved.invalid")
  private let missing = CredentialReference(
    service: "synthetic", account: "missing", boundHost: "missing.invalid")

  @Test("blocked attributes coalesce and never publish an old credential's status")
  func blockedAttributesRejectStaleResults() async throws {
    let items = BlockedStatusItems()
    defer { items.release() }
    let refresh = EvieModelKeyStatusRefresh(
      keys: EvieModelKeys(items: items, credentials: StaticCredentialProvider()))
    var published: [EvieModelKeyStatus] = []
    refresh.onChange = { if let value = refresh.statuses["brain"] { published.append(value) } }
    refresh.refresh(["brain": saved])
    try await waitUntil { items.calls == 1 }
    for _ in 0..<100 { refresh.refresh(["brain": saved]) }
    refresh.refresh(["brain": missing])
    #expect(items.calls == 1)
    #expect(refresh.statuses["brain"] == .checking)
    #expect(!items.wasOnMainThread)
    items.release()
    try await waitUntil { refresh.statuses["brain"] == .missing }
    #expect(items.calls == 2)
    #expect(!published.contains(.saved))
    for _ in 0..<100 { refresh.refresh(["brain": missing], force: false) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(items.calls == 2)
  }

  @Test("an explicit refresh updates a cached status without rendering polling")
  func explicitRefreshUpdatesCache() async throws {
    let items = BlockedStatusItems()
    items.release()
    let refresh = EvieModelKeyStatusRefresh(
      keys: EvieModelKeys(items: items, credentials: StaticCredentialProvider()))
    refresh.refresh(["brain": saved])
    try await waitUntil { refresh.statuses["brain"] == .saved }
    items.markSaved(false)
    refresh.refresh(["brain": saved])
    try await waitUntil { refresh.statuses["brain"] == .missing }
    #expect(items.calls == 2)
    #expect(!items.wasOnMainThread)
    refresh.refresh([:])
    #expect(refresh.statuses.isEmpty)
  }

  @Test("a guide row renders and later reports attributes without reading secrets")
  func guideRendersWhileKeychainWaits() async throws {
    let items = BlockedStatusItems()
    defer { items.release() }
    let step = EvieGuidePCKeyStep(
      keys: EvieModelKeys(items: items, credentials: StaticCredentialProvider()),
      configuration: { .builtIn }, onKeySaved: { _ in })
    var notifications = 0
    step.onStatusChanged = { notifications += 1 }
    let row = step.row
    #expect(row.statusText == "Verificando…")
    #expect(row.action == nil)
    try await waitUntil { items.calls == 1 }
    #expect(!items.wasOnMainThread)
    items.release()
    try await waitUntil { step.row.mark == .satisfied }
    #expect(notifications >= 2)
    #expect(items.secretReads == 0)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
  }
}

private final class BlockedStatusItems: EvieKeychainItems, Sendable {
  private struct State {
    var released = false
    var calls = 0
    var wasOnMainThread = false
    var saved = true
    var secretReads = 0
  }
  private let state = Mutex(State())
  private let gate = DispatchSemaphore(value: 0)
  var calls: Int { state.withLock { $0.calls } }
  var wasOnMainThread: Bool { state.withLock { $0.wasOnMainThread } }
  var secretReads: Int { state.withLock { $0.secretReads } }
  func contains(_ item: KeychainItemName) throws -> Bool {
    let blocks = state.withLock { value in
      value.calls += 1
      value.wasOnMainThread = value.wasOnMainThread || Thread.isMainThread
      return !value.released
    }
    if blocks { gate.wait() }
    return state.withLock { $0.saved && item.account != "missing" }
  }
  func read(_ item: KeychainItemName) throws -> String? {
    state.withLock { $0.secretReads += 1 }
    return nil
  }
  func write(_ secret: String, to item: KeychainItemName, label: String) throws {}
  func release() {
    state.withLock { $0.released = true }
    gate.signal()
  }
  func markSaved(_ saved: Bool) { state.withLock { $0.saved = saved } }
}
