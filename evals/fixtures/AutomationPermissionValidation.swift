import AppKit
import ApplicationServices
import EvieCore
import Foundation

// The production row/request state machine is compiled unchanged. Only the
// launch, Automation probe and Settings boundaries are injected: no OS prompt,
// target application, private data or credential is touched by this fixture.
private struct AutomationCheckFailure: Error { let message: String }
private struct SyntheticLaunchFailure: LocalizedError {
  var errorDescription: String? { "synthetic launch failure" }
}

private actor ControlledAutomationProbe {
  private var opened = false
  private var status: OSStatus
  private let requestedStatus: OSStatus
  private let suspendRefresh: Bool
  private let suspendRequest: Bool
  private var pendingRefresh: [CheckedContinuation<OSStatus, Never>] = []
  private var pendingRequest: [CheckedContinuation<OSStatus, Never>] = []
  private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var refreshCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var events: [String] = []
  private(set) var refreshCalls = 0
  private(set) var requestCalls = 0

  init(
    status: OSStatus = OSStatus(procNotFound), requestedStatus: OSStatus = noErr,
    suspendRefresh: Bool = false, suspendRequest: Bool = false
  ) {
    self.status = status
    self.requestedStatus = requestedStatus
    self.suspendRefresh = suspendRefresh
    self.suspendRequest = suspendRequest
  }

  func open() {
    events.append("open")
    opened = true
  }

  func probe(_ request: Bool) async -> OSStatus {
    events.append(request ? "request" : "refresh")
    if request {
      requestCalls += 1
      let waiters = requestWaiters
      requestWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      if suspendRequest {
        return await withCheckedContinuation { pendingRequest.append($0) }
      }
      status = opened ? requestedStatus : OSStatus(procNotFound)
      return status
    }
    refreshCalls += 1
    let counted = refreshCountWaiters.filter { $0.0 <= refreshCalls }
    refreshCountWaiters.removeAll { $0.0 <= refreshCalls }
    for (_, waiter) in counted { waiter.resume() }
    let waiters = refreshWaiters
    refreshWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if suspendRefresh {
      return await withCheckedContinuation { pendingRefresh.append($0) }
    }
    return status
  }

  func waitUntilRefreshEntered() async {
    if refreshCalls > 0 { return }
    await withCheckedContinuation { refreshWaiters.append($0) }
  }

  func waitForRefreshCount(_ count: Int) async {
    if refreshCalls >= count { return }
    await withCheckedContinuation { refreshCountWaiters.append((count, $0)) }
  }

  func waitUntilRequestEntered() async {
    if requestCalls > 0 { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }

  func finishRefresh(with value: OSStatus) {
    let waiters = pendingRefresh
    pendingRefresh.removeAll()
    for waiter in waiters { waiter.resume(returning: value) }
  }

  func finishRequest(with value: OSStatus) {
    let waiters = pendingRequest
    pendingRequest.removeAll()
    for waiter in waiters { waiter.resume(returning: value) }
  }
}

@MainActor
private final class AutomationSettingsSink {
  private(set) var opened: [URL] = []
  private var results: [Bool]

  init(results: [Bool] = [true]) { self.results = results }

  func open(_ url: URL) -> Bool {
    opened.append(url)
    return results.isEmpty ? true : results.removeFirst()
  }
}

// Compile the entire production guide VM, including its standardItems factory.
// These unrelated hardware/key/network factories must never run in this test.
@MainActor final class EvieAudioCapture {
  init() { fatalError("Unexpected real audio factory in Automation validation") }
}

@MainActor struct SystemPermissionItem: PermissionGuideItem {
  init(permission: EviePermission, audioCapture: EvieAudioCapture) {
    fatalError("Unexpected system-permission factory in Automation validation")
  }
  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    fatalError("Unused factory")
  }
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    fatalError("Unused factory")
  }
}

@MainActor struct PCKeyItem: PermissionGuideItem {
  init(step: EvieGuidePCKeyStep) {
    fatalError("Unexpected Keychain factory in Automation validation")
  }
  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    fatalError("Unused factory")
  }
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    fatalError("Unused factory")
  }
}

