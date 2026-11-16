import CarPlay
import UIKit
import Combine

@MainActor final class SharedRuntime {
    static let session: VoiceSession = {
        let session=VoiceSession()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--showcase-conversation") { session.showConversationFixture() }
        #endif
        return session
    }()
}

struct CarPlaySnapshot: Equatable {
    let state: VoiceState
    let active: Bool
    let muted: Bool
}

@MainActor final class CarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var changes: AnyCancellable?
    private var presented=false
    private var lastSnapshot: CarPlaySnapshot?
    private static let artwork: UIImage = {
        // Rasterize the SF Symbol so the XPC template receives a concrete image.
        let renderer=UIGraphicsImageRenderer(size:CGSize(width:150,height:150))
        return renderer.image { _ in
            UIImage(systemName:"waveform")?.withTintColor(.systemGreen,renderingMode:.alwaysOriginal)
                .draw(in:CGRect(x:15,y:15,width:120,height:120))
        }
    }()

    static func makeTemplate(current: VoiceState) -> CPVoiceControlTemplate {
        // CarPlay discards every state after the first five. Always include the
        // current state first; replace the template for an uncached state.
        var states=[current]
        for state in [VoiceState.ready,.connecting,.listening,.thinking,.speaking,.paused,.failed] where !states.contains(state) {
            states.append(state)
        }
        return CPVoiceControlTemplate(voiceControlStates:states.prefix(5).map {
            CPVoiceControlState(identifier:$0.rawValue,titleVariants:[$0.rawValue],image:artwork,repeats:false)
        })
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface=interfaceController
        changes=SharedRuntime.session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        installTemplate()
    }

    private func installTemplate() {
        guard let interface else { return }
        let next=Self.makeTemplate(current:SharedRuntime.session.state)
        template=next;presented=false;lastSnapshot=nil
        interface.setRootTemplate(next,animated:false) { [weak self,weak next] success,error in
            Task { @MainActor [weak self,weak next] in
                guard let self,let next,self.template === next else { return }
                guard success else {
                    self.template=nil
                    NSLog("Hermes CarPlay could not present its template: %@",error?.localizedDescription ?? "unknown error")
                    return
                }
                self.presented=true
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard presented,let template else { return }
        let session=SharedRuntime.session
        let snapshot=CarPlaySnapshot(state:session.state,active:session.active,muted:session.muted)
        // Audio meters publish frequently. Only send actual UI state changes
        // across CarPlay's XPC connection, rather than rebuilding controls per frame.
        guard snapshot != lastSnapshot else { return }
        guard template.voiceControlStates.contains(where:{$0.identifier==snapshot.state.rawValue}) else {
            installTemplate();return
        }
        lastSnapshot=snapshot
        if template.activeStateIdentifier != snapshot.state.rawValue {
            template.activateVoiceControlState(withIdentifier:snapshot.state.rawValue)
        }
        let title=snapshot.active ? (snapshot.muted ? "Unmute":"Mute") : "Start"
        template.leadingNavigationBarButtons=[CPBarButton(title:title) { _ in
            // CarPlay can invoke handlers from its XPC callback queue.
            Task { @MainActor in
                let session=SharedRuntime.session
                if session.active { session.toggleMute() } else { SystemCalls.shared.start() }
            }
        }]
        template.trailingNavigationBarButtons=snapshot.active || snapshot.state == .connecting ? [CPBarButton(title:"End") { _ in
            Task { @MainActor in SystemCalls.shared.end() }
        }] : []
    }

    func templateApplicationScene(_ scene:CPTemplateApplicationScene,didDisconnect interfaceController:CPInterfaceController) {
        changes=nil;template=nil;interface=nil;presented=false;lastSnapshot=nil
        // A display disconnect must not tear down a CallKit call on the phone.
    }
}
