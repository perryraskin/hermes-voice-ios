import CarPlay
import UIKit
import Combine

@MainActor final class SharedRuntime {
    static let session: VoiceSession = {
        let session=VoiceSession()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--showcase-conversation") { session.showConversationFixture() }
        #endif
        VoiceLiveActivity.shared.observe(session)
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

    static func makeTemplate(current: VoiceState, active: Bool = false, muted: Bool = false) -> CPVoiceControlTemplate {
        // CarPlay discards every state after the first five. Always include the
        // current state first; replace the template for an uncached state.
        var states=[current]
        for state in [VoiceState.ready,.connecting,.listening,.thinking,.speaking,.paused,.failed] where !states.contains(state) {
            states.append(state)
        }
        let template=CPVoiceControlTemplate(voiceControlStates:states.prefix(5).map {
            CPVoiceControlState(identifier:$0.rawValue,titleVariants:[$0.rawValue],image:artwork,repeats:false)
        })
        configureControls(template,snapshot:CarPlaySnapshot(state:current,active:active,muted:muted))
        return template
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
        let session=SharedRuntime.session
        let next=Self.makeTemplate(current:session.state,active:session.active,muted:session.muted)
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
        Self.configureControls(template,snapshot:snapshot)
    }

    static func configureControls(_ template:CPVoiceControlTemplate,snapshot:CarPlaySnapshot) {
        // Include usable controls in the initial XPC payload, before presentation.
        // Navigation buttons also work with rotary controllers and hardware focus.
        let busy=snapshot.active || snapshot.state == .connecting
        let talk=barButton(title:busy ? "End" : "Talk") {
            if busy { SystemCalls.shared.end() } else { SystemCalls.shared.start() }
        }
        talk.buttonStyle = .rounded
        template.trailingNavigationBarButtons=[talk]
        if snapshot.active {
            template.leadingNavigationBarButtons=[barButton(title:snapshot.muted ? "Unmute" : "Mute") {
                SystemCalls.shared.setMuted(!SharedRuntime.session.muted)
            }]
        } else {
            template.leadingNavigationBarButtons=[]
        }
    }

    // The outer callback must itself be nonisolated. A Task inside an
    // actor-inferred callback is too late: Swift can trap before entering it.
    nonisolated static func controlHandler(_ action:@escaping @MainActor @Sendable () -> Void) -> @Sendable (CPBarButton) -> Void {
        { _ in Task { @MainActor in action() } }
    }

    private nonisolated static func barButton(title:String,action:@escaping @MainActor @Sendable () -> Void) -> CPBarButton {
        CPBarButton(title:title,handler:controlHandler(action))
    }

    func templateApplicationScene(_ scene:CPTemplateApplicationScene,didDisconnect interfaceController:CPInterfaceController) {
        changes=nil;template=nil;interface=nil;presented=false;lastSnapshot=nil
        // A display disconnect must not tear down a CallKit call on the phone.
    }
}
