import XCTest
@testable import HermesVoice
final class VoiceTests:XCTestCase {
    @MainActor func testPrivateHostValidation() throws { let s=VoiceSession(); for host in ["http://host.ts.net","https://example.com","https://host.ts.net?token=secret","https://user:pass@host.ts.net"] { s.host=host; XCTAssertThrowsError(try s.baseURL()) }; s.host="https://host.tail123.ts.net:12322"; XCTAssertNoThrow(try s.baseURL()) }
    @MainActor func testEndInvalidatesLateAudio() throws { let s=VoiceSession(); s.end(); try s.handle(WireEvent(type:"audio",text:nil,audio:"AA==",turn:"old")); XCTAssertEqual(s.state,.ready); XCTAssertFalse(s.active) }
}
