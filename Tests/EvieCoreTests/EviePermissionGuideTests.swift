import Foundation
import Testing

@testable import EvieCore

@Suite("Evie permission guide")
struct EviePermissionGuideTests {
  @Test("lists the five system permissions in the order the guide asks for them")
  func listsThePermissionsInOrder() {
    // Input Monitoring is deliberately absent: it is added only if the takeover
    // monitor turns out to need a listen-only event tap.
    #expect(
      EviePermission.allCases == [
        .microphone, .speechRecognition, .screenRecording, .accessibility, .postEvents,
      ]
    )
  }

  @Test(
    "every permission opens its own Privacy & Security pane",
    arguments: [
      (EviePermission.microphone, "Privacy_Microphone"),
      (.speechRecognition, "Privacy_SpeechRecognition"),
      (.screenRecording, "Privacy_ScreenCapture"),
      (.accessibility, "Privacy_Accessibility"),
      // Posting events is granted on the Accessibility list; macOS has no
      // separate pane for it.
      (.postEvents, "Privacy_Accessibility"),
    ]
  )
  func deepLinksToThePane(permission: EviePermission, anchor: String) {
    #expect(
      permission.settingsURL.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    )
  }

  @Test("a granted permission is marked done and offers no button")
  func grantedOffersNothing() {
    let row = PermissionGuideRow.permission(
      .microphone, status: .granted, alreadyRequested: true
    )

    #expect(row.mark == .satisfied)
    #expect(row.action == nil)
  }

  @Test("a permission never asked for offers to ask")
  func undeterminedOffersRequest() {
    let row = PermissionGuideRow.permission(
      .speechRecognition, status: .notDetermined, alreadyRequested: false
    )

    #expect(row.mark == .pending)
    #expect(row.action == PermissionGuideRow.Action(title: "Pedir", kind: .request))
  }

  @Test("a refused permission sends the user to its pane, because macOS will not ask twice")
  func deniedOffersSettings() {
    let row = PermissionGuideRow.permission(
      .microphone, status: .denied, alreadyRequested: false
    )

    #expect(row.mark == .refused)
    #expect(
      row.action
        == PermissionGuideRow.Action(
          title: "Abrir Ajustes", kind: .openSettings(EviePermission.microphone.settingsURL)
        )
    )
  }

  @Test("a yes-or-no permission is requested once, then only offers the pane")
  func yesOrNoPermissionIsRequestedOnce() {
    let beforeAsking = PermissionGuideRow.permission(
      .screenRecording, status: .notGranted, alreadyRequested: false
    )
    let afterAsking = PermissionGuideRow.permission(
      .screenRecording, status: .notGranted, alreadyRequested: true
    )

    #expect(beforeAsking.action?.kind == .request)
    #expect(beforeAsking.mark == .pending)
    #expect(
      afterAsking.action?.kind == .openSettings(EviePermission.screenRecording.settingsURL)
    )
    #expect(afterAsking.mark == .refused)
  }

  @Test("only Screen Recording tells the user to reopen Evie after allowing it")
  func onlyScreenRecordingNeedsARelaunch() {
    for permission in EviePermission.allCases {
      let row = PermissionGuideRow.permission(
        permission, status: .notGranted, alreadyRequested: false
      )
      if permission == .screenRecording {
        #expect(row.hint?.contains("reabra a Evie") == true)
      } else {
        #expect(row.hint == nil, "\(permission.rawValue) should not ask for a relaunch")
      }
    }
  }

  @Test("the row id is the permission, so a refresh replaces the row in place")
  func rowIdentityIsThePermission() {
    let before = PermissionGuideRow.permission(
      .accessibility, status: .notGranted, alreadyRequested: false
    )
    let after = PermissionGuideRow.permission(
      .accessibility, status: .granted, alreadyRequested: true
    )

    #expect(before.id == after.id)
    #expect(before != after)
  }
}

@Suite("Evie permission guide record")
struct EviePermissionGuideRecordTests {
  @Test("a missing file is a first launch")
  func missingFileIsFirstLaunch() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PermissionGuideStore(fileURL: directory.appendingPathComponent("guide.json"))

    let record = store.load()

    #expect(record.dismissed == false)
    #expect(record.requested.isEmpty)
  }

  @Test("what was asked and whether the guide was closed survive a relaunch")
  func roundTrips() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("nested/guide.json")
    let store = PermissionGuideStore(fileURL: fileURL)

    var record = PermissionGuideRecord()
    record.dismissed = true
    record.requested = [.screenRecording, .postEvents]
    try store.save(record)

    #expect(PermissionGuideStore(fileURL: fileURL).load() == record)
    let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
  }

  @Test("a damaged file shows the guide again rather than failing launch")
  func damagedFileIsFirstLaunch() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("guide.json")
    try Data("{ not json".utf8).write(to: fileURL)

    #expect(PermissionGuideStore(fileURL: fileURL).load() == PermissionGuideRecord())
  }

  @Test("an unknown permission written by a newer build is ignored, not fatal")
  func unknownPermissionIsIgnored() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("guide.json")
    try Data(
      #"{"schema_version":1,"dismissed":true,"requested":["screen_recording","input_monitoring"]}"#
        .utf8
    ).write(to: fileURL)

    let record = PermissionGuideStore(fileURL: fileURL).load()

    #expect(record.dismissed)
    #expect(record.requested == [.screenRecording])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-permission-guide-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
