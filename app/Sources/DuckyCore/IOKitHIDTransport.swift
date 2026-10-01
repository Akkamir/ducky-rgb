import Foundation
import IOKit.hid

/// Raw HID connection through IOHIDManager. Device and report callbacks run on a private dispatch
/// queue, so replies keep arriving while the main run loop tracks a slider or a window resize;
/// `exchange` blocks its caller until the matching reply arrives.
public final class IOKitHIDTransport: HIDTransport, @unchecked Sendable {
    public static let vendorID = 0x445B
    public static let productID = 0x07AE
    public static let usagePage = 0xFF60
    public static let usage = 0x61

    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    public var onEvent: (@Sendable ([UInt8]) -> Void)?
    public var isConnected: Bool { lock.withLock { device != nil } }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var inbox: [[UInt8]] = []
    private let arrival = DispatchSemaphore(value: 0)
    private let callbackQueue = DispatchQueue(label: "ducky-rgb.hid-callbacks")
    private var started = false

    public init() {}

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
        // With a dispatch queue, callbacks must be registered on the manager before activation;
        // the manager opens matched devices itself and reports their input here.
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().receive(bytes)
        }, context)
        IOHIDManagerSetDispatchQueue(manager, callbackQueue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
    }

    private func attach(_ newDevice: IOHIDDevice) {
        lock.withLock { device = newDevice }
        notify(true)
    }

    private func detach(_ oldDevice: IOHIDDevice) {
        let removed = lock.withLock { () -> Bool in
            guard let current = device, CFEqual(current, oldDevice) else { return false }
            device = nil
            return true
        }
        if removed { notify(false) }
    }

    private func notify(_ connected: Bool) {
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(connected) }
    }

    private func receive(_ report: [UInt8]) {
        if DuckyProtocol.isEvent(report) { // sent by the keyboard on its own, not a reply
            onEvent?(report)
            return
        }
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
