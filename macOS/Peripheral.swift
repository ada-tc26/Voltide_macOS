import Foundation
import IOKit
import IOKit.hid

struct Peripheral: Identifiable {
    let id: String
    let name: String
    let transport: String
    var percent: Int?
    var charging: Bool?
    var state = "已连接"

    var deviceSymbol: String {
        let label = name.lowercased()
        if transport == "游戏手柄" { return "gamecontroller" }
        if label.contains("keyboard") || label.contains("键盘") { return "keyboard" }
        if label.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if label.contains("head") || label.contains("耳机") || label.contains("airpods") { return "headphones" }
        if label.contains("mouse") || label.contains("鼠标") || id.hasPrefix("usb-") { return "computermouse" }
        return "dot.radiowaves.left.and.right"
    }
}

enum BatteryScanner {
    static func scan() throws -> [Peripheral] {
        var iterator: io_iterator_t = 0
        let match = ["IOPropertyExistsMatch": "BatteryPercent"] as CFDictionary
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        defer { IOObjectRelease(iterator) }
        var devices: [String: Peripheral] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard property("Built-In") as? Bool != true,
                  let name = property("Product") as? String ?? property("DeviceName") as? String,
                  let level = property("BatteryPercent") as? Int, (0...100).contains(level) else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            let id = property("DeviceAddress") as? String ?? "registry-\(entryID)"
            devices[id] = Peripheral(id: id, name: name, transport: property("Transport") as? String ?? "HID",
                                     percent: level, charging: property("IsCharging") as? Bool)
        }
        for receiver in ReceiverScanner.scan() { devices[receiver.id] = receiver }
        return devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
