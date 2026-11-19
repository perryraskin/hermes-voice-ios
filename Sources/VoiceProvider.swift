import Foundation

/// Stable provider IDs are persisted and advertised by the private host.
/// Models and voices belong to each provider's host configuration.
enum VoiceProvider:String,CaseIterable,Identifiable {
    case fish="fish_live3" // Preserve the existing preference ID across upgrades.
    case elevenLabs="elevenlabs"
    var id:String { rawValue }
    var name:String { switch self { case .fish:"Fish Audio";case .elevenLabs:"ElevenLabs" } }
    static let preferenceKey="voiceProvider"
    static let preferred:VoiceProvider = .fish

    static func available(in capabilities:[String:Any])->Set<VoiceProvider> {
        if let ids=capabilities["voice_providers"] as? [String] { return Set(ids.compactMap(Self.init(rawValue:))) }
        // Legacy hosts required ElevenLabs to report ready.
        var providers:Set<VoiceProvider>=[.elevenLabs]
        if capabilities["fish_available"] as? Bool == true { providers.insert(.fish) }
        return providers
    }
    static func resolve(preference:String?,available:Set<VoiceProvider>)->VoiceProvider? {
        let requested=preference.flatMap(Self.init(rawValue:)) ?? preferred
        if available.contains(requested) { return requested }
        return allCases.first(where:available.contains)
    }
}


struct FishVoice: Decodable, Identifiable {
    static let preferenceKey = "fishVoiceID"
    static let nameKey = "fishVoiceName"
    let id: String
    let name: String
    let sampleURL: URL?
    let group: String?
}
