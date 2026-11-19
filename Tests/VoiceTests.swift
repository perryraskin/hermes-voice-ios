import XCTest
@testable import HermesVoice
final class VoiceTests:XCTestCase {
    @MainActor func testLaunchChecksPairedConnectionOnlyOnce() async {
        let session = VoiceSession()
        session.host = "https://hermes.example.ts.net"
        session.token = ""
        var requests = 0
        let load: (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests += 1
            XCTAssertTrue(session.checkingConnection)
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                                                         statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"profile":"voice","ready":true}"#.utf8), response)
        }
        await session.testConnectionOnLaunch(load: load)
        XCTAssertEqual(requests, 0)
        session.token = "fixture"
        await session.testConnectionOnLaunch(load: load)
        XCTAssertTrue(session.connected)
        XCTAssertFalse(session.checkingConnection)
        session.connected = false
        await session.testConnectionOnLaunch(load: load)
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testLaunchCheckFailureAllowsManualRetry() async {
        let session = VoiceSession()
        session.host = "https://hermes.example.ts.net"
        session.token = "fixture"
        await session.testConnectionOnLaunch { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(session.connected)
        XCTAssertFalse(session.checkingConnection)
        XCTAssertFalse(session.error.isEmpty)
        await session.testConnection { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                                                         statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"profile":"voice","ready":true}"#.utf8), response)
        }
        XCTAssertTrue(session.connected)
        XCTAssertTrue(session.error.isEmpty)
    }

    @MainActor func testLaunchCheckIgnoresResultAfterCredentialsChange() async {
        let session = VoiceSession()
        session.host = "https://hermes.example.ts.net"
        session.token = "fixture"
        await session.testConnectionOnLaunch { _ in
            session.token = ""
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertFalse(session.connected)
        XCTAssertFalse(session.checkingConnection)
        XCTAssertTrue(session.error.isEmpty)
    }

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
