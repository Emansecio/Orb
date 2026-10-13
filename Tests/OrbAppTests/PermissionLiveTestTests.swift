import CoreGraphics
import Foundation
import Testing
@testable import Orb

/// "Testar" on the Permissões tab: what a capture or an Accessibility read says about the permission, and what each row
/// shows from it. Nothing here captures the screen or reads another app.
struct PermissionLiveTestTests {
    private func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test func aCaptureWorksOnlyWhenItShowsSomething() throws {
        let black = try image { $0.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let screen = try image {
            $0.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            $0.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)); $0.fill(CGRect(x: 8, y: 8, width: 40, height: 30))
        }
        #expect(PermissionTestOutcome.screenRecording(.success(screen)) == .working)
        #expect(PermissionTestOutcome.screenRecording(.success(black)) == .broken, "a black frame is the permission not in effect")
        let refused = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        #expect(PermissionTestOutcome.screenRecording(.failure(refused)) == .broken)
        #expect(PermissionTestOutcome.screenRecording(.failure(CancellationError())) == .inconclusive)
    }

    @Test func onlyARefusedAccessibilityReadBlamesThePermission() {
        #expect(PermissionTestOutcome.accessibility(.values(["AXRole": .string("AXApplication")])) == .working)
        #expect(PermissionTestOutcome.accessibility(.failed(.apiDisabled)) == .broken)
        #expect(PermissionTestOutcome.accessibility(.failed(.cannotComplete)) == .inconclusive, "a busy Dock says nothing")
        #expect(PermissionTestOutcome.accessibility(.values([:])) == .inconclusive)
    }

    private func row(_ kind: MacPermissionKind, _ status: MacPermissionStatus?, canAsk: Bool = false, awaitsRelaunch: Bool = false,
                     test: PermissionTestOutcome? = nil, isTesting: Bool = false, isAsking: Bool = false) -> PermissionRowState {
        PermissionRowState.make(kind: kind, status: status, isAsking: isAsking, canAsk: canAsk, awaitsRelaunch: awaitsRelaunch,
                                test: test, isTesting: isTesting)
    }

    @Test func aGrantedRowOffersTheTestAndShowsWhatItFound() {
        #expect(row(.screenRecording, .granted) == PermissionRowState(badge: .status(.granted), actions: [.test]))
        #expect(row(.accessibility, .granted, isTesting: true) == PermissionRowState(badge: .testing, actions: [.test]))
        #expect(row(.accessibility, .granted, test: .working) == PermissionRowState(badge: .working, actions: [.test]))
        #expect(row(.screenRecording, .granted, test: .inconclusive)
                == PermissionRowState(badge: .status(.granted), actions: [.test], note: PermissionRowState.inconclusive))
        #expect(row(.fullDiskAccess, .granted) == PermissionRowState(badge: .status(.granted), actions: []), "no live test for it")
        #expect(PermissionRowAction.test.title == "Testar")
    }

    @Test func aBrokenTestPointsAtTheFixOfEachPermission() {
        let screen = row(.screenRecording, .granted, test: .broken)
        #expect(screen == PermissionRowState(badge: .broken, actions: [.relaunch], note: PermissionRowState.screenRecordingBroken))
        #expect(screen.note?.contains("reabrir o Orb") == true)
        let accessibility = row(.accessibility, .granted, test: .broken)
        #expect(accessibility.actions == [.openSystemSettings])
        #expect(accessibility.note?.contains("remova o Orb da lista de Acessibilidade") == true)
        #expect(PermissionRowAction.relaunch.title == "Reabrir o Orb")
    }

    @Test func screenRecordingThatMacOSCannotGrantAnymoreOffersToReopenNotToAskAgain() {
        let waiting = row(.screenRecording, .notGranted, awaitsRelaunch: true)
        #expect(waiting.actions == [.openSystemSettings, .relaunch])
        #expect(waiting.note == PermissionRowState.awaitingRelaunch)
        #expect(row(.screenRecording, .notGranted, canAsk: true).actions == [.ask], "before macOS was asked, asking still helps")
    }

    @Test func otherRowsKeepTheirSingleButton() {
        let mail = MacPermissionKind.automation(AutomationTarget.known[0])
        #expect(row(.accessibility, nil) == PermissionRowState(badge: .loading, actions: []))
        #expect(row(.accessibility, .notGranted, canAsk: true, isAsking: true) == PermissionRowState(badge: .asking, actions: [.ask]))
        #expect(row(mail, .appNotRunning) == PermissionRowState(badge: .status(.appNotRunning), actions: [.openAppAndAsk(appName: "Mail")],
                                                                 note: PermissionRowState.appClosed))
        #expect(row(.fullDiskAccess, .notGranted) == PermissionRowState(badge: .status(.notGranted), actions: [.openSystemSettings]))
    }
}

/// The tab's model with scripted tests: no capture, no Accessibility read, no prompt.
@MainActor
struct PermissionLiveTestModelTests {
    private func model(_ stub: StubMacPermissionSystem, outcome: PermissionTestOutcome) -> MacPermissionsModel {
        MacPermissionsModel(checker: MacPermissionChecker(system: stub), tester: MacPermissionTester { _ in outcome },
                            notifications: { .allowed })
    }

    @Test func aTestResultLastsWhileThePermissionStaysGranted() async {
        let stub = StubMacPermissionSystem()
        stub.screenRecording = true
        let model = model(stub, outcome: .broken)
        await model.refresh()
        await model.test(.screenRecording)
        #expect(model.row(.screenRecording).badge == .broken)
        #expect(model.testing.isEmpty)
        await model.refresh()
        #expect(model.tests[.screenRecording] == .broken)
        stub.screenRecording = false
        await model.refresh()
        #expect(model.tests.isEmpty, "a result about a permission that is gone is dropped")
        #expect(stub.recordedRequests.isEmpty)
    }

    @Test func goingToSystemSettingsForScreenRecordingOffersToReopen() async {
        let stub = StubMacPermissionSystem()
        let model = model(stub, outcome: .working)
        await model.refresh()
        var opened: [MacPrivacyPane] = []
        model.openSettings(.accessibility) { opened.append($0) }
        #expect(model.awaitsRelaunch.isEmpty, "Accessibility applies without a restart")
        model.openSettings(.screenRecording) { opened.append($0) }
        #expect(opened == [.accessibility, .screenRecording])
        #expect(model.row(.screenRecording).actions == [.openSystemSettings, .relaunch])
        #expect(!model.canAsk(.screenRecording))
    }

    @Test func theWatchRereadsOnlyTheEssentialsAndStopsWithTheTab() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", 0)
        let model = model(stub, outcome: .working)
        await model.refresh()
        let readsBefore = stub.asks.count
        let watching = Task { await model.watch(every: .milliseconds(10)) }
        stub.accessibility = true
        let deadline = ContinuousClock.now + .seconds(2)
        while model.status(of: .accessibility) != .granted, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.status(of: .accessibility) == .granted, "a switch turned in System Settings shows without coming back to the app")
        watching.cancel()
        await watching.value
        #expect(stub.asks.count == readsBefore, "Automation is not polled")
        #expect(model.status(of: .automation(AutomationTarget.known[0])) == .granted, "rows that are not polled keep their status")
    }
}
