import ActivityKit
import Combine
import UIKit

@MainActor final class VoiceLiveActivity {
    static let shared=VoiceLiveActivity()
    private weak var session:VoiceSession?
    private var observation:AnyCancellable?
    private var foreground:AnyCancellable?
    private var current:Activity<VoiceActivityAttributes>?
    private var lastState:VoiceActivityAttributes.ContentState?
    private var dismissedSession:String?
    private var work:Task<Void,Never>?

    func observe(_ session:VoiceSession) {
        self.session=session
        // A restarted process cannot restore a live microphone connection.
        let stale=Activity<VoiceActivityAttributes>.activities
        work=Task { for activity in stale { await activity.end(nil,dismissalPolicy:.immediate) } }
        observation=Publishers.CombineLatest(session.$state,session.$muted)
            .sink { [weak self] state,muted in self?.refresh(state:state,muted:muted) }
        foreground=NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self,let session=self.session else { return }
                self.refresh(state:session.state,muted:session.muted)
            }
    }
    private func refresh(state:VoiceState,muted:Bool) {
        guard let session else { return }
        let ongoing=state == .connecting || session.active && state != .ready && state != .failed && state != .paused
        let id=session.activityIdentifier.uuidString
        let content=VoiceActivityAttributes.ContentState(phase:state.rawValue,muted:muted)
        let startedAt=session.activityStartedAt
        let isCall=session.systemManagedAudio
        let previous=work
        work=Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard ongoing else {
                if let current { await current.end(nil,dismissalPolicy:.immediate) }
                self.current=nil;self.lastState=nil;self.dismissedSession=nil
                return
            }
            if let current,current.attributes.sessionID != id {
                await current.end(nil,dismissalPolicy:.immediate);self.current=nil;self.lastState=nil
            }
            if let current,current.activityState == .dismissed || current.activityState == .ended {
                self.dismissedSession=id;self.current=nil;return
            }
            guard self.dismissedSession != id else { return }
            if self.current == nil {
                // A background answer already has CallKit UI. Defer a custom
                // activity until foreground rather than bypassing ActivityKit.
                guard UIApplication.shared.applicationState == .active,ActivityAuthorizationInfo().areActivitiesEnabled else { return }
                do {
                    self.current=try Activity.request(attributes:VoiceActivityAttributes(sessionID:id,startedAt:startedAt,isCall:isCall),content:ActivityContent(state:content,staleDate:nil),pushType:nil)
                    self.lastState=content
                } catch { NSLog("Hermes Live Activity could not start: %@",error.localizedDescription) }
            } else if content != self.lastState,let current=self.current {
                await current.update(ActivityContent(state:content,staleDate:nil));self.lastState=content
            }
        }
    }
}

extension Notification.Name {
    static let hermesRevealSession=Notification.Name("HermesRevealSession")
}
