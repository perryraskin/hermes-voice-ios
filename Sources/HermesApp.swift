import SwiftUI
import AVFoundation
import Security

@main struct HermesApp: App {
    @UIApplicationDelegateAdaptor(HermesAppDelegate.self) private var appDelegate
    @StateObject private var session = SharedRuntime.session
    var body: some Scene { WindowGroup { HomeView().environmentObject(session).onOpenURL { url in Task { await session.pair(url) } }.preferredColorScheme(.dark) } }
}

enum VoiceState: String, CaseIterable { case ready = "Ready", connecting = "Connecting", listening = "Listening", thinking = "Thinking", speaking = "Speaking", paused = "Paused", failed = "Unavailable"
    var hint: String { switch self { case .ready: "Start a conversation."; case .connecting: "Connecting to Hermes…"; case .listening: "Take your time. I’m here."; case .thinking: "Working on that."; case .speaking: "You can interrupt me."; case .paused: "Resume when you’re ready."; case .failed: "Check your private connection." } }
}
struct TranscriptEntry: Identifiable { let id = UUID(); let role: String; var text: String }
struct WireEvent: Decodable { let type: String; let text: String?; let audio: String?; let turn: String? }

enum CredentialStore {
    static let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.perryraskin.hermes.voice", kSecAttrAccount as String:"device"]
    static func read() -> String { var q = query; q[kSecReturnData as String] = true; var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }; return String(data:data, encoding:.utf8) ?? "" }
    static func save(_ value: String) throws { SecItemDelete(query as CFDictionary); guard !value.isEmpty else { return }; var q = query; q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; let status = SecItemAdd(q as CFDictionary,nil); if status != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) } }
}

