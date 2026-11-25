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

    var batterySymbol: String {
        if charging == true { return "bolt.fill" }
        guard let percent else { return "questionmark.circle" }
        let quarter = Int((Double(percent) / 25).rounded()) * 25
        return "battery.\(quarter)percent"
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
