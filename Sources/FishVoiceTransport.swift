import Foundation
import LiveKit

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
    private var muteChanging=false
    init(session:VoiceSession,host:URL,credential:String) { self.session=session;self.host=host;self.credential=credential;super.init() }

    func start() async throws {
        var request=URLRequest(url:host.appendingPathComponent("v1/fish/sessions"));request.httpMethod="POST";request.timeoutInterval=25;request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization")
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
        try await room.localParticipant.setMicrophone(enabled:true)
        session?.state = .listening
        meter=Timer.scheduledTimer(withTimeInterval:1.0/20,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self,!self.closed else { return }
                self.session?.level=CGFloat(self.room.localParticipant.audioLevel)
                self.session?.playbackLevel=CGFloat(self.room.remoteParticipants.values.map(\.audioLevel).max() ?? 0)
            }
        }
        for participant in room.remoteParticipants.values { updateState(participant.attributes["lk.agent.state"]) }
    }
    private func transcript(id:String,identity:Participant.Identity,text:String) {
        guard !closed else { return }
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
    func setMuted(_ value:Bool) {
        guard !closed,!muteChanging else { return };muteChanging=true
        Task {
            defer { muteChanging=false }
            do { try await room.localParticipant.setMicrophone(enabled:!value);guard !closed else { return };session?.muted=value;session?.level=0 }
            catch { guard !closed else { return };session?.error="The microphone could not be changed." }
        }
    }
    private func closeRemote(_ token:FishSessionToken) async {
        var request=URLRequest(url:host.appendingPathComponent("v1/fish/sessions/\(token.session_id)/end"));request.httpMethod="POST";request.timeoutInterval=10;request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization")
        _ = try? await PrivateHTTP.data(for:request)
    }
    func end() {
        guard !closed else { return };closed=true;meter?.invalidate();meter=nil
        let token=self.token
        Task {
            try? await room.localParticipant.publish(data:Data("{\"type\":\"user.hangup\"}".utf8),options:DataPublishOptions(topic:"client-event",reliable:true))
            await room.disconnect()
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