@MainActor final class VoiceSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var state: VoiceState = .ready
    @Published var muted = false
    @Published var connected = false
    @Published var error = ""
    @Published var entries: [TranscriptEntry] = []
    @Published var level: CGFloat = 0
    @Published var playbackLevel: CGFloat = 0
    private var meterTimer: Timer?
    @Published var host = UserDefaults.standard.string(forKey:"host") ?? ""
    @Published var token = CredentialStore.read()
    private var socket: URLSessionWebSocketTask?
    var systemManagedAudio=false
    var audioActivated=true
    var attentionCallID:String?
    var onReady:(()->Void)?
    var onEnded:(()->Void)?
    private var recognitionReady=false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayer?
    private var pcmPlayer: AVAudioPlayerNode?
    private var pcmQueue: [Data] = []
    private var pcmPending = 0
    private var pcmRemainder = Data()
    private var playbackGeneration = UUID()
    private let pcmFormat=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!
    private var audioQueue: [Data] = []
    private var voiceFrames = 0
    private var generation = UUID()
    private var receiveTask: Task<Void,Never>?
    private var turn: String?
    private var pendingSends = 0
    private var starting = false
    #if DEBUG
    private var showcaseActive = false
    #endif
    private var observer: NSObjectProtocol?
    private var engineObserver: NSObjectProtocol?
    var active: Bool {
        #if DEBUG
        if showcaseActive { return true }
        #endif
        return socket != nil
    }
    var label: String { muted && active ? "Muted" : state.rawValue }
    var hint: String { muted && active ? "Your microphone is paused." : state.hint }
    override init() { super.init(); observer = NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in if self?.systemManagedAudio != true { self?.pause() } } } }
    #if DEBUG
    func showConversationFixture() {
        // Synthetic README data in the actual views; no socket, recording or providers.
        showcaseActive=true;connected=true;state = .listening;level=0.38
        entries=[.init(role:"You",text:"What needs my attention?"),
                 .init(role:"Hermes",text:"The preview is ready. Would you like the shorter version?"),
                 .init(role:"You",text:"Yes, keep it brief."),
                 .init(role:"Hermes",text:"The new layout is simpler, and the main controls are easier to reach.")]
    }
    #endif
    func pair(_ url: URL) async {
        guard url.scheme == "hermesvoice", url.host == "pair", let parts=URLComponents(url:url,resolvingAgainstBaseURL:false), let code=parts.queryItems?.first(where:{$0.name=="code"})?.value, code.count >= 32 else { return }
        do {
            let configured=Bundle.main.object(forInfoDictionaryKey:"HermesPrivateHost") as? String ?? ""
            let pairingHost=host.isEmpty ? configured : host
            guard let base=URL(string:pairingHost),base.scheme=="https",base.host?.hasSuffix(".ts.net")==true,base.user==nil,base.password==nil,base.query==nil,base.fragment==nil else { throw NSError(domain:"Pairing",code:2,userInfo:[NSLocalizedDescriptionKey:"Enter your private host in Settings before opening the pairing link."]) }
            let endpoint=base.appendingPathComponent("v1/pair")
            var request=URLRequest(url:endpoint); request.httpMethod="POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody=try JSONSerialization.data(withJSONObject:["code":code]); request.timeoutInterval=15
            let (data,response)=try await PrivateHTTP.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let value=try JSONSerialization.jsonObject(with:data) as? [String:String],let credential=value["token"] else { throw NSError(domain:"Pairing",code:1,userInfo:[NSLocalizedDescriptionKey:"Pairing link expired or already used. Generate a new link on your Mac."]) }
            try CredentialStore.save(credential); token=credential;host=pairingHost;UserDefaults.standard.set(host,forKey:"host");await testConnection();try? await AttentionAPI.registerDevice()
        } catch { self.error=error.localizedDescription }
    }
    func save() { do { _ = try baseURL(); try CredentialStore.save(token); UserDefaults.standard.set(host,forKey:"host"); error = "" } catch { self.error = error.localizedDescription } }
    func baseURL() throws -> URL { guard let u = URL(string:host), u.scheme == "https", u.host?.hasSuffix(".ts.net") == true, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { throw NSError(domain:"Hermes",code:1,userInfo:[NSLocalizedDescriptionKey:"Enter your private HTTPS Tailscale host (.ts.net)."])}; return u }
    func testConnection() async { do { var r = URLRequest(url:try baseURL().appendingPathComponent("v1/capabilities")); r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization"); r.timeoutInterval = 10; let (data,response) = try await PrivateHTTP.data(for:r); guard (response as? HTTPURLResponse)?.statusCode == 200, let cap = try JSONSerialization.jsonObject(with:data) as? [String:Any], cap["profile"] as? String == "voice", cap["ready"] as? Bool == true else { throw NSError(domain:"Hermes",code:2,userInfo:[NSLocalizedDescriptionKey:"The voice service is not ready or this device is not authorized."])}; connected = true; error = "" } catch { connected = false; self.error = error.localizedDescription } }
    func start() async {
        guard !active, !starting else { return }; starting=true; defer { starting=false }; let attempt=generation; save(); guard error.isEmpty else { return }
        state = .connecting; await testConnection(); guard generation == attempt else { return }; guard connected else { state = .failed; return }
        guard await AVAudioApplication.requestRecordPermission() else { error = "Allow microphone access in iPhone Settings."; state = .failed; return }
        guard generation == attempt else { return }
        do { var u = URLComponents(url:try baseURL().appendingPathComponent("v1/stream"),resolvingAgainstBaseURL:false)!; u.scheme = "wss"; u.queryItems=[URLQueryItem(name:"audio",value:"pcm_24000")]; if let attentionCallID { u.queryItems?.append(URLQueryItem(name:"call_id",value:attentionCallID)) }; var r = URLRequest(url:u.url!); r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization"); let ws = URLSession.shared.webSocketTask(with:r); socket = ws; ws.resume(); generation = UUID(); let epoch = generation; entries = []; muted = false
            receiveTask = Task { do { while !Task.isCancelled { let msg = try await ws.receive(); guard self.generation == epoch else { return }; if case .string(let str) = msg { try self.handle(JSONDecoder().decode(WireEvent.self,from:Data(str.utf8))) } } } catch { guard self.generation == epoch else { return }; self.end(); self.connected=false; self.state = .failed; self.error = "Connection interrupted. Check your last request before trying again." } }
        } catch { end(); state = .failed; self.error = error.localizedDescription }
    }
    func handle(_ e: WireEvent) throws { guard active else { return }; switch e.type {
    case "ready": recognitionReady=true;onReady?();try beginCaptureIfReady()
    case "context": turn=e.turn;state = .thinking
    case "partial": if let t=e.text { if entries.last?.role == "You" && state == .listening { entries[entries.count-1].text=t } else { entries.append(.init(role:"You",text:t)) } }
    case "committed": turn=e.turn; state = .thinking; if let t=e.text { if entries.last?.role == "You" { entries[entries.count-1].text=t } else { entries.append(.init(role:"You",text:t)) } }
    case "text": guard e.turn == turn else { return }; if entries.last?.role == "Hermes" { entries[entries.count-1].text += " " + (e.text ?? "") } else { entries.append(.init(role:"Hermes",text:e.text ?? "")) }
    case "text_delta": guard e.turn == turn else { return };if entries.last?.role == "Hermes" { entries[entries.count-1].text += e.text ?? "" } else { entries.append(.init(role:"Hermes",text:e.text ?? "")) }
    case "audio": guard e.turn == turn, let s=e.audio,let d=Data(base64Encoded:s) else { return }; audioQueue.append(d); try playNext()
    case "pcm_audio": guard e.turn == turn,let s=e.audio,let d=Data(base64Encoded:s),!d.isEmpty else { return };pcmRemainder.append(d);let count=pcmRemainder.count & ~1;if count > 0 { pcmQueue.append(Data(pcmRemainder.prefix(count)));pcmRemainder.removeFirst(count);playPCM() }
    case "interrupted": stopPlayback(); turn=nil; state = .listening
    case "done": if state != .speaking { state = .listening }
    case "error": error=e.text ?? "Voice is unavailable."; state = .listening
    default: break
    } }
    func beginCaptureIfReady() throws {
        guard recognitionReady,(!systemManagedAudio || audioActivated) else { return }
        if let engine { try engine.start() } else { try capture() }
        if pcmPending == 0 { state = .listening };playPCM()
    }
    func suspendSystemAudio() { audioActivated=false;engine?.stop();player?.pause();pcmPlayer?.pause() }
    func capture() throws {
        let audio = AVAudioSession.sharedInstance(); try audio.setCategory(.playAndRecord,mode:.voiceChat,options:[.defaultToSpeaker,.allowBluetoothHFP]); if !systemManagedAudio { try audio.setActive(true) }
        let engine=AVAudioEngine(); self.engine=engine; try engine.inputNode.setVoiceProcessingEnabled(true)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.active,self.engine === engine,(!self.systemManagedAudio || self.audioActivated) else { return }
                do { try engine.start();self.playPCM() } catch { self.error="Audio route changed. End and restart the conversation." }
            }
        }
        let epoch = generation
        let output=AVAudioPlayerNode();pcmPlayer=output;engine.attach(output);engine.connect(output,to:engine.mainMixerNode,format:pcmFormat)
        output.installTap(onBus:0,bufferSize:1024,format:pcmFormat) { [weak self] buffer,_ in
            guard let samples=buffer.floatChannelData?[0],buffer.frameLength>0 else { return }
            let count=Int(buffer.frameLength)
            let energy=(0..<count).reduce(0.0) { $0+Double(samples[$1]*samples[$1]) }
            let amplitude=CGFloat(min(1,sqrt(energy/Double(count))*5))
            Task { @MainActor in guard let self,self.active,self.generation == epoch else { return };self.playbackLevel=amplitude }
        }
        let format=engine.inputNode.outputFormat(forBus:0)
        let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
        guard let converter=AVAudioConverter(from:format,to:target) else { throw NSError(domain:"Audio",code:1) }
        engine.inputNode.installTap(onBus:0,bufferSize:2048,format:format) { [weak self] buffer,_ in
            let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(Double(buffer.frameLength)*16000/format.sampleRate)+32)!
            var fed=false; var err:NSError?
            converter.convert(to:output,error:&err) { _,status in if fed { status.pointee = .noDataNow; return nil }; fed=true; status.pointee = .haveData; return buffer }
            guard err == nil, let bytes=output.int16ChannelData?[0] else { return }; let data=Data(bytes:bytes,count:Int(output.frameLength)*2)
            let count=Int(output.frameLength); let rms=count > 0 ? sqrt((0..<count).reduce(0.0){$0+pow(Double(bytes[$1])/32768,2)}/Double(count)) : 0
            Task { @MainActor in guard let self, self.active, self.generation == epoch, !self.muted else { return }; if self.state == .speaking { self.voiceFrames = rms > 0.025 ? self.voiceFrames+1 : 0; if self.voiceFrames >= 3 { self.stopPlayback(); self.turn=nil; self.state = .listening; self.send(["type":"interrupt"]); self.voiceFrames=0 } }; self.level = self.level * 0.3 + CGFloat(min(1,pow(rms*12,0.65))) * 0.7; self.send(["type":"audio","audio":data.base64EncodedString()]) }
        }; try engine.start()
    }
    func send(_ value:[String:String]) { guard let socket,let data=try? JSONSerialization.data(withJSONObject:value),let str=String(data:data,encoding:.utf8) else { return }; guard pendingSends < 8 || value["type"] != "audio" else { return }; pendingSends += 1; let epoch = generation; socket.send(.string(str)) { [weak self] _ in Task { @MainActor in guard let self, self.generation == epoch else { return }; self.pendingSends = max(0,self.pendingSends-1) } } }
    func toggleMute() { SystemCalls.shared.setMuted(!muted) }
    func setMuted(_ value:Bool) { muted=value;level=0;send(["type":muted ? "mute":"unmute"]) }
    func pause() { guard active else { return }; end(); state = .paused }
    func end() {
        #if DEBUG
        showcaseActive=false
        #endif
        generation=UUID(); pendingSends=0; turn=nil; receiveTask?.cancel(); receiveTask=nil; socket?.cancel(with:.normalClosure,reason:nil); socket=nil; if let engineObserver { NotificationCenter.default.removeObserver(engineObserver);self.engineObserver=nil };stopPlayback();pcmPlayer=nil; engine?.stop(); engine?.inputNode.removeTap(onBus:0); engine=nil; player?.stop(); player=nil; stopMetering(); audioQueue=[]; voiceFrames=0; level=0; muted=false; state = .ready; recognitionReady=false;attentionCallID=nil;if !systemManagedAudio { try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation) };onEnded?();systemManagedAudio=false;audioActivated=true }
    func stopPlayback() {
        playbackGeneration=UUID();pcmPending=0;pcmQueue=[];pcmRemainder=Data();pcmPlayer?.stop()
        player?.stop();player=nil;audioQueue=[];stopMetering()
    }
    func playPCM() {
        guard active,let node=pcmPlayer,let engine,(!systemManagedAudio || audioActivated) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { self.error="Audio playback could not start. Check the selected audio route.";return }
        }
        let epoch=playbackGeneration
        for data in pcmQueue {
            let frames=data.count/2
            guard let buffer=AVAudioPCMBuffer(pcmFormat:pcmFormat,frameCapacity:AVAudioFrameCount(frames)),let output=buffer.floatChannelData?[0] else { continue }
            buffer.frameLength=AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                for index in 0..<frames {
                    let sample=Float(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:index*2,as:Int16.self)))/32768
                    output[index]=sample
                }
            }
            pcmPending += 1
            node.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self,self.playbackGeneration == epoch,self.active else { return }
                    self.pcmPending=max(0,self.pcmPending-1)
                    if self.pcmPending == 0 { self.playbackLevel=0;self.state = .listening }
                }
            }
        }
        pcmQueue=[]
        if pcmPending > 0 { node.play();state = .speaking }
    }
    func playNext() throws { guard player == nil, !audioQueue.isEmpty, active else { return }; player = try AVAudioPlayer(data:audioQueue.removeFirst()); player?.delegate=self; player?.isMeteringEnabled=true; player?.play(); state = .speaking; startMetering() }
    func startMetering() {
        meterTimer?.invalidate()
        meterTimer=Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player=self.player, player.isPlaying else { return }
                player.updateMeters()
                let power=Double(player.averagePower(forChannel:0))
                let normalized=CGFloat(min(1,pow(10,power/40)*1.6))
                self.playbackLevel=self.playbackLevel*0.35+normalized*0.65
            }
        }
    }
    func stopMetering() { meterTimer?.invalidate(); meterTimer=nil; playbackLevel=0 }
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) { Task { @MainActor in if self.active { self.player=nil; self.stopMetering(); do { try self.playNext() } catch { self.error="Voice playback failed." }; if self.player == nil { self.state = .listening } } } }
}
