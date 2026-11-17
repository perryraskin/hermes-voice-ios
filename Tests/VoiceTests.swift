import XCTest
@testable import HermesVoice
final class VoiceTests:XCTestCase {
    @MainActor func testPrivateHostValidation() throws { let s=VoiceSession(); for host in ["http://host.ts.net","https://example.com","https://host.ts.net?token=secret","https://user:pass@host.ts.net"] { s.host=host; XCTAssertThrowsError(try s.baseURL()) }; s.host="https://host.tail123.ts.net:12322"; XCTAssertNoThrow(try s.baseURL()) }
    @MainActor func testEndInvalidatesLateAudio() throws { let s=VoiceSession(); s.end(); try s.handle(WireEvent(type:"audio",text:nil,audio:"AA==",turn:"old")); try s.handle(WireEvent(type:"pcm_audio",text:nil,audio:"AQACAA==",turn:"old")); XCTAssertEqual(s.state,.ready); XCTAssertFalse(s.active) }
    @MainActor func testPCMUsesCaptureEngineAndInterruptStopsPlayback() throws {
        let session=VoiceSession();session.showConversationFixture()
        defer { session.end() }
        try session.handle(WireEvent(type:"ready",text:nil,audio:nil,turn:nil))
        try session.handle(WireEvent(type:"committed",text:"Test",audio:nil,turn:"pcm-test"))
        try session.handle(WireEvent(type:"pcm_audio",text:nil,audio:Data(repeating:0,count:24000).base64EncodedString(),turn:"pcm-test"))
        XCTAssertEqual(session.state,.speaking)
        try session.handle(WireEvent(type:"interrupted",text:nil,audio:nil,turn:nil))
        XCTAssertEqual(session.state,.listening)
        try session.handle(WireEvent(type:"pcm_audio",text:nil,audio:"AQACAA==",turn:"pcm-test"))
        XCTAssertEqual(session.state,.listening)
    }
}
