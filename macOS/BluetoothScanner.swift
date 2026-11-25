import Foundation

enum BluetoothScanner {
    // Read the same connected-device inventory macOS exposes in System Information.
    // This does not start discovery or initiate a connection to a sleeping device.
    static func scan() -> [Peripheral] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-timeout", "8", "SPBluetoothDataType"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return devices(in: data)
    }

    static func addressID(_ address: String?) -> String? {
        guard let address else { return nil }
        let digits = address.lowercased().filter { $0 != ":" && $0 != "-" }
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "bluetooth-" + digits
    }

    static func devices(in data: Data) -> [Peripheral] {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = report["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var rows: [Peripheral] = []
        for controller in controllers {
            let connected = controller["device_connected"] as? [[String: [String: Any]]] ?? []
            for entry in connected {
                for (name, fields) in entry {
                    guard let id = addressID(fields["device_address"] as? String) else { continue }
                    let main = percent(fields["device_batteryLevelMain"]) ?? percent(fields["device_batteryLevelCombined"])
                    let components = [("Left", "左耳"), ("Right", "右耳"), ("Case", "充电盒")].compactMap { key, label in
                        percent(fields["device_batteryLevel" + key]).map { ComponentLevel(label: label, percent: $0) }
                    }
                    var row = Peripheral(id: id, name: name, transport: "蓝牙", percent: main, charging: nil)
                    row.componentLevels = components
                    row.bluetoothType = fields["device_minorType"] as? String
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private static func percent(_ raw: Any?) -> Int? {
        let text = (raw as? String ?? (raw as? NSNumber)?.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, let value = Int(text.hasSuffix("%") ? String(text.dropLast()).trimmingCharacters(in: .whitespaces) : text),
              (0...100).contains(value) else { return nil }
        return value
    }
}
