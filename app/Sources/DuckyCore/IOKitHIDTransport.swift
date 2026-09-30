import Foundation
import IOKit.hid

/// Raw HID connection through IOHIDManager. Device callbacks run on the main run loop; `exchange`
/// blocks a background thread until the matching reply arrives.
public final class IOKitHIDTransport: HIDTransport, @unchecked Sendable {
    public static let vendorID = 0x445B
    public static let productID = 0x07AE
    public static let usagePage = 0xFF60
    public static let usage = 0x61

    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    public var isConnected: Bool { lock.withLock { device != nil } }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var inbox: [[UInt8]] = []
    private let arrival = DispatchSemaphore(value: 0)
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var started = false

    public init() {}

    deinit {
        inputBuffer.deallocate()
    }

    public func start() {
        guard !started else { return }
        started = true
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ newDevice: IOHIDDevice) {
        guard IOHIDDeviceOpen(newDevice, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(newDevice, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().receive(bytes)
        }, context)
        lock.withLock { device = newDevice }
        onConnectionChange?(true)
    }

    private func detach(_ oldDevice: IOHIDDevice) {
        let removed = lock.withLock { () -> Bool in
            guard let current = device, CFEqual(current, oldDevice) else { return false }
            device = nil
            return true
        }
        if removed { onConnectionChange?(false) }
    }

    private func receive(_ report: [UInt8]) {
        lock.withLock { inbox.append(report) }
        arrival.signal()
    }

    public func exchange(_ report: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        precondition(!Thread.isMainThread, "exchange blocks; call it off the main thread")
        guard let device = lock.withLock({ self.device }) else { throw DuckyError.notConnected }
        lock.withLock { inbox.removeAll() }
        while arrival.wait(timeout: .now()) == .success {}
        let status = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
        }
        guard status == kIOReturnSuccess else { throw DuckyError.notConnected }
        let deadline = DispatchTime.now() + timeout
        while true {
            guard arrival.wait(timeout: deadline) == .success else { throw DuckyError.timeout }
            let reply = lock.withLock { inbox.isEmpty ? nil : inbox.removeFirst() }
            // Replies to an earlier command that timed out can still arrive: skip them.
            if let reply, reply.first == report.first { return reply }
        }
    }
}
