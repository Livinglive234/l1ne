import Foundation
import CallKit
import AVFoundation

/// Shows L1ne's calls to iOS through CallKit: the lock-screen call card, the green call indicator, the system
/// answer/decline UI and headset or car controls. The SIP side stays in SIPEngine; this only mirrors it.
///
/// A call that arrives while the app is closed still needs a push (PushKit) to wake the app. That is the "push to
/// the app for any server" item in docs/ROADMAP.md. Until then incoming calls use this UI only while L1ne is running.
@MainActor
final class CallKitManager: NSObject, CXProviderDelegate {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuids: [Int32: UUID] = [:]
    private var reportedConnected: Set<Int32> = []
    private var endedBySystem: Set<Int32> = []
    private var names: [UUID: String] = [:]
    private var startPerformed: Set<UUID> = []       // outgoing calls whose start action CallKit has processed
    private var connectedEarly: Set<UUID> = []       // answered before that happened; reported once it has

    private override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 4
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic, .phoneNumber]
        cfg.includesCallsInRecents = AppSettings.shared.callsInPhoneApp
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    private func uuid(_ id: Int32) -> UUID {
        if let u = uuids[id] { return u }
        let u = UUID(); uuids[id] = u; return u
    }

    /// Re-applies the setting that decides whether calls also show in the Phone app's Recents.
    func applySettings() {
        let cfg = provider.configuration
        cfg.includesCallsInRecents = AppSettings.shared.callsInPhoneApp
        provider.configuration = cfg
    }

    // MARK: SIPEngine -> system

    func reportIncoming(_ id: Int32, name: String, address: String) {
        guard uuids[id] == nil else { return }
        let u = uuid(id)
        let up = CXCallUpdate()
        up.remoteHandle = CXHandle(type: .generic, value: address.isEmpty ? name : address)
        up.localizedCallerName = name
        up.hasVideo = false
        up.supportsHolding = true
        up.supportsGrouping = false; up.supportsUngrouping = false; up.supportsDTMF = true
        provider.reportNewIncomingCall(with: u, update: up) { _ in }
    }

    /// Answers an incoming call from the app itself (auto answer), through CallKit so the system call screen and the audio session stay in step.
    func answerFromApp(_ id: Int32) {
        guard let u = uuids[id] else { SIPEngine.shared.answer(id); return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: u))) { err in
            if err != nil { Task { @MainActor in SIPEngine.shared.answer(id) } }
        }
    }

    func reportOutgoing(_ id: Int32, name: String, address: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["L1NE_NOCALLKIT"] != nil { return }     // tests/mock: the simulator's CallKit ends unanswered calls
        #endif
        guard uuids[id] == nil else { return }
        let u = uuid(id)
        names[u] = name
        let h = CXHandle(type: .generic, value: address.isEmpty ? name : address)
        let start = CXStartCallAction(call: u, handle: h)
        start.contactIdentifier = name
        controller.request(CXTransaction(action: start)) { [weak self] err in
            if err != nil { Task { @MainActor in self?.uuids[id] = nil } }
        }
    }

    func reportConnected(_ id: Int32, outgoing: Bool) {
        guard let u = uuids[id], !reportedConnected.contains(id) else { return }
        reportedConnected.insert(id)
        guard outgoing else { return }
        if startPerformed.contains(u) { provider.reportOutgoingCall(with: u, connectedAt: Date()) } else { connectedEarly.insert(u) }
    }

    func reportEnded(_ id: Int32) {
        guard let u = uuids.removeValue(forKey: id) else { return }
        startPerformed.remove(u); connectedEarly.remove(u); names[u] = nil
        reportedConnected.remove(id)
        if endedBySystem.remove(id) == nil { provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded) }
    }

    private func id(for action: CXCallAction) -> Int32? { uuids.first { $0.value == action.callUUID }?.key }

    // MARK: system -> SIPEngine

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in SIPEngine.shared.hangupAll(); self.uuids = [:]; self.reportedConnected = [] }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            if let n = self.names[action.callUUID] {          // show the contact's name, not the SIP address
                let up = CXCallUpdate()
                up.localizedCallerName = n
                up.supportsHolding = true; up.supportsGrouping = false; up.supportsUngrouping = false; up.supportsDTMF = true
                provider.reportCall(with: action.callUUID, updated: up)
            }
            self.startPerformed.insert(action.callUUID)
            if self.connectedEarly.remove(action.callUUID) != nil { provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date()) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            if let id = self.id(for: action) { SIPEngine.shared.answer(id) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if let id = self.id(for: action) { self.endedBySystem.insert(id); SIPEngine.shared.hangup(id) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in
            let e = SIPEngine.shared
            if let id = self.id(for: action), e.held.contains(id) != action.isOnHold { e.toggleHold(id) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            let e = SIPEngine.shared
            if let id = self.id(for: action), e.muted.contains(id) != action.isMuted { e.toggleMute(id) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { @MainActor in
            if let id = self.id(for: action) { SIPEngine.shared.sendDTMF(id, action.digits) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in SIPEngine.shared.audioSessionActivated() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in SIPEngine.shared.audioSessionDeactivated() }
    }
}
