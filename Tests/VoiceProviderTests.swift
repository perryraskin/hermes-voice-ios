import XCTest
@testable import HermesVoice
final class VoiceProviderTests:XCTestCase {
    func testSelectionAndLegacyCompatibility() {
        XCTAssertEqual(VoiceProvider.resolve(preference:"fish_live3",available:[.fish,.elevenLabs]),.fish)
        XCTAssertEqual(VoiceProvider.resolve(preference:"elevenlabs",available:[.fish,.elevenLabs]),.elevenLabs)
        XCTAssertEqual(VoiceProvider.resolve(preference:"fish_live3",available:[.elevenLabs]),.elevenLabs)
        XCTAssertEqual(VoiceProvider.available(in:["fish_available":true]),[.fish,.elevenLabs])
        XCTAssertTrue(VoiceProvider.available(in:["voice_providers":["unknown"]]).isEmpty)
        XCTAssertTrue(VoiceProvider.available(in:["voice_providers":[String]()]).isEmpty)
        XCTAssertNil(VoiceProvider.resolve(preference:nil,available:[]))
    }
}
