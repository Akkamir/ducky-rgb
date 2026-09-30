import Foundation

/// Raw HID commands of the hostrgb firmware (spec section 3).
public enum Command: UInt8, Sendable {
    case ping = 0x01, hostMode = 0x02, hostSet = 0x03, hostFill = 0x04
    case getInfo = 0x10, getEffects = 0x11, getState = 0x12, setBase = 0x13
    case getOverlay = 0x14, setOverlay = 0x15, clearOverlay = 0x16, save = 0x17
}

public enum Status: UInt8, Sendable {
    case ok = 0, unknownCommand = 1, badArgument = 2, flashError = 3
}

public enum DuckyError: Error, Equatable, Sendable {
    case notConnected
    case timeout
    case malformedReply
    case status(Command, Status)
    case outdatedFirmware(version: Int)
}

/// The saved background layer: a QMK rgb_matrix effect and its parameters.
public struct BaseSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var effectID: UInt8
    public var hue: UInt8
    public var saturation: UInt8
    public var brightness: UInt8
    public var speed: UInt8

    public init(enabled: Bool = true, effectID: UInt8 = 1, hue: UInt8 = 0, saturation: UInt8 = 255, brightness: UInt8 = 200, speed: UInt8 = 128) {
        self.enabled = enabled
        self.effectID = effectID
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.speed = speed
    }
}

public struct KeyboardInfo: Equatable, Sendable {
    public let version: Int
    public let ledCount: Int
    public let effectCount: Int
    public let persistent: Bool
}

public struct KeyboardState: Equatable, Sendable {
    public let base: BaseSettings
    public let hostMode: Bool
    public let customizedCount: Int
    public let dirty: Bool
}

public enum DuckyProtocol {
    public static let reportSize = 32
    public static let version = 2
    public static let overlayPerReport = 7
    public static let effectsPerReport = 28
    public static let hostLEDsPerReport = 9

    public static func request(_ command: Command, _ args: [UInt8] = []) -> [UInt8] {
        precondition(args.count < reportSize, "too many arguments")
        let report = [command.rawValue] + args
        return report + [UInt8](repeating: 0, count: reportSize - report.count)
    }

    /// Checks a reply and returns its payload (bytes 2 and up).
    public static func payload(of reply: [UInt8], for command: Command) throws -> [UInt8] {
        guard reply.count >= 2, reply[0] == command.rawValue, let status = Status(rawValue: reply[1]) else {
            throw DuckyError.malformedReply
        }
        guard status == .ok else { throw DuckyError.status(command, status) }
        return Array(reply.dropFirst(2))
    }

    public static func setBase(_ base: BaseSettings) -> [UInt8] {
        request(.setBase, [base.enabled ? 1 : 0, base.effectID, base.hue, base.saturation, base.brightness, base.speed])
    }

    public static func setOverlay(first: Int, colors: [RGB?]) -> [UInt8] {
        precondition(colors.count <= overlayPerReport, "at most \(overlayPerReport) LEDs per report")
        var args: [UInt8] = [UInt8(first), UInt8(colors.count)]
        for color in colors {
            args += color.map { [1, $0.r, $0.g, $0.b] } ?? [0, 0, 0, 0]
        }
        return request(.setOverlay, args)
    }

    public static func decodePing(_ p: [UInt8]) throws -> (version: Int, ledCount: Int) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        return (Int(p[0]), Int(p[1]))
    }

    public static func decodeInfo(_ p: [UInt8]) throws -> KeyboardInfo {
        guard p.count >= 4 else { throw DuckyError.malformedReply }
        return KeyboardInfo(version: Int(p[0]), ledCount: Int(p[1]), effectCount: Int(p[2]), persistent: p[3] != 0)
    }

    public static func decodeEffects(_ p: [UInt8]) throws -> (first: Int, ids: [UInt8]) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        let count = Int(p[1])
        guard count <= effectsPerReport, p.count >= 2 + count else { throw DuckyError.malformedReply }
        return (Int(p[0]), Array(p[2..<2 + count]))
    }

    public static func decodeState(_ p: [UInt8]) throws -> KeyboardState {
        guard p.count >= 9 else { throw DuckyError.malformedReply }
        let base = BaseSettings(enabled: p[0] != 0, effectID: p[1], hue: p[2], saturation: p[3], brightness: p[4], speed: p[5])
        return KeyboardState(base: base, hostMode: p[6] != 0, customizedCount: Int(p[7]), dirty: p[8] != 0)
    }

    public static func decodeOverlay(_ p: [UInt8]) throws -> (first: Int, colors: [RGB?]) {
        guard p.count >= 2 else { throw DuckyError.malformedReply }
        let count = Int(p[1])
        guard count <= overlayPerReport, p.count >= 2 + 4 * count else { throw DuckyError.malformedReply }
        let colors: [RGB?] = (0..<count).map { i in
            let e = Array(p[(2 + 4 * i)..<(6 + 4 * i)])
            return e[0] & 1 == 1 ? RGB(e[1], e[2], e[3]) : nil
        }
        return (Int(p[0]), colors)
    }
}
