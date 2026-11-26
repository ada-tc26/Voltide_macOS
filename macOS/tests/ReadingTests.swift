import Foundation

@main
enum ReadingTests {
    static func main() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        for (minutes, expected) in [(0, "00:00"), (7, "00:07"), (543, "09:03"), (1439, "23:59")] {
            let date = Date(timeIntervalSince1970: Double(minutes * 60))
            precondition(panelTime(date, timeZone: utc) == expected)
        }
        let start = Date(timeIntervalSince1970: 1000)
        var history = ReadingHistory()
        var headset = Peripheral(id: "bluetooth-1", name: "耳机", transport: "蓝牙", percent: 70)
        headset.componentLevels = [ComponentLevel(label: "左耳", percent: 0), ComponentLevel(label: "充电盒", percent: 32)]
        history.apply(ScanBatch(.bluetooth, time: start) { [headset] })
        headset.componentLevels.removeLast()
        headset.percent = nil
        history.apply(ScanBatch(.bluetooth, time: start.addingTimeInterval(30)) { [headset] })
        var row = history.devices[0]
        precondition(row.readAt == start && row.percent == 70 && row.stale)
        precondition(row.componentLevels[0].percent == 0 && !row.componentLevels[0].stale)
        precondition(row.componentLevels[1].readAt == start && row.componentLevels[1].stale)
        for seconds in [60, 100] {
            history.apply(ScanBatch(.bluetooth, time: start.addingTimeInterval(Double(seconds))) { throw CocoaError(.fileReadUnknown) })
            row = history.devices[0]
            precondition(row.state == "采集失败" && row.readAt == start)
            precondition(row.componentLevels[0].readAt == start.addingTimeInterval(30))
        }
        history.apply(ScanBatch(.bluetooth, time: start.addingTimeInterval(905)) { [headset] })
        precondition(history.devices[0].percent == nil && history.devices[0].componentLevels.count == 1)
        history.apply(ScanBatch(.bluetooth) { [] })
        precondition(history.devices.isEmpty)
        let empty = try BluetoothScanner.devices(in: Data(#"{"SPBluetoothDataType":[{"controller_properties":{}}]}"#.utf8))
        precondition(empty.isEmpty)
        for malformed in ["{}", "null", #"{"SPBluetoothDataType":[{"device_connected":"invalid"}]}"#] {
            do { _ = try BluetoothScanner.devices(in: Data(malformed.utf8)); fatalError("Malformed report accepted") }
            catch {}
        }
        let product = Array("PRO X Wireless 鼠标".utf8)
        let decoded = OutputReports.deviceName(length: product.count) { offset in
            product.dropFirst(Int(offset)).prefix(16)
        }
        precondition(decoded == "PRO X Wireless 鼠标")
        precondition(OutputReports.deviceName(length: 20) { _ in nil } == nil)
        let levels = (0...255).map { ReceiverScanner.razerPercent(UInt8($0)) }
        precondition(levels == levels.sorted())
        precondition([levels[0], levels[100], levels[101], levels[255]] == [0, 39, 40, 100])
        print("Reading history, Bluetooth failure handling and Razer conversion passed")
    }
}
