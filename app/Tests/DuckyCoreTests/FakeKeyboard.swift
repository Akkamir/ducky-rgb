import Foundation
@testable import DuckyCore

/// Simulates the hostrgb firmware (protocol v2) for tests.
final class FakeKeyboard: HIDTransport, @unchecked Sendable {
    var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var connected: Bool
    private var log: [Command] = []
    private var failures: [Command: Status] = [:]

    let version: UInt8
    let effectIDs: [UInt8]
    var base = BaseSettings()
    var overlay = [RGB?](repeating: nil, count: 68)
    var savedBase: BaseSettings?
    var savedOverlay: [RGB?]?
    var hostMode = false
    var dirty = false

    init(version: UInt8 = 2, effectIDs: [UInt8] = Array(1...14), connected: Bool = true) {
        self.version = version
        self.effectIDs = effectIDs
        self.connected = connected
    }

    var isConnected: Bool { lock.withLock { connected } }

    func start() {}

    func setConnected(_ value: Bool) {
        lock.withLock { connected = value }
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(value) }
    }

    func commands() -> [Command] { lock.withLock { log } }

    /// Makes the next occurrence of `command` fail with `status`.
    func failNext(_ command: Command, with status: Status) {
        lock.withLock { failures[command] = status }
    }

    func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        try lock.withLock {
            guard connected else { throw DuckyError.notConnected }
            var out = [UInt8](repeating: 0, count: 32)
            out[0] = report[0]
            func reply(_ payload: [UInt8] = []) -> [UInt8] {
                for (i, byte) in payload.enumerated() { out[2 + i] = byte }
                return out
            }
            func fail(_ status: Status) -> [UInt8] {
                out[1] = status.rawValue
                return out
            }
            guard let command = Command(rawValue: report[0]) else { return fail(.unknownCommand) }
            log.append(command)
            if let status = failures.removeValue(forKey: command) { return fail(status) }
            if version < 2 && report[0] >= 0x10 { return fail(.unknownCommand) }
            let a = report
            switch command {
            case .ping:
                return reply([version, 68])
            case .hostMode:
                hostMode = a[1] != 0
                return reply()
            case .hostSet, .hostFill:
                return reply()
            case .getInfo:
                return reply([2, 68, UInt8(effectIDs.count), 1])
            case .getEffects:
                let first = Int(a[1])
                guard first <= effectIDs.count else { return fail(.badArgument) }
                let ids = Array(effectIDs[first..<min(effectIDs.count, first + 28)])
                return reply([UInt8(first), UInt8(ids.count)] + ids)
            case .getState:
                return reply([base.enabled ? 1 : 0, base.effectID, base.hue, base.saturation, base.brightness, base.speed,
                              hostMode ? 1 : 0, UInt8(overlay.compactMap { $0 }.count), dirty ? 1 : 0])
            case .setBase:
                guard effectIDs.contains(a[2]) else { return fail(.badArgument) }
                base = BaseSettings(enabled: a[1] != 0, effectID: a[2], hue: a[3], saturation: a[4], brightness: a[5], speed: a[6])
                dirty = true
                return reply()
            case .getOverlay:
                let first = Int(a[1])
                guard first < 68 else { return fail(.badArgument) }
                let count = min(7, 68 - first)
                var payload: [UInt8] = [UInt8(first), UInt8(count)]
                for color in overlay[first..<first + count] {
                    payload += color.map { [1, $0.r, $0.g, $0.b] } ?? [0, 0, 0, 0]
                }
                return reply(payload)
            case .setOverlay:
                let first = Int(a[1]), count = Int(a[2])
                guard count <= 7, first + count <= 68 else { return fail(.badArgument) }
                for i in 0..<count {
                    let e = Array(a[(3 + 4 * i)..<(7 + 4 * i)])
                    overlay[first + i] = e[0] & 1 == 1 ? RGB(e[1], e[2], e[3]) : nil
                }
                dirty = true
                return reply()
            case .clearOverlay:
                overlay = [RGB?](repeating: nil, count: 68)
                dirty = true
                return reply()
            case .save:
                savedBase = base
                savedOverlay = overlay
                dirty = false
                return reply()
            }
        }
    }
}
