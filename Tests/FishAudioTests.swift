import XCTest
import LiveKit
@testable import HermesVoice

final class FishAudioTests:XCTestCase {
    @MainActor func testCallKitGatesTheLiveKitEngineAndManualModeRestoresIt() throws {
        defer { try? FishVoiceTransport.configureAudio(systemManaged:false,active:true) }
        try FishVoiceTransport.configureAudio(systemManaged:true,active:false)
        XCTAssertFalse(AudioManager.shared.audioSession.isAutomaticConfigurationEnabled)
        XCTAssertFalse(AudioManager.shared.engineAvailability.isInputAvailable);XCTAssertFalse(AudioManager.shared.engineAvailability.isOutputAvailable)
        try FishVoiceTransport.configureAudio(systemManaged:true,active:true)
        XCTAssertFalse(AudioManager.shared.audioSession.isAutomaticConfigurationEnabled)
        XCTAssertTrue(AudioManager.shared.engineAvailability.isInputAvailable);XCTAssertTrue(AudioManager.shared.engineAvailability.isOutputAvailable)
        try FishVoiceTransport.configureAudio(systemManaged:true,active:false)
        XCTAssertFalse(AudioManager.shared.engineAvailability.isInputAvailable);XCTAssertFalse(AudioManager.shared.engineAvailability.isOutputAvailable)
        try FishVoiceTransport.configureAudio(systemManaged:false,active:true)
        XCTAssertTrue(AudioManager.shared.audioSession.isAutomaticConfigurationEnabled)
        XCTAssertTrue(AudioManager.shared.engineAvailability.isInputAvailable);XCTAssertTrue(AudioManager.shared.engineAvailability.isOutputAvailable)
    }
}
