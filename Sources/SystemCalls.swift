import CallKit
import PushKit
import UIKit
import AVFoundation

@MainActor final class SystemCalls:NSObject,CXProviderDelegate,PKPushRegistryDelegate {
    static let shared=SystemCalls()
    private let provider:CXProvider
    private let controller=CXCallController()
    private var registry:PKPushRegistry?
    private var callID:UUID?
    private var incomingID:String?
    private var answerAction:CXAnswerCallAction?
    private var startupTimer:Timer?
    override private init() {
        let config=CXProviderConfiguration();config.supportsVideo=false;config.maximumCallsPerCallGroup=1;config.supportedHandleTypes=[.generic];config.includesCallsInRecents=false
        provider=CXProvider(configuration:config);super.init();provider.setDelegate(self,queue:.main)
        let session=SharedRuntime.session
        session.onReady={ [weak self] in self?.connectionReady() }
        session.onEnded={ [weak self] in self?.sessionEnded() }
    }
    func registerPushes() {
        #if !targetEnvironment(simulator)
        if registry==nil { let r=PKPushRegistry(queue:.main);r.delegate=self;r.desiredPushTypes=[.voIP];registry=r }
        #endif
    }
    func start() {
        #if targetEnvironment(simulator)
        Task { await SharedRuntime.session.start() }
        #else
        guard callID==nil else { return }
        let id=UUID();callID=id;SharedRuntime.session.state = .connecting;let action=CXStartCallAction(call:id,handle:CXHandle(type:.generic,value:"Hermes"));action.isVideo=false
        controller.request(CXTransaction(action:action)) { error in
            if let error { Task { @MainActor in self.callID=nil;SharedRuntime.session.state = .failed;SharedRuntime.session.error=error.localizedDescription } }
        }
        #endif
    }
    func end() {
        guard let id=callID else { SharedRuntime.session.end();return }
        controller.request(CXTransaction(action:CXEndCallAction(call:id))) { [weak self] error in
            if error != nil { Task { @MainActor in self?.sessionEnded();SharedRuntime.session.end() } }
        }
    }
    func setMuted(_ muted:Bool) {
        guard let id=callID else { SharedRuntime.session.setMuted(muted);return }
        controller.request(CXTransaction(action:CXSetMutedCallAction(call:id,muted:muted))) { _ in }
    }
    func provider(_ provider:CXProvider,perform action:CXStartCallAction) {
        guard callID==action.callUUID else { action.fail();return };callID=action.callUUID
        SharedRuntime.session.systemManagedAudio=true;SharedRuntime.session.audioActivated=false
        provider.reportOutgoingCall(with:action.callUUID,startedConnectingAt:Date());action.fulfill()
        beginConnection()
    }
    private func beginConnection() {
        startupTimer?.invalidate();startupTimer=Timer.scheduledTimer(withTimeInterval:25,repeats:false) { [weak self] _ in Task { @MainActor in self?.answerAction?.fail();self?.answerAction=nil;SharedRuntime.session.end();SharedRuntime.session.error="The call could not connect. Check Tailscale and try again." } }
        Task { await SharedRuntime.session.start();if SharedRuntime.session.state == .failed { self.sessionEnded() } }
    }
    func provider(_ provider:CXProvider,perform action:CXAnswerCallAction) {
        guard action.callUUID==callID else { action.fail();return };answerAction=action
        SharedRuntime.session.systemManagedAudio=true;SharedRuntime.session.audioActivated=false;SharedRuntime.session.attentionCallID=incomingID
        beginConnection()
    }
    private func connectionReady() {
        startupTimer?.invalidate();startupTimer=nil
        if let action=answerAction { action.fulfill();answerAction=nil;if let incomingID { Task { try? await AttentionAPI.call(incomingID,action:"answered") } } }
        else if let callID { provider.reportOutgoingCall(with:callID,connectedAt:Date()) }
    }
    func provider(_ provider:CXProvider,perform action:CXEndCallAction) {
        guard action.callUUID==callID else { action.fail();return }
        let incoming=incomingID;let answered=SharedRuntime.session.active
        callID=nil;incomingID=nil;answerAction?.fail();answerAction=nil;startupTimer?.invalidate();startupTimer=nil
        SharedRuntime.session.end();action.fulfill()
        if let incoming { Task { try? await AttentionAPI.call(incoming,action:answered ? "ended":"declined") } }
    }
    func provider(_ provider:CXProvider,perform action:CXSetMutedCallAction) { SharedRuntime.session.setMuted(action.isMuted);action.fulfill() }
    func provider(_ provider:CXProvider,perform action:CXSetHeldCallAction) { SharedRuntime.session.setMuted(action.isOnHold);action.fulfill() }
    func provider(_ provider:CXProvider,didActivate audioSession:AVAudioSession) { SharedRuntime.session.audioActivated=true;do { try SharedRuntime.session.beginCaptureIfReady() } catch { SharedRuntime.session.error=error.localizedDescription;SharedRuntime.session.end() } }
    func provider(_ provider:CXProvider,didDeactivate audioSession:AVAudioSession) { SharedRuntime.session.suspendSystemAudio() }
    func providerDidReset(_ provider:CXProvider) { callID=nil;incomingID=nil;SharedRuntime.session.end() }
    private func sessionEnded() {
        startupTimer?.invalidate();startupTimer=nil;answerAction?.fail();answerAction=nil
        if let callID { provider.reportCall(with:callID,endedAt:Date(),reason:.remoteEnded) }
        if let incomingID { Task { try? await AttentionAPI.call(incomingID,action:"ended") } }
        callID=nil;incomingID=nil
    }
    func pushRegistry(_ registry:PKPushRegistry,didUpdate pushCredentials:PKPushCredentials,for type:PKPushType) {
        let token=pushCredentials.token.map{String(format:"%02x",$0)}.joined()
        #if DEBUG
        let environment="sandbox"
        #else
        let environment="production"
        #endif
        UserDefaults.standard.set(token,forKey:"voipToken");UserDefaults.standard.set(environment,forKey:"voipEnvironment")
        Task { try? await AttentionAPI.registerDevice() }
    }
    func pushRegistry(_ registry:PKPushRegistry,didInvalidatePushTokenFor type:PKPushType) { UserDefaults.standard.removeObject(forKey:"voipToken") }
    func pushRegistry(_ registry:PKPushRegistry,didReceiveIncomingPushWith payload:PKPushPayload,for type:PKPushType,completion:@escaping()->Void) {
        // Report immediately, before network work, including invalid or busy calls.
        let identifier=payload.dictionaryPayload["call_id"] as? String
        let id=identifier.flatMap(UUID.init(uuidString:)) ?? UUID()
        let update=CXCallUpdate();update.localizedCallerName="Hermes";update.remoteHandle=CXHandle(type:.generic,value:"Hermes");update.hasVideo=false;update.supportsHolding=false;update.supportsGrouping=false;update.supportsUngrouping=false;update.supportsDTMF=false
        provider.reportNewIncomingCall(with:id,update:update) { [weak self] error in
            Task { @MainActor in
                defer { completion() }
                guard let self,error==nil else { return }
                guard self.callID==nil,let identifier else { self.provider.reportCall(with:id,endedAt:Date(),reason:.failed);return }
                self.callID=id;self.incomingID=identifier
            }
        }
    }
}
class HermesAppDelegate:NSObject,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool { SystemCalls.shared.registerPushes();return true }
}
