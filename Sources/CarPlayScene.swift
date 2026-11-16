import CarPlay
import UIKit
import Combine

@MainActor final class SharedRuntime {
    static let session = VoiceSession()
}
@MainActor final class CarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var changes: AnyCancellable?
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface=interfaceController
        let states=VoiceState.allCases.map { CPVoiceControlState(identifier:$0.rawValue,titleVariants:[$0.rawValue],image:UIImage(systemName:"waveform"),repeats:false) }
        template=CPVoiceControlTemplate(voiceControlStates:states)
        interfaceController.setRootTemplate(template!,animated:false,completion:nil)
        changes=SharedRuntime.session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        refresh()
    }
    private func refresh() {
        let s=SharedRuntime.session
        template?.activateVoiceControlState(withIdentifier:s.state.rawValue)
        let start=CPBarButton(title:s.active ? (s.muted ? "Unmute":"Mute") : "Start") { _ in
            if s.active { s.toggleMute() } else { SystemCalls.shared.start() }
        }
        template?.leadingNavigationBarButtons=[start]
        template?.trailingNavigationBarButtons=[CPBarButton(title:"End") { _ in SystemCalls.shared.end() }]
    }
    func templateApplicationScene(_ scene:CPTemplateApplicationScene,didDisconnect interfaceController:CPInterfaceController) {
        SharedRuntime.session.pause(); changes=nil; template=nil; interface=nil
    }
}