@MainActor struct BrainConnectionItem: PermissionGuideItem {
  init(step: EvieGuideBrainStep) { fatalError("Unexpected model factory in Automation validation") }
  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    fatalError("Unused factory")
  }
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    fatalError("Unused factory")
  }
}

@MainActor
private final class AutomationPreparationTrace {
  enum Event: Equatable { case preparing, batchFinished }
  private var first: Event?
  private var waiters: [CheckedContinuation<Event, Never>] = []

  func record(_ event: Event) {
    guard first == nil else { return }
    first = event
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: event) }
  }

  func waitForFirstEvent() async -> Event {
    if let first { return first }
    return await withCheckedContinuation { waiters.append($0) }
  }
}

/// Observes the actual protocol boundary; every operation still reaches the
/// production Automation item and the VM itself remains unchanged.
@MainActor
private struct ObservedAutomationItem: PermissionGuideItem {
  let item: AutomationPermissionItem
  let trace: AutomationPreparationTrace
  func row(given record: PermissionGuideRecord) -> PermissionGuideRow { item.row(given: record) }
  func refreshStatus() { item.refreshStatus() }
  func observeRowChanges(_ callback: @escaping @MainActor () -> Void) {
    item.observeRowChanges(callback)
  }
  func prepareForRequest() async {
    trace.record(.preparing)
    await item.prepareForRequest()
  }
  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    await item.perform(action)
  }
}

@main
struct AutomationPermissionValidation {
  @MainActor
  static func main() async {
    do {
      try await closedTargetOpensBeforeRequest()
      try await deniedOpensSettingsWithoutRequesting()
      try await successfulSettingsRetryClearsPreviousFailure()
      try await launchFailureIsVisibleAndNeverRequests()
      try await unknownStatusIsVisible()
      try await refreshIsCachedAndCoalesced()
      try await staleRefreshCannotReplaceRequest()
      try await pendingProbeKeepsMainActorResponsive()
      try await bulkRequestWaitsForInitialAutomationStatus()
      print(
        "PASS: production Automation item and complete guide VM; 9 controlled launch/probe/cache/bulk cases; no UI/TCC/network"
      )
    } catch {
      let message = (error as? AutomationCheckFailure)?.message ?? String(describing: error)
      FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
      exit(1)
    }
  }

