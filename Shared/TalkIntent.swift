import AppIntents
import Foundation

struct HermesStartError:LocalizedError {
    let message:String
    var errorDescription:String? { message }
}

/// The Action button, Control Center, Siri and Shortcuts start the same in-app
/// conversation without opening Hermes. Running it again ends the conversation.
/// AudioRecordingIntent lets the microphone start in the background as long as
/// the conversation Live Activity is shown, which VoiceLiveActivity provides.
/// LiveActivityIntent is what lets perform() request that activity from the background.
struct StartHermesConversationIntent:AudioRecordingIntent,LiveActivityIntent {
    static var title:LocalizedStringResource="Talk to Hermes"
    static var description=IntentDescription("Start a Hermes voice conversation without opening the app. Run it again to end the conversation.")
    static var supportedModes:IntentModes { .background }
    init() {}
    @MainActor func perform() async throws -> IntentResultContainer<Never,Never,Never,Never> {
        #if HERMES_APP
        try await SystemCalls.shared.toggleFromIntent()
        return .result()
        #else
        throw HermesStartError(message:"Open Hermes to start a conversation.")
        #endif
    }
}
