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

    @MainActor func testControlsArePresentBeforeTemplatePresentation() {
        for state in [VoiceState.ready,.paused,.failed] {
            let template=CarPlayScene.makeTemplate(current:state)
            XCTAssertEqual(template.trailingNavigationBarButtons.first?.title,"Talk")
            XCTAssertEqual(template.trailingNavigationBarButtons.first?.buttonStyle,.rounded)
            XCTAssertEqual(template.trailingNavigationBarButtons.first?.isEnabled,true)
        }
        let connecting=CarPlayScene.makeTemplate(current:.connecting)
        XCTAssertEqual(connecting.trailingNavigationBarButtons.first?.title,"End")
        let active=CarPlayScene.makeTemplate(current:.listening,active:true)
        XCTAssertEqual(active.leadingNavigationBarButtons.first?.title,"Mute")
        XCTAssertEqual(active.trailingNavigationBarButtons.first?.title,"End")
        CarPlayScene.configureControls(active,snapshot:CarPlaySnapshot(state:.listening,active:true,muted:true))
        XCTAssertEqual(active.leadingNavigationBarButtons.first?.title,"Unmute")
    }

    func testCarPlayCallbackCanArriveOnBackgroundQueue() async {
        let handled=expectation(description:"CarPlay action reaches main actor")
        let handler=CarPlayScene.controlHandler {
            XCTAssertTrue(Thread.isMainThread)
            handled.fulfill()
        }
        DispatchQueue.global().async { handler(CPBarButton(title:"Talk",handler:nil)) }
        await fulfillment(of:[handled],timeout:2)
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