  @MainActor
  private static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw AutomationCheckFailure(message: message) }
  }

  @MainActor
  private static func item(
    probe: ControlledAutomationProbe, settings: AutomationSettingsSink = AutomationSettingsSink()
  ) -> AutomationPermissionItem {
    AutomationPermissionItem(
      bundleID: "invalid.example.synthetic-calendar", title: "Synthetic Calendar",
      probe: { request in await probe.probe(request) },
      openTarget: { await probe.open() },
      openSettings: { settings.open($0) })
  }

  @MainActor
  private static func refresh(_ item: AutomationPermissionItem) async {
    item.refreshStatus()
    await item.validationRefreshTask()?.value
  }

  @MainActor
  private static func closedTargetOpensBeforeRequest() async throws {
    let probe = ControlledAutomationProbe()
    let model = item(probe: probe)
    await refresh(model)
    let before = model.row(given: PermissionGuideRecord())
    try check(before.action?.kind == .request, "closed target did not offer the request action")
    let result = await model.perform(PermissionGuideRow.Action(title: "Pedir", kind: .request))
    let row = model.row(given: PermissionGuideRecord())
    try check(
      row.mark == .satisfied && row.statusText == "Permitido",
      "closed target was requested before opening")
    let events = await probe.events
    try check(events.suffix(2) == ["open", "request"], "launch/request order was not preserved")
    try check(result == nil, "Automation request was misreported as a five-permission prompt")
  }

  @MainActor
  private static func deniedOpensSettingsWithoutRequesting() async throws {
    let probe = ControlledAutomationProbe(status: OSStatus(errAEEventNotPermitted))
    let settings = AutomationSettingsSink()
    let model = item(probe: probe, settings: settings)
    await refresh(model)
    let row = model.row(given: PermissionGuideRecord())
    guard let action = row.action, case .openSettings = action.kind else {
      throw AutomationCheckFailure(message: "denied Automation did not offer Settings")
    }
    _ = await model.perform(action)
    try check(settings.opened.count == 1, "denied Automation did not open its Settings route")
    try check(
      settings.opened.first?.absoluteString.contains("Privacy_Automation") == true,
      "wrong Settings pane")
    try check(await probe.requestCalls == 0, "denied Automation requested again")
    try check(!(await probe.events).contains("open"), "Settings action launched the target")
  }

  @MainActor
  private static func successfulSettingsRetryClearsPreviousFailure() async throws {
    let probe = ControlledAutomationProbe(status: OSStatus(errAEEventNotPermitted))
    let settings = AutomationSettingsSink(results: [false, true])
    let model = item(probe: probe, settings: settings)
    var changes = 0
    model.observeRowChanges { changes += 1 }
    await refresh(model)
    guard let action = model.row(given: PermissionGuideRecord()).action,
      case .openSettings = action.kind
    else { throw AutomationCheckFailure(message: "denied retry did not offer Settings") }
    _ = await model.perform(action)
    let first = model.row(given: PermissionGuideRecord())
    try check(
      first.hint?.contains("Não consegui abrir os Ajustes") == true,
      "failed Settings opening was not visible")
    // Merely refreshing a still-denied grant must not pretend that Settings
    // opened. The second successful action is what resolves this launch error.
    await refresh(model)
    try check(
      model.row(given: PermissionGuideRecord()).hint?.contains("Não consegui abrir os Ajustes")
        == true,
      "denied refresh discarded an unresolved Settings-opening error")
    let changesBeforeRetry = changes
    _ = await model.perform(action)
    let retried = model.row(given: PermissionGuideRecord())
    try check(
      retried.hint?.contains("Não consegui abrir os Ajustes") != true,
      "successful Settings retry retained a previous opening error")
    try check(retried.mark == .refused, "Settings retry changed the denied authorization")
    try check(
      retried.action?.title == "Abrir Ajustes", "Settings retry lost the denied-state action")
    try check(settings.opened.count == 2, "Settings retry did not attempt both openings")
    try check(changes > changesBeforeRetry, "successful Settings retry did not notify the guide")
    try check(await probe.requestCalls == 0, "Settings retry asked for Automation again")
  }

  @MainActor
  private static func launchFailureIsVisibleAndNeverRequests() async throws {
    let probe = ControlledAutomationProbe()
    let model = AutomationPermissionItem(
      bundleID: "invalid.example.synthetic-calendar", title: "Synthetic Calendar",
      probe: { request in await probe.probe(request) },
      openTarget: { throw SyntheticLaunchFailure() }, openSettings: { _ in true })
    _ = await model.perform(PermissionGuideRow.Action(title: "Pedir", kind: .request))
    let row = model.row(given: PermissionGuideRecord())
    let visible = row.statusText + " " + (row.hint ?? "") + " " + row.detail
    try check(visible.contains("synthetic launch failure"), "target launch failure was hidden")
    try check(row.mark != .satisfied, "failed target launch claimed permission")
    try check(await probe.requestCalls == 0, "failed target launch still requested Automation")
  }

  @MainActor
  private static func unknownStatusIsVisible() async throws {
    let probe = ControlledAutomationProbe(status: OSStatus(-12_345))
    let model = item(probe: probe)
    await refresh(model)
    let row = model.row(given: PermissionGuideRecord())
    let visible = row.statusText + " " + (row.hint ?? "") + " " + row.detail
    try check(visible.contains("-12345"), "unknown OSStatus was hidden as a generic denial")
    try check(row.mark != .satisfied, "unknown OSStatus claimed permission")
  }

  @MainActor
  private static func refreshIsCachedAndCoalesced() async throws {
    let probe = ControlledAutomationProbe(suspendRefresh: true)
    let model = item(probe: probe)
    var changes = 0
    model.observeRowChanges { changes += 1 }
    for _ in 0..<5 { model.refreshStatus() }
    await probe.waitUntilRefreshEntered()
    let pending = model.validationRefreshTask()
    for _ in 0..<100 { _ = model.row(given: PermissionGuideRecord()) }
    try check(
      await probe.refreshCalls == 1, "row access or concurrent refresh duplicated the probe")
    await probe.finishRefresh(with: noErr)
    await pending?.value
    try check(
      model.row(given: PermissionGuideRecord()).mark == .satisfied,
      "coalesced refresh did not update the cache")
    try check(changes > 0, "refresh did not notify the guide")
  }

  @MainActor
  private static func staleRefreshCannotReplaceRequest() async throws {
    let probe = ControlledAutomationProbe(suspendRefresh: true)
    let model = item(probe: probe)
    model.refreshStatus()
    await probe.waitUntilRefreshEntered()
    let staleTask = model.validationRefreshTask()
    _ = await model.perform(PermissionGuideRow.Action(title: "Pedir", kind: .request))
    try check(
      model.row(given: PermissionGuideRecord()).mark == .satisfied,
      "request did not publish permission")
    await probe.finishRefresh(with: OSStatus(procNotFound))
    await staleTask?.value
    try check(
      model.row(given: PermissionGuideRecord()).mark == .satisfied,
      "stale refresh replaced the request result")
  }

  @MainActor
  private static func pendingProbeKeepsMainActorResponsive() async throws {
    let probe = ControlledAutomationProbe(suspendRequest: true)
    let model = item(probe: probe)
    let request = Task {
      await model.perform(PermissionGuideRow.Action(title: "Pedir", kind: .request))
    }
    await probe.waitUntilRequestEntered()
    var pulse = false
    let mainActorPulse = Task { @MainActor in pulse = true }
    await mainActorPulse.value
    try check(
      model.row(given: PermissionGuideRecord()).action == nil,
      "pending request still exposed a second permission action")
    for _ in 0..<5 { model.refreshStatus() }
    let duplicate = await model.perform(PermissionGuideRow.Action(title: "Pedir", kind: .request))
    try check(duplicate == nil, "coalesced duplicate reported a new system permission")
    try check(await probe.requestCalls == 1, "pending request allowed a second authorization probe")
    try check(await probe.refreshCalls == 0, "pending request started a competing refresh")
    try check(pulse, "MainActor could not run while the authorization probe was pending")
    await probe.finishRequest(with: noErr)
    _ = await request.value
    try check(
      model.row(given: PermissionGuideRecord()).mark == .satisfied,
      "responsive request did not settle")
  }

  @MainActor
  private static func bulkRequestWaitsForInitialAutomationStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = ControlledAutomationProbe(suspendRefresh: true)
    let automation = item(probe: probe)
    let trace = AutomationPreparationTrace()
    let guide = PermissionGuideViewModel(
      items: [ObservedAutomationItem(item: automation, trace: trace)],
      store: PermissionGuideStore(fileURL: directory.appendingPathComponent("guide.json")),
      isBundled: true)
    await probe.waitUntilRefreshEntered()
    try check(
      guide.rows.first?.action == nil,
      "bulk fixture did not begin with an unresolved cached Automation status")
    let initialRefresh = automation.validationRefreshTask()
    let request = Task {
      await guide.requestAvailablePermissions()
      trace.record(.batchFinished)
    }
    let first = await trace.waitForFirstEvent()
    guard first == .preparing else {
      await probe.finishRefresh(with: OSStatus(procNotFound))
      await initialRefresh?.value
      await request.value
      throw AutomationCheckFailure(message: "bulk request skipped asynchronous status preparation")
    }
    try check(await probe.requestCalls == 0, "bulk request prompted before status was available")
    await probe.finishRefresh(with: OSStatus(procNotFound))
    await request.value
    // VM.perform refreshes the visible rows after the request. Resolve that
    // final status probe too, then await the real task before checking output.
    let finalRefresh = automation.validationRefreshTask()
    await probe.waitForRefreshCount(2)
    await probe.finishRefresh(with: noErr)
    await finalRefresh?.value
    try check(
      await probe.requestCalls == 1, "bulk request did not ask exactly once after readiness")
    let events = await probe.events
    try check(
      events.filter { $0 == "open" }.count == 1,
      "bulk request did not open its closed target exactly once")
    try check(
      guide.rows.count == 1 && guide.rows.first?.mark == .satisfied,
      "bulk request did not publish the allowed Automation row")
    try check(guide.busyRows.isEmpty, "bulk request left its row busy")
  }
}
