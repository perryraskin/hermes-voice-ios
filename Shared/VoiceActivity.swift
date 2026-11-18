import ActivityKit
import AppIntents
import Foundation

struct VoiceActivityAttributes:ActivityAttributes {
    struct ContentState:Codable,Hashable {
        var phase:String
        var muted:Bool
        var title:String { muted ? "Muted":phase }
        var animatesWave:Bool { !muted && (phase == "Listening" || phase == "Speaking") }
        var symbol:String {
            if muted { return "mic.slash.fill" }
            switch phase {
            case "Connecting":return "network"
            case "Thinking":return "ellipsis"
            case "Speaking":return "waveform"
            default:return "mic.fill"
            }
        }
    }
    var sessionID:String
    var startedAt:Date
    var isCall:Bool
}

struct HermesActivityError:LocalizedError {
    var errorDescription:String? { "That conversation has ended. Open Hermes to start a new one." }
}

struct SetHermesMuteIntent:LiveActivityIntent {
    static var title:LocalizedStringResource="Set Hermes microphone"
    static var isDiscoverable=false
    static var supportedModes:IntentModes { .background }
    @Parameter(title:"Session") var sessionID:String
    @Parameter(title:"Muted") var muted:Bool
    init() {}
    init(sessionID:String,muted:Bool) { self.sessionID=sessionID;self.muted=muted }
    @MainActor func perform() async throws -> IntentResultContainer<Never,Never,Never,Never> {
        #if HERMES_APP
        let session=SharedRuntime.session
        guard session.active,session.activityIdentifier.uuidString==sessionID else { throw HermesActivityError() }
        SystemCalls.shared.setMuted(muted)
        return .result()
        #else
        throw HermesActivityError()
        #endif
    }
}

struct EndHermesSessionIntent:LiveActivityIntent {
    static var title:LocalizedStringResource="End Hermes conversation"
    static var isDiscoverable=false
    static var supportedModes:IntentModes { .background }
    @Parameter(title:"Session") var sessionID:String
    init() {}
    init(sessionID:String) { self.sessionID=sessionID }
    @MainActor func perform() async throws -> IntentResultContainer<Never,Never,Never,Never> {
        #if HERMES_APP
        let session=SharedRuntime.session
        guard (session.active || session.state == .connecting),session.activityIdentifier.uuidString==sessionID else { throw HermesActivityError() }
        SystemCalls.shared.end()
        return .result()
        #else
        throw HermesActivityError()
        #endif
    }
}
