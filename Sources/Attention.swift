import Foundation
import AppIntents
import SwiftUI

enum AttentionAPI {
    static func request(_ path:String,method:String="GET",body:[String:Any]?=nil) async throws -> Data {
        guard let host=UserDefaults.standard.string(forKey:"host"),let base=URL(string:host),base.scheme=="https",base.host?.hasSuffix(".ts.net")==true else { throw URLError(.badURL) }
        var request=URLRequest(url:base.appendingPathComponent(path));request.httpMethod=method;request.timeoutInterval=8;request.setValue("Bearer \(CredentialStore.read())",forHTTPHeaderField:"Authorization")
        if let body { request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await PrivateHTTP.data(for:request)
        guard let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw NSError(domain:"Hermes",code:401,userInfo:[NSLocalizedDescriptionKey:"This device credential was rejected. Reconnect the app in Settings."])
            }
            let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            throw NSError(domain:"Hermes",code:1,userInfo:[NSLocalizedDescriptionKey:value?["error"] as? String ?? "Hermes could not complete that request. Check Tailscale."])
        };return data
    }
    static func registerDevice() async throws { guard let token=UserDefaults.standard.string(forKey:"voipToken"),let environment=UserDefaults.standard.string(forKey:"voipEnvironment") else { return };_ = try await request("v1/devices",method:"POST",body:["token":token,"environment":environment]) }
    static func call(_ id:String,action:String) async throws { _ = try await request("v1/calls/"+id,method:"POST",body:["action":action]) }
}
struct SetDrivingStatusIntent:AppIntent {
    static var title:LocalizedStringResource="Set Hermes Driving Status"
    static var description=IntentDescription("Tell Hermes when Driving Focus or CarPlay connects or disconnects.")
    static var openAppWhenRun=false
    @Parameter(title:"Driving") var driving:Bool
    func perform() async throws -> some IntentResult & ProvidesDialog { _ = try await AttentionAPI.request("v1/driving",method:"POST",body:["active":driving]);return .result(dialog:driving ? "Hermes knows you’re driving.":"Hermes driving status cleared.") }
}
struct HermesShortcuts:AppShortcutsProvider {
    static var appShortcuts:[AppShortcut] { AppShortcut(intent:SetDrivingStatusIntent(),phrases:["Set driving status in \(.applicationName)"],shortTitle:"Driving status",systemImageName:"car") }
}
struct AttentionSettingsView:View {
    @State private var enabled=false
    @State private var driving=false
    @State private var pushReady:Bool?
    @State private var loading=false
    @State private var saving=false
    @State private var testing=false
    @Environment(\.scenePhase) private var scenePhase
    @State private var events:[[String:Any]]=[]
    @State private var message=""
    var body:some View {
        Form {
            Section("Incoming calls") {
                Text("Build " + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")).font(.caption).foregroundStyle(.secondary)
                Toggle("Allow urgent calls while driving",isOn:Binding(get:{enabled},set:{value in Task { await updateEnabled(value) } })).disabled(loading || saving || pushReady == nil)
                LabeledContent("Push connection",value:loading ? "Checking…" : (pushReady == nil ? "Unreachable" : (pushReady == true ? "Ready":"Setup needed")))
                Button(testing ? "Requesting call…":"Test incoming call") { Task { await testCall() } }.disabled(testing || loading || pushReady != true)
                if let host=UserDefaults.standard.string(forKey:"host"),let base=URL(string:host) { Link("Open connection check in Safari",destination:base.appendingPathComponent("health")) }
                Button("Refresh connection",systemImage:"arrow.clockwise") { Task { await load() } }.disabled(loading)
                Text("Only urgent requests needing your decision within 30 minutes may ring. Calls are combined and limited to one offer per issue, with a 10-minute cooldown.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Driving") {
                LabeledContent("Status",value:driving ? "Driving":"Not driving")
                Text("In Shortcuts, create automations for Driving Focus on/off or CarPlay connect/disconnect. Add ‘Set Hermes Driving Status’ with Driving on/off. Status expires after four hours.").font(.footnote)
                Button(driving ? "Clear driving status":"Mark as driving") { Task { do { _ = try await AttentionAPI.request("v1/driving",method:"POST",body:["active":!driving]);await load() } catch { message=error.localizedDescription } } }
            }
            if !message.isEmpty { Section { Text(message).foregroundStyle(.orange) } }
            Section("Attention queue") { if events.isEmpty { Text("Nothing needs your attention.").foregroundStyle(.secondary) };ForEach(events.indices,id:\.self) { i in VStack(alignment:.leading,spacing:6) { Text(events[i]["title"] as? String ?? "Request");Text(events[i]["source"] as? String ?? "").font(.caption).foregroundStyle(.secondary);Text(events[i]["body"] as? String ?? "").font(.footnote).lineLimit(4) } } }
        }.navigationTitle("Calls & attention").task { await load() }.refreshable { await load() }.onChange(of:scenePhase) { _,phase in if phase == .active { Task { await load() } } }
    }
    private func load() async {
        guard !loading else { return };loading=true;defer { loading=false }
        do {
            let data=try await AttentionAPI.request("v1/attention")
            let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            enabled=value["enabled"] as? Bool ?? false;driving=value["driving"] as? Bool ?? false;pushReady=value["push_ready"] as? Bool;events=value["events"] as? [[String:Any]] ?? [];message=""
            // Token upload is independent; a transient registration failure must not hide server status.
            Task { try? await AttentionAPI.registerDevice() }
        } catch { pushReady=nil;message=error.localizedDescription }
    }
    private func updateEnabled(_ value:Bool) async {
        guard !saving else { return };saving=true;defer { saving=false }
        do { _ = try await AttentionAPI.request("v1/attention/preferences",method:"PATCH",body:["enabled":value]);enabled=value;message="" }
        catch { message=error.localizedDescription;pushReady=nil }
    }
    private func testCall() async {
        guard !testing else { return };testing=true;defer { testing=false }
        do {
            let data=try await AttentionAPI.request("v1/calls/test",method:"POST")
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            message=result?["offered"] as? Bool == true ? "Test call requested. Watch for an incoming Hermes call." : "Another call is active. End it before requesting a test."
        } catch { message=error.localizedDescription;pushReady=nil }
    }
}
