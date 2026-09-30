import Foundation

/// A connection to the keyboard's raw HID interface.
public protocol HIDTransport: AnyObject, Sendable {
    var isConnected: Bool { get }
    /// Called on the main queue when the keyboard appears or disappears.
    var onConnectionChange: (@Sendable (Bool) -> Void)? { get set }
    func start()
    /// Sends a 32-byte report and returns the reply to the same command. Blocks: never call it
    /// on the main thread.
    func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8]
}
