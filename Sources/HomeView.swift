import AVFoundation
import SwiftUI

private let sage = Color(red:0.79,green:0.91,blue:0.74)
private let surface = Color(red:0.063,green:0.078,blue:0.071)
struct HomeView: View {
    @EnvironmentObject var session: VoiceSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings=false
    @State private var transcript=false
    @ScaledMetric(relativeTo:.title) private var headingSize=27
    @ScaledMetric(relativeTo:.largeTitle) private var stateSize=34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var engaged: Bool { session.active || session.state == .connecting }
    private var statusSymbol: String { session.muted ? "mic.slash.fill" : (session.state == .speaking ? "speaker.wave.2.fill" : "mic.fill") }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing:0) {
                    header
                    Spacer(minLength:30)
                    VoiceWave(state:session.state,muted:session.muted,input:session.level,output:session.playbackLevel)
                        .padding(.top,28)
                    VStack(spacing:12) {
                        Text(session.label).font(.system(size:stateSize,weight:.medium,design:.rounded)).tracking(-0.7)
                            .contentTransition(.opacity)
                        Text(session.hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(.top,14).frame(maxWidth:.infinity)
                    Spacer(minLength:35)
                    transcriptPreview.padding(.top,20)
                    if !session.error.isEmpty {
                        Label(session.error,systemImage:"exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading)
                            .padding(16).background(.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:16))
                            .padding(.top,16)
                    }
                    Spacer(minLength:20)
                }.padding(.horizontal,26).padding(.top,8).frame(minHeight:geometry.size.height)
            }.scrollIndicators(.hidden)
        }
        .background(surface)
        .safeAreaInset(edge:.bottom,spacing:0) { controls.padding(.top,16).padding(.bottom,16).frame(maxWidth:.infinity).background(surface) }
        .tint(sage)
        .animation(reduceMotion ? nil:.easeInOut(duration:0.25),value:session.state)
        .animation(reduceMotion ? nil:.easeInOut(duration:0.2),value:session.muted)
        .sensoryFeedback(.selection,trigger:session.muted)
        .task { await session.testConnectionOnLaunch() }
        // CallKit and this screen use SharedRuntime.session. Returning to the app
        // reveals that session without starting a new connection or stopping audio.
        .onChange(of:engaged) { _,ongoing in
            if ongoing { revealOngoingCall() }
        }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active && engaged { revealOngoingCall() }
        }
        .onReceive(NotificationCenter.default.publisher(for:.hermesRevealSession)) { _ in revealOngoingCall() }
        .sheet(isPresented:$settings) { SettingsView() }
        .sheet(isPresented:$transcript) { TranscriptView().environmentObject(session) }
    }
    private func revealOngoingCall() {
        settings=false
        transcript=false
    }
    private var header: some View {
        HStack(alignment:.center) {
            VStack(alignment:.leading,spacing:8) {
                Text("Hermes").font(.system(size:headingSize,weight:.semibold)).tracking(-0.7)
                HStack(spacing:6) {
                    Circle().fill(session.connected ? sage:.gray).frame(width:5,height:5)
                    Text(session.checkingConnection ? "Checking connection…" : session.connected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { settings=true } label:{ Image(systemName:"slider.horizontal.3").font(.system(size:18,weight:.medium)).foregroundStyle(.secondary).frame(width:46,height:46).background(.white.opacity(0.045),in:Circle()) }
                .buttonStyle(VoiceButtonStyle()).accessibilityLabel("Settings")
        }
    }
    private var transcriptPreview: some View {
        Button { transcript=true } label:{
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Label(session.entries.isEmpty ? "CONVERSATION":(session.entries.last?.role.uppercased() ?? "CONVERSATION"),systemImage:session.entries.last?.role == "Hermes" ? "waveform":"text.bubble")
                        .font(.system(.caption2,design:.rounded,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
                if let entry=session.entries.last {
                    Text(entry.text).font(.system(.title3,design:.rounded)).foregroundStyle(.primary).lineSpacing(4).lineLimit(5).frame(maxWidth:.infinity,alignment:.leading)
                } else {
                    Text("A little space to think out loud.").font(.body).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
                .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:22))
                .overlay(RoundedRectangle(cornerRadius:22).strokeBorder(.white.opacity(0.055),lineWidth:1))
        }.buttonStyle(.plain).accessibilityLabel("Conversation transcript").accessibilityValue(session.entries.last?.text ?? "No conversation yet")
    }
    private var controls: some View {
        HStack(alignment:.center,spacing:32) {
            if engaged {
                control(session.muted ? "Unmute":"Mute",symbol:session.muted ? "mic.slash.fill":"mic.fill",primary:false) { session.toggleMute() }.disabled(!session.active)
                control(session.state == .connecting ? "Cancel":"End",symbol:"stop.fill",primary:true) { SystemCalls.shared.end() }
            } else {
                control(session.state == .paused ? "Resume":"Start",symbol:"mic.fill",primary:true) {
                    if session.host.isEmpty { settings=true } else { SystemCalls.shared.start() }
                }
            }
        }
    }
    private func control(_ title:String,symbol:String,primary:Bool,action:@escaping()->Void)->some View {
        VStack(spacing:10) {
            Button(action:action) {
                Image(systemName:symbol).font(.system(size:primary ? 25:20,weight:.medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width:primary ? 76:60,height:primary ? 76:60)
                    .foregroundStyle(primary ? surface:(session.muted ? sage:Color.white.opacity(0.8)))
                    .background(primary ? sage:(session.muted ? sage.opacity(0.14):.white.opacity(0.065)),in:Circle())
                    .overlay(Circle().strokeBorder(primary ? Color.clear:.white.opacity(0.07),lineWidth:1))
            }.buttonStyle(VoiceButtonStyle()).accessibilityLabel(title)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct TranscriptView: View {
    @EnvironmentObject var session:VoiceSession
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:24) {
                        ForEach(session.entries) { entry in
                            VStack(alignment:.leading,spacing:8) {
                                Text(entry.role.uppercased()).font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(entry.role == "Hermes" ? sage:.gray)
                                Text(entry.text).font(.body).lineSpacing(5).textSelection(.enabled)
                            }.frame(maxWidth:.infinity,alignment:.leading).id(entry.id)
                        }
                    }.padding(24)
                }.overlay { if session.entries.isEmpty { ContentUnavailableView("No conversation yet",systemImage:"waveform",description:Text("Start a conversation to see its transcript.")) } }
            }.background(surface).navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }.presentationDragIndicator(.visible)
    }
}
struct SettingsView: View {
    @AppStorage(FishVoice.nameKey) private var fishVoiceName = ""
    @AppStorage(VoiceProvider.preferenceKey) private var voiceProvider=VoiceProvider.preferred.rawValue
    @EnvironmentObject var session:VoiceSession
    @Environment(\.dismiss) var dismiss
    var body:some View { NavigationStack { Form {
        Section("Private connection") { if !session.error.isEmpty { Text(session.error).font(.footnote).foregroundStyle(.orange) }; TextField("https://your-host.tailnet.ts.net:port",text:$session.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityLabel("Private host URL"); SecureField("Device credential",text:$session.token).accessibilityLabel("Device credential"); Button("Test connection") { session.save(); Task { await session.testConnection() } }; Label(session.connected ? "Connected to Hermes Voice":"Not connected",systemImage:session.connected ? "checkmark.circle":"network") }
        Section { NavigationLink("Calls & attention") { AttentionSettingsView() } }
        Section("Voice") { Picker("Voice engine",selection:$voiceProvider) { ForEach(VoiceProvider.allCases) { provider in Text(provider.name).tag(provider.rawValue) } }.disabled(session.active); if voiceProvider == VoiceProvider.fish.rawValue {
            NavigationLink { FishVoicePicker() } label: {
                LabeledContent("Fish Audio voice", value: fishVoiceName.isEmpty ? "Agent default" : fishVoiceName)
            }.disabled(session.active)
        }; Text("Voice settings apply to new manual conversations and incoming Hermes calls.").font(.footnote).foregroundStyle(.secondary) }
        Section("Privacy") { Text("Tailscale connects to your private host. ElevenLabs conversations relay speech through the host; Fish Audio streams speech directly to Fish using short-lived WebRTC credentials. Hermes supplies replies through a dedicated authenticated callback. Fish audio recording is disabled. This app keeps the current transcript in memory.").font(.footnote) }
        if !session.error.isEmpty { Section("Connection details") { Text(session.error).foregroundStyle(.orange) } }
        Section { Button("Forget this device",role:.destructive) { session.end(); session.token=""; session.host=""; try? CredentialStore.save(""); UserDefaults.standard.removeObject(forKey:"host"); session.connected=false } }
    }.navigationTitle("Settings").toolbar { Button("Done") { if session.host.isEmpty && session.token.isEmpty { session.error=""; dismiss() } else { session.save(); if session.error.isEmpty { dismiss() } } } } } }
}

private struct FishVoicePicker: View {
    @EnvironmentObject private var session: VoiceSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FishVoice.preferenceKey) private var selection = ""
    @AppStorage(FishVoice.nameKey) private var selectedName = ""
    @State private var query = ""
    @State private var voices: [FishVoice] = []
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0
    @State private var player = AVPlayer()
    @State private var previewingID: String?
    @State private var previewError = false
    @State private var previewStatus: NSKeyValueObservation?
    @State private var previewReady = false
    @State private var previewAudioActive = false

    var body: some View {
        List {
            choice(id: "", name: "Agent default")
            if !selection.isEmpty && !voices.contains(where: { $0.id == selection }) {
                choice(id: selection, name: selectedName)
            }
            if previewError {
                Text("Couldn’t play the voice sample. Try again.").foregroundStyle(.secondary)
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(voiceGroups, id: \.self) { group in
                    Section(group) {
                        ForEach(voices.filter { ($0.group ?? "Voices") == group }) { voice in
                            voiceRow(voice)
                        }
                    }
                }
            } else if !voices.isEmpty {
                Section("Search results") {
                    ForEach(voices) { voice in voiceRow(voice) }
                }
            }
            if loading {
                ProgressView("Loading voices")
            } else if failed {
                Button("Couldn’t load voices. Retry") { retry += 1 }
            } else if voices.isEmpty {
                Text("No voices found").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fish Audio voice")
        .searchable(text: $query, prompt: "Search Fish Audio voices")
        .onDisappear { stopPreview() }
        .onChange(of: session.active) { _, active in
            if active { stopPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player.currentItem { stopPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player.currentItem {
                stopPreview()
                previewError = true
            }
        }
        .task(id: [query, String(retry), session.host, session.token]) {
            stopPreview()
            previewError = false
            loading = true
            failed = false
            voices = []
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await session.loadFishVoices(matching: query)
                try Task.checkCancellation()
                voices = result
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                loading = false
            }
        }
    }

    private var voiceGroups: [String] {
        voices.reduce(into: []) { groups, voice in
            let group = voice.group ?? "Voices"
            if !groups.contains(group) { groups.append(group) }
        }
    }

    private func voiceRow(_ voice: FishVoice) -> some View {
        HStack {
            choice(id: voice.id, name: voice.name)
            if let url = voice.sampleURL {
                Button {
                    togglePreview(id: voice.id, url: url)
                } label: {
                    Group {
                        if previewingID == voice.id && !previewReady {
                            ProgressView()
                        } else {
                            Image(systemName: previewingID == voice.id ? "stop.circle.fill" : "play.circle")
                                .font(.title2)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(previewingID == voice.id ? "Stop sample" : "Play sample for \(voice.name)")
                .disabled(session.active)
            }
        }
    }

    private func togglePreview(id: String, url: URL) {
        let wasPlaying = previewingID == id
        stopPreview()
        previewError = false
        guard !wasPlaying, !session.active else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            previewAudioActive = true
        } catch {
            previewError = true
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        previewingID = id
        previewStatus = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Task { @MainActor in
                guard item === player.currentItem else { return }
                switch item.status {
                case .readyToPlay: previewReady = true
                case .failed:
                    stopPreview()
                    previewError = true
                default: break
                }
            }
        }
        player.play()
    }

    private func stopPreview() {
        previewStatus = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        previewingID = nil
        previewReady = false
        if previewAudioActive {
            previewAudioActive = false
            if !session.active {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func choice(id: String, name: String) -> some View {
        Button {
            selection = id
            selectedName = id.isEmpty ? "" : name
            dismiss()
        } label: {
            HStack {
                Text(name)
                Spacer()
                if selection == id { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
        .disabled(session.active)
    }
}
