import Foundation
import IOKit.hid

/// Receivers that answer an output report on their interrupt input channel.
/// Register before sending so a fast reply cannot race the listener.
final class OutputReports {
    private let device: IOHIDDevice
    private var packets: [[UInt8]] = []
    private let mode = "io.voltide.receiver" as CFString

    init(_ device: IOHIDDevice) { self.device = device }

    func exchange(_ request: [UInt8], timeout: Double, accepts: ([UInt8]) -> Bool) -> [UInt8]? {
        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        guard let loop = CFRunLoopGetCurrent(), (1...4096).contains(size) else { return nil }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        packets.removeAll()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, result, _, _, _, bytes, length in
            guard let context, result == kIOReturnSuccess, length > 0 else { return }
            let reader = Unmanaged<OutputReports>.fromOpaque(context).takeUnretainedValue()
            reader.packets.append(Array(UnsafeBufferPointer(start: bytes, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, loop, mode)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, mode)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, nil, nil)
            buffer.deallocate()
        }
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, Int(request[0]), request, request.count) == kIOReturnSuccess else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(CFRunLoopMode(mode), 0.025, true)
            if let reply = packets.first(where: accepts) { return reply }
            packets.removeAll(keepingCapacity: true)
        }
        return nil
    }

    static func validCompxReply(_ bytes: [UInt8]) -> Bool {
        bytes.count == 17 && bytes[0] == 8 && bytes[1] == 4 && bytes[2] == 0 &&
        bytes[6] <= 100 && bytes[1...16].reduce(UInt8(0), &+) == 0x4D &&
        bytes[3...9].contains(where: { $0 != 0 })
    }

    func readCompx(into row: inout Peripheral) {
        var query = [UInt8](repeating: 0, count: 17)
        query[0] = 8
        query[1] = 4
        query[16] = 0x49
        guard let data = exchange(query, timeout: 0.8, accepts: Self.validCompxReply) else { return }
        row.percent = Int(data[6])
        row.charging = data[7] == 1
        row.state = "已连接"
    }

    func readLogitech(into row: inout Peripheral) {
        for slot: UInt8 in 1...4 {
            func call(feature: UInt8, function: UInt8, parameters: [UInt8] = []) -> [UInt8]? {
                var request = [UInt8](repeating: 0, count: 20)
                request[0...3] = [0x11, slot, feature, (function << 4) | 0x0E]
                request.replaceSubrange(4..<(4 + parameters.count), with: parameters)
                return exchange(request, timeout: 0.65) { reply in
                    reply.count >= 7 && reply[0...3] == request[0...3]
                }
            }
            guard let levelFeature = call(feature: 0, function: 0, parameters: [0x10, 0]) else { continue }
            var feature = levelFeature[4]
            var function: UInt8 = 0
            if feature == 0 {
                feature = call(feature: 0, function: 0, parameters: [0x10, 4])?[4] ?? 0
                function = 1
            }
            guard feature != 0, let result = call(feature: feature, function: function), result[4] <= 100 else { continue }
            row.percent = Int(result[4])
            row.charging = result[5] & 1 != 0
            row.state = "已连接"
            return
        }
    }
}
