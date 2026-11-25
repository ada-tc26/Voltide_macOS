import Foundation
import IOKit.hid

// Feature reports with ID zero omit the Windows-only prefix on macOS.
enum ReceiverScanner {
    private static let razerProducts: Set<Int> = [
        0x007B, 0x00C1, 0x00DF, 0x00B7, 0x00C3, 0x00BF, 0x00E6, 0x00AB,
        0x00CD, 0x00D7, 0x00C5, 0x00D1, 0x00C8, 0x00D4, 0x00B0, 0x00DB,
        0x00B4, 0x00B8, 0x00B9, 0x00B3, 0x009A, 0x005A, 0x0045
    ]

    static func scan() -> [Peripheral] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matches = [[kIOHIDVendorIDKey: 0x1532], [kIOHIDVendorIDKey: 0x046D],
                       [kIOHIDVendorIDKey: 0x373B], [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFB34],
                       [kIOHIDVendorIDKey: 0x258A, kIOHIDProductIDKey: 0x0138]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var found: [String: Peripheral] = [:]
        for device in devices {
            func property(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
            guard let vid = property(kIOHIDVendorIDKey) as? Int,
                  let pid = property(kIOHIDProductIDKey) as? Int else { continue }
            let length = property(kIOHIDMaxFeatureReportSizeKey) as? Int
            let razer = vid == 0x1532 && razerProducts.contains(pid) && length == 90
            let eweadn = vid == 0x258A && pid == 0x0138 && length == 520 && IOHIDDeviceConformsTo(device, 0xFF02, 2)
            let outputSize = property(kIOHIDMaxOutputReportSizeKey) as? Int
            let logitech = vid == 0x046D && IOHIDDeviceConformsTo(device, 0xFF00, 2) && outputSize == 20
            let compxModels = [0x10C9: "VXE R1", 0x1278: "ATK A9 Air", 0xFB34: "IMECOO P1"]
            let compx = ((vid == 0x373B && [0x10C9, 0x1278].contains(pid)) || (vid == 0x3554 && pid == 0xFB34))
                && property(kIOHIDPrimaryUsagePageKey) as? Int == 0xFF02 && outputSize == 17
            guard razer || eweadn || logitech || compx else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID) == KERN_SUCCESS else { continue }
            let location = (property(kIOHIDLocationIDKey) as? NSNumber)?.stringValue ?? String(entryID)
            let id = "usb-\(vid)-\(pid)-\(location)"
            if found[id]?.percent != nil { continue }
            let name = compxModels[pid] ?? property(kIOHIDProductKey) as? String ?? (razer ? "Razer" : eweadn ? "EWEADN A5 Pro" : "Logitech")
            var row = Peripheral(id: id, name: name,
                                 transport: "2.4 GHz", state: "暂未收到读数")
            if IOHIDDeviceOpen(device, 0) == kIOReturnSuccess {
                defer { IOHIDDeviceClose(device, 0) }
                if razer { readRazer(device, into: &row) }
                else if eweadn { readA5(device, into: &row) }
                else if logitech { OutputReports(device).readLogitech(into: &row) }
                else { OutputReports(device).readCompx(into: &row) }
            } else { row.state = "无法访问接收器" }
            found[id] = row
        }
        return Array(found.values)
    }

    private static func response(_ device: IOHIDDevice, id: Int, size: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: size)
        data[0] = UInt8(id)
        var count = size
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, &data, &count) == kIOReturnSuccess,
              count == size else { return nil }
        return data
    }

    private static func readRazer(_ device: IOHIDDevice, into row: inout Peripheral) {
        var query = [UInt8](repeating: 0, count: 90)
        query[1] = UInt8.random(in: 0x20...0xEF)
        query[5...7] = [2, 7, 0x80]
        query[88] = query[2..<88].reduce(0, ^)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, query, query.count) == kIOReturnSuccess else { return }
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.01)
            guard let data = response(device, id: 0, size: 90), data[1] == query[1],
                  data[6] == 7, data[7] == 0x80 else { continue }
            if data[0] == 4 { row.state = "设备未应答"; return }
            guard data[0] == 2, data[5] >= 2 else { continue }
            let raw = Int(data[9])
            row.percent = raw <= 100 ? raw : Int((Double(raw) * 100 / 255).rounded())
            row.charging = data[8] != 0
            row.state = "已连接"
            return
        }
    }

    private static func readA5(_ device: IOHIDDevice, into row: inout Peripheral) {
        let sequence = UInt8.random(in: 0...255)
        var query = [UInt8](repeating: 0, count: 520)
        query[0...6] = [9, 12 &+ sequence, 9, 1, 1, sequence, 1]
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 9, query, query.count) == kIOReturnSuccess else { return }
        Thread.sleep(forTimeInterval: 0.1)
        guard let data = response(device, id: 9, size: 520), data[0] == 9,
              data[2...6] == query[2...6], data[7] == 0, data[8] <= 100 else { return }
        row.percent = Int(data[8])
        row.state = "已连接"
    }
}
