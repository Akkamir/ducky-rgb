import Foundation
import Observation

/// App-facing state of the keyboard. Edits apply to the keyboard immediately; one save is sent
/// `saveDelay` seconds after the last edit. HID work runs on a serial queue, in call order.
@MainActor
@Observable
public final class LightingController {
    public enum Connection: Equatable, Sendable {
        case disconnected
        case outdatedFirmware(version: Int)
        case connected
    }

    public enum SaveState: Equatable, Sendable {
        case saved
        case pending
        case failed(String)
    }

    public private(set) var connection: Connection = .disconnected
    public private(set) var saveState: SaveState = .saved
    public private(set) var hostMode = false
    public private(set) var base = BaseSettings()
    public private(set) var overlay = [RGB?](repeating: nil, count: KeyboardLayout.ledCount)
    public private(set) var effects: [Effect] = []
    public private(set) var info: KeyboardInfo?
    public private(set) var lastError: String?
    /// True while the app streams live frames (audio mode) through the host mode.
    public private(set) var showingLiveFrames = false

    public var canControl: Bool { connection == .connected }

    private let transport: HIDTransport
    private let client: KeyboardClient
    private let queue = DispatchQueue(label: "ducky-rgb.hid")
    private let saveDelay: TimeInterval
    private var editGeneration = 0
    private let liveFrame = LiveFrameSlot()

    public init(transport: HIDTransport, saveDelay: TimeInterval = 2) {
        self.transport = transport
        self.client = KeyboardClient(transport: transport)
        self.saveDelay = saveDelay
    }

