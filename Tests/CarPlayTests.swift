import CarPlay
import XCTest
@testable import HermesVoice

final class CarPlayTests: XCTestCase {
    @MainActor func testEveryLifecycleStateSurvivesCarPlayTemplateLimit() {
        for current in VoiceState.allCases {
            let template=CarPlayScene.makeTemplate(current:current)
            XCTAssertLessThanOrEqual(template.voiceControlStates.count,5)
            XCTAssertEqual(template.voiceControlStates.first?.identifier,current.rawValue)
            XCTAssertTrue(template.voiceControlStates.contains(where:{$0.identifier==current.rawValue}))
            XCTAssertEqual(Set(template.voiceControlStates.map(\.identifier)).count,template.voiceControlStates.count)
        }
    }

    @MainActor func testAppRegistersTheActualCarPlaySceneClass() throws {
        let manifest=try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey:"UIApplicationSceneManifest") as? [String:Any])
        let configs=try XCTUnwrap(manifest["UISceneConfigurations"] as? [String:Any])
        let scenes=try XCTUnwrap(configs["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String:Any]])
        let name=try XCTUnwrap(scenes.first?["UISceneDelegateClassName"] as? String)
        XCTAssertEqual(scenes.first?["UISceneClassName"] as? String,"CPTemplateApplicationScene")
        XCTAssertTrue(NSClassFromString(name) === CarPlayScene.self)
    }
}
