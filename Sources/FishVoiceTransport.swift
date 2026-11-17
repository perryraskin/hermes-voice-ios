import Foundation
import LiveKit
import AVFoundation

struct FishSessionToken:Decodable {
    let session_id:String
    let transport:String
    let livekit_url:String
    let token:String
}

@MainActor final class FishVoiceTransport:NSObject,RoomDelegate {
    private lazy var room=Room(delegate:self)
    private weak var session:VoiceSession?
    private let host:URL
    private let credential:String
    private var token:FishSessionToken?
    private var closed=false
    private var meter:Timer?
    private var resultTask:Task<Void,Never>?
    private var deliveredResults=Set<String>()
    private var lastUserSpeech=Date.distantPast
    private var muteChanging=false
    private var connectionReady=false
    private var microphoneStarting=false
    private let audioOwner=UUID()
    private static var currentAudioOwner:UUID?
    private let systemManaged:Bool
    init(session:VoiceSession,host:URL,credential:String) { self.session=session;self.host=host;self.credential=credential;self.systemManaged=session.systemManagedAudio;super.init() }

    func start() async throws {
        Self.currentAudioOwner=audioOwner
        try Self.configureAudio(systemManaged:systemManaged,active:session?.audioActivated == true)
        var request=URLRequest(url:host.appendingPathComponent("v1/fish/sessions"));request.httpMethod="POST";request.timeoutInterval=25;request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization")
        if let call=session?.attentionCallID {
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try JSONSerialization.data(withJSONObject:["call_id":call])
        }
        let (data,response)=try await PrivateHTTP.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain:"Fish",code:1,userInfo:[NSLocalizedDescriptionKey:"Fish could not start. Check the trial configuration or credit."]) }
        let token=try JSONDecoder().decode(FishSessionToken.self,from:data);self.token=token
        guard !closed,token.transport=="livekit",let url=URL(string:token.livekit_url),url.scheme=="wss" else { await closeRemote(token);throw CancellationError() }
        try await room.registerTextStreamHandler(for:"lk.transcription") { [weak self] reader,identity in
            let id=reader.info.attributes["lk.segment_id"] ?? reader.info.id
            var text=""
            for try await chunk in reader {
                text+=chunk
                await self?.transcript(id:id,identity:identity,text:text)
            }
        }
        try await room.connect(url:token.livekit_url,token:token.token)
        guard !closed else { await room.disconnect();return }
        connectionReady=true
        watchResults(token)
        if systemManaged { session?.onReady?() }
        if !systemManaged || session?.audioActivated == true { try activateAudio() }
        meter=Timer.scheduledTimer(withTimeInterval:1.0/20,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self,!self.closed else { return }
                self.session?.level=CGFloat(self.room.localParticipant.audioLevel)
                self.session?.playbackLevel=CGFloat(self.room.remoteParticipants.values.map(\.audioLevel).max() ?? 0)
            }
        }
        for participant in room.remoteParticipants.values { updateState(participant.attributes["lk.agent.state"]) }
    }
    static func configureAudio(systemManaged:Bool,active:Bool) throws {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = !systemManaged
        if systemManaged && active {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,mode:.voiceChat,options:[.allowBluetoothHFP])
        }
        try AudioManager.shared.setEngineAvailability(!systemManaged || active ? .default:.none)
    }
    func activateAudio() throws {
        guard !closed else { return }
        try Self.configureAudio(systemManaged:systemManaged,active:true)
        guard connectionReady,!microphoneStarting else { return };microphoneStarting=true
        Task {
            defer { microphoneStarting=false }
            do {
                try await room.localParticipant.setMicrophone(enabled:session?.muted != true)
                guard !closed else { return };session?.state = .listening
            } catch {
                guard !closed else { return };session?.end();session?.error="The call microphone could not start. Check the audio route."
            }
        }
    }
    func deactivateAudio() {
        guard systemManaged,!closed else { return }
        try? Self.configureAudio(systemManaged:true,active:false)
    }
    private func transcript(id:String,identity:Participant.Identity,text:String) {
        guard !closed else { return }
        if identity==room.localParticipant.identity { lastUserSpeech=Date() }
        session?.receiveFishTranscript(id:id,role:identity==room.localParticipant.identity ? "You":"Hermes",text:text)
    }
    private func updateState(_ state:String?) {
        guard !closed else { return }
        switch state {
        case "speaking":session?.state = .speaking
        case "thinking":session?.state = .thinking
        case "idle","listening":session?.state = .listening
        default:break
        }
    }
    func setMuted(_ value:Bool,completion:((Bool)->Void)?=nil) {
        guard !closed,!muteChanging else { completion?(false);return }
        if systemManaged && session?.audioActivated != true {
            // CallKit has gated the engine off. Save the desired mute state;
            // activation applies it before capture starts, avoiding a hold cycle.
            session?.muted=value;session?.level=0;completion?(true);return
        }
        muteChanging=true
        Task {
            defer { muteChanging=false }
            do { try await room.localParticipant.setMicrophone(enabled:!value);guard !closed else { return };session?.muted=value;session?.level=0;completion?(true) }
            catch { guard !closed else { return };session?.error="The microphone could not be changed.";completion?(false) }
        }
    }
    private struct DeferredResults:Decodable { let pending:Bool;let ready:[String] }
    private func watchResults(_ token:FishSessionToken) {
        resultTask=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
                guard let self,!self.closed else { return }
                do {
                    var request=URLRequest(url:self.host.appendingPathComponent("v1/fish/sessions/\(token.session_id)/results"))
                    request.timeoutInterval=8;request.setValue("Bearer \(self.credential)",forHTTPHeaderField:"Authorization")
                    let (data,response)=try await PrivateHTTP.data(for:request)
                    let status=(response as? HTTPURLResponse)?.statusCode
                    if status==404 || status==410 { return }
                    guard status==200,!self.closed else { continue }
                    let results=try JSONDecoder().decode(DeferredResults.self,from:data)
                    if results.pending || !results.ready.isEmpty {
                        try await self.room.localParticipant.publish(data:Data("{\"type\":\"user.activity\"}".utf8),options:DataPublishOptions(topic:"client-event",reliable:true))
                    }
                    guard self.session?.state == .listening,Date().timeIntervalSince(self.lastUserSpeech)>2 else { continue }
                    if let marker=results.ready.first(where:{!self.deliveredResults.contains($0)}) {
                        self.deliveredResults.insert(marker) // Never replay an uncertain send.
                        let payload=try JSONSerialization.data(withJSONObject:["type":"user.message","text":marker,"audio":true])
                        try await self.room.localParticipant.publish(data:payload,options:DataPublishOptions(topic:"client-event",reliable:true))
                    }
                } catch {
                    guard !Task.isCancelled,!self.closed else { return }
                }
            }
        }
    }
    private func closeRemote(_ token:FishSessionToken) async {
        var request=URLRequest(url:host.appendingPathComponent("v1/fish/sessions/\(token.session_id)/end"));request.httpMethod="POST";request.timeoutInterval=10;request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization")
        _ = try? await PrivateHTTP.data(for:request)
    }
    func end() {
        guard !closed else { return };closed=true;resultTask?.cancel();resultTask=nil;meter?.invalidate();meter=nil
        let token=self.token
        Task {
            try? await room.localParticipant.publish(data:Data("{\"type\":\"user.hangup\"}".utf8),options:DataPublishOptions(topic:"client-event",reliable:true))
            await room.disconnect()
            if Self.currentAudioOwner==audioOwner {
                Self.currentAudioOwner=nil
                if systemManaged { try? AudioManager.shared.setEngineAvailability(.none) }
                AudioManager.shared.audioSession.isAutomaticConfigurationEnabled=true
            }
            if let token { await closeRemote(token) }
        }
    }
    nonisolated func room(_ room:Room,participant:Participant,didUpdateAttributes attributes:[String:String]) {
        Task { @MainActor [weak self] in self?.updateState(attributes["lk.agent.state"]) }
    }
    nonisolated func room(_ room:Room,didDisconnectWithError error:LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self,!closed else { return }
            session?.end();session?.error=error == nil ? "Fish session ended.":"Fish connection interrupted. Check the last request before repeating it."
        }
    }
    nonisolated func room(_ room:Room,participant:RemoteParticipant?,didReceiveData data:Data,forTopic topic:String,encryptionType:EncryptionType) {
        guard topic=="agent-event",let event=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        let kind=event["type"] as? String
        Task { @MainActor [weak self] in
            guard let self,!closed else { return }
            if kind=="session.ended" { session?.end() }
            if kind=="error" { session?.error="Fish reported a voice connection error." }
        }
    }
}