    public func start() {
        transport.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.connectionChanged(connected) }
        }
        transport.start()
        if transport.isConnected { connectionChanged(true) }
    }

    private func connectionChanged(_ connected: Bool) {
        showingLiveFrames = false // a replugged keyboard starts without host mode
        liveFrame.clear()
        if connected {
            refresh()
        } else {
            connection = .disconnected
            saveState = .saved
            info = nil
        }
    }

    private struct Snapshot: Sendable {
        let version: Int
        let info: KeyboardInfo?
        let effectIDs: [UInt8]
        let state: KeyboardState?
        let overlay: [RGB?]
    }

    private nonisolated static func readSnapshot(_ client: KeyboardClient) throws -> Snapshot {
        let ping = try client.ping()
        guard ping.version >= DuckyProtocol.version else {
            return Snapshot(version: ping.version, info: nil, effectIDs: [], state: nil, overlay: [])
        }
        let info = try client.info()
        return Snapshot(version: ping.version, info: info, effectIDs: try client.effects(count: info.effectCount),
                        state: try client.state(), overlay: try client.overlay(ledCount: info.ledCount))
    }

    /// Refreshes when the keyboard is plugged in, whatever the last known state (recovers after a
    /// failed start or a transient write error).
    public func refreshIfPresent() {
        if transport.isConnected { refresh() }
    }

    /// Saves now if a save is pending (used before quitting), then calls `completion`.
    public func flushPendingSave(completion: @escaping @MainActor () -> Void) {
        guard saveState == .pending, canControl else {
            queue.async { Task { @MainActor in completion() } } // after queued HID work
            return
        }
        editGeneration += 1 // cancels the scheduled save
        let generation = editGeneration
        queue.async { [client] in
            let result = Result { try client.save() }
            Task { @MainActor [weak self] in
                if let self, generation == self.editGeneration {
                    switch result {
                    case .success: self.saveState = .saved
                    case .failure(let error): self.saveState = .failed(Self.describe(error))
                    }
                }
                completion()
            }
        }
    }

    /// Re-reads everything from the keyboard.
    public func refresh() {
        let liveWhenQueued = showingLiveFrames
        queue.async { [client] in
            let result = Result { try Self.readSnapshot(client) }
            Task { @MainActor [weak self] in self?.apply(snapshot: result, liveWhenQueued: liveWhenQueued) }
        }
    }

    private func apply(snapshot result: Result<Snapshot, Error>, liveWhenQueued: Bool) {
        switch result {
        case .failure(let error):
            report(error)
        case .success(let snapshot):
            guard let info = snapshot.info, let state = snapshot.state else {
                connection = .outdatedFirmware(version: snapshot.version)
                return
            }
            self.info = info
            effects = EffectCatalog.effects(for: snapshot.effectIDs)
            base = state.base
            // Our own live frames are not "the CLI" (the read may predate their end).
            hostMode = state.hostMode && !liveWhenQueued && !showingLiveFrames
            overlay = snapshot.overlay
            saveState = state.dirty ? .pending : .saved
            lastError = nil
            connection = .connected
            if state.dirty { scheduleSave() }
        }
    }

    public func setBase(_ new: BaseSettings) {
        guard canControl, new != base else { return }
        base = new
        edit { try $0.setBase(new) }
    }

    /// Sets (or erases, with nil) the custom colour of the given LEDs.
    public func paint(_ indices: [Int], color: RGB?) {
        guard canControl else { return }
        var changed = Set<Int>()
        for i in indices where overlay.indices.contains(i) && overlay[i] != color {
            overlay[i] = color
            changed.insert(i)
        }
        guard !changed.isEmpty else { return }
        let colors = overlay, changedLEDs = changed
        edit { try $0.setOverlay(colors, only: changedLEDs) }
    }

    public func fill(_ color: RGB) {
        paint(Array(overlay.indices), color: color)
    }

    public func clearOverlay() {
        guard canControl else { return }
        overlay = [RGB?](repeating: nil, count: overlay.count)
        edit { try $0.clearOverlay() }
    }

    public func apply(_ preset: Preset) {
        guard canControl else { return }
        base = preset.base
        overlay = preset.overlayColors(ledCount: overlay.count)
        let newBase = base, colors = overlay
        let custom = Set(colors.indices.filter { colors[$0] != nil })
        edit { client in
            try client.setBase(newBase)
            try client.clearOverlay()
            try client.setOverlay(colors, only: custom)
        }
    }

    /// Takes the LEDs back from the CLI's live mode.
    public func releaseHostMode() {
        guard canControl else { return }
        hostMode = false
        queue.async { [client] in
            do { try client.setHostMode(false) } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
    }

    /// Shows a live frame through the host mode (audio mode). Nothing is saved.
    public func showLiveFrame(_ colors: [RGB]) {
        guard canControl else { return }
        let enableHostMode = !showingLiveFrames
        showingLiveFrames = true
        guard let generation = liveFrame.put(colors, enableHostMode: enableHostMode) else { return }
        queue.async { [client, liveFrame] in
            guard let next = liveFrame.take(generation: generation) else { return }
            do {
                if next.enableHostMode { try client.setHostMode(true) }
                try client.sendHostFrame(next.frame)
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if next.enableHostMode, self.showingLiveFrames {
                        // Host mode may be off: the next frame asks for it again.
                        self.showingLiveFrames = false
                        self.liveFrame.clear()
                    }
                    self.report(error)
                }
            }
        }
    }

    /// Stops live frames: the keyboard shows the saved lighting again.
    public func endLiveFrames() {
        guard showingLiveFrames else { return }
        showingLiveFrames = false
        liveFrame.clear()
        queue.async { [client] in
            do {
                // A keyboard left in host mode would stay frozen on the last frame: try twice.
                do { try client.setHostMode(false) } catch { try client.setHostMode(false) }
            } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
    }

    private func edit(_ work: @escaping @Sendable (KeyboardClient) throws -> Void) {
        // An edit in the app means the user wants to see it: take the LEDs back from the CLI's live mode.
        let releaseHostMode = hostMode
        hostMode = false
        queue.async { [client] in
            do {
                if releaseHostMode { try client.setHostMode(false) }
                try work(client)
                Task { @MainActor [weak self] in self?.lastError = nil }
            } catch {
                Task { @MainActor [weak self] in self?.report(error) }
            }
        }
        scheduleSave()
    }

    private func scheduleSave() {
        editGeneration += 1
        let generation = editGeneration
        saveState = .pending
        let delay = UInt64(saveDelay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.saveIfLatest(generation)
        }
    }

    private func saveIfLatest(_ generation: Int) {
        guard generation == editGeneration, canControl else { return }
        queue.async { [client] in
            let result = Result { try client.save() }
            Task { @MainActor [weak self] in
                guard let self, generation == self.editGeneration else { return }
                switch result {
                case .success: self.saveState = .saved
                case .failure(let error):
                    self.saveState = .failed(Self.describe(error))
                    self.report(error)
                }
            }
        }
    }

    private func report(_ error: Error) {
        lastError = Self.describe(error)
        // A failed write while the device is still plugged in is not a disconnection.
        if case DuckyError.notConnected = error, !transport.isConnected { connection = .disconnected }
    }

    public nonisolated static func describe(_ error: Error) -> String {
        switch error as? DuckyError {
        case .notConnected: return "Clavier non connecté"
        case .timeout: return "Le clavier ne répond pas"
        case .malformedReply: return "Réponse inattendue du clavier"
        case .status(let command, let status): return "Commande \(command) refusée (\(status))"
        case .outdatedFirmware(let version): return "Firmware v\(version) à mettre à jour"
        case nil: return error.localizedDescription
        }
    }
}

/// Holds the latest live frame until the HID queue sends it; older unsent frames are replaced.
/// `clear()` starts a new generation: sends queued before it no longer take frames.
final class LiveFrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: [RGB]?
    private var enableHostMode = false
    private var generation = 0

    /// Stores the frame; returns the generation to send it with when no send is queued yet.
    func put(_ colors: [RGB], enableHostMode enable: Bool) -> Int? {
        lock.withLock {
            let wasEmpty = frame == nil
            frame = colors
            enableHostMode = enableHostMode || enable
            return wasEmpty ? generation : nil
        }
    }

    func take(generation expected: Int) -> (frame: [RGB], enableHostMode: Bool)? {
        lock.withLock {
            guard expected == generation, let colors = frame else { return nil }
            let enable = enableHostMode
            frame = nil
            enableHostMode = false
            return (colors, enable)
        }
    }

    func clear() {
        lock.withLock {
            frame = nil
            enableHostMode = false
            generation += 1
        }
    }
}
