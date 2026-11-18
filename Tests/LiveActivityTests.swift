import XCTest
import AVFAudio
@testable import HermesVoice

final class LiveActivityTests:XCTestCase {
    @MainActor func testEndedInterruptionDoesNotStopConversation() async throws {
        let session=SharedRuntime.session;session.end();session.showConversationFixture()
        defer { session.end() }
        NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:nil,userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue])
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertTrue(session.active)
    }
    @MainActor func testStaleActivityCannotControlANewerSession() async throws {
        let session=SharedRuntime.session;session.end();session.showConversationFixture()
        defer { session.end() }
        let stale=UUID().uuidString
        do { _ = try await SetHermesMuteIntent(sessionID:stale,muted:true).perform();XCTFail("A stale activity must not mute the session") } catch {}
        XCTAssertFalse(session.muted)
        do { _ = try await EndHermesSessionIntent(sessionID:stale).perform();XCTFail("A stale activity must not end the session") } catch {}
        XCTAssertTrue(session.active)
        _ = try await SetHermesMuteIntent(sessionID:session.activityIdentifier.uuidString,muted:true).perform()
        XCTAssertTrue(session.muted)
        _ = try await EndHermesSessionIntent(sessionID:session.activityIdentifier.uuidString).perform()
        XCTAssertFalse(session.active)
    }
    @MainActor func testTalkIntentEndsAnActiveConversation() async throws {
        let session=SharedRuntime.session;session.end();session.showConversationFixture()
        defer { session.end() }
        _ = try await StartHermesConversationIntent().perform()
        XCTAssertFalse(session.active)
        XCTAssertEqual(session.state,.ready)
    }
    @MainActor func testTalkIntentReportsAnUnconfiguredHost() async throws {
        let session=SharedRuntime.session;session.end()
        let host=session.host;defer { session.host=host;session.error="" }
        session.host=""
        do { _ = try await StartHermesConversationIntent().perform();XCTFail("Start must fail without a private host") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertFalse(session.active)
    }
}
