import Foundation

/// Protocol v2 operations over a transport. Blocking: use it from a background queue.
public final class KeyboardClient: @unchecked Sendable {
    public let transport: HIDTransport
    public var timeout: TimeInterval = 1.0

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    @discardableResult
    private func send(_ report: [UInt8]) throws -> [UInt8] {
        guard let command = Command(rawValue: report[0]) else { throw DuckyError.malformedReply }
        let reply = try transport.exchange(report, timeout: timeout)
        return try DuckyProtocol.payload(of: reply, for: command)
    }

    public func ping() throws -> (version: Int, ledCount: Int) {
        try DuckyProtocol.decodePing(send(DuckyProtocol.request(.ping)))
    }

    public func info() throws -> KeyboardInfo {
        try DuckyProtocol.decodeInfo(send(DuckyProtocol.request(.getInfo)))
    }

    public func effects(count: Int) throws -> [UInt8] {
        var ids: [UInt8] = []
        while ids.count < count {
            let page = try DuckyProtocol.decodeEffects(send(DuckyProtocol.request(.getEffects, [UInt8(ids.count)])))
            guard page.first == ids.count else { throw DuckyError.malformedReply } // late reply to another page
            guard !page.ids.isEmpty else { break }
            ids += page.ids
        }
        return ids
    }

    public func state() throws -> KeyboardState {
        try DuckyProtocol.decodeState(send(DuckyProtocol.request(.getState)))
    }

    public func setBase(_ base: BaseSettings) throws {
        try send(DuckyProtocol.setBase(base))
    }

    public func overlay(ledCount: Int) throws -> [RGB?] {
        var colors: [RGB?] = []
        while colors.count < ledCount {
            let page = try DuckyProtocol.decodeOverlay(send(DuckyProtocol.request(.getOverlay, [UInt8(colors.count)])))
            guard page.first == colors.count else { throw DuckyError.malformedReply } // late reply to another page
            guard !page.colors.isEmpty else { break }
            colors += page.colors
        }
        return colors
    }

    /// Writes the overlay in reports of 7 LEDs; with `only`, skips reports without a changed LED.
    public func setOverlay(_ colors: [RGB?], only changed: Set<Int>? = nil) throws {
        for first in stride(from: 0, to: colors.count, by: DuckyProtocol.overlayPerReport) {
            let range = first..<min(first + DuckyProtocol.overlayPerReport, colors.count)
            if let changed, !range.contains(where: changed.contains) { continue }
            try send(DuckyProtocol.setOverlay(first: first, colors: Array(colors[range])))
        }
    }

    public func clearOverlay() throws {
        try send(DuckyProtocol.request(.clearOverlay))
    }

    public func save() throws {
        try send(DuckyProtocol.request(.save))
    }

    public func setHostMode(_ on: Bool) throws {
        try send(DuckyProtocol.request(.hostMode, [on ? 1 : 0]))
    }
}
