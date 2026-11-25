import SwiftUI
import ServiceManagement
import GameController

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var devices: [Peripheral] = []
    @Published private(set) var refreshing = false
    @Published private(set) var updated: Date?
    @Published var message: String?
    @Published var interval: Int {
        didSet { UserDefaults.standard.set(interval, forKey: "refreshSeconds"); schedule() }
    }
    private var visible = false
    private var timer: Timer?
    private var previous: [String: Int] = [:]
    private var controllerIDs: [ObjectIdentifier: UUID] = [:]

    init() {
        let saved = UserDefaults.standard.integer(forKey: "refreshSeconds")
        interval = [15, 30, 90].contains(saved) ? saved : 90
        _ = GCController.controllers()
        schedule()
        refresh()
    }

    func panelVisible(_ value: Bool) {
        visible = value
        schedule()
        if value { refresh() }
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: visible ? Double(interval) : 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func controllers() -> [Peripheral] {
        let connected = GCController.controllers()
        let keys = Set(connected.map(ObjectIdentifier.init))
        controllerIDs = controllerIDs.filter { keys.contains($0.key) }
        return connected.compactMap { pad in
            guard let battery = pad.battery else { return nil }
            let key = ObjectIdentifier(pad)
            let id = controllerIDs[key] ?? UUID()
            controllerIDs[key] = id
            let level = battery.batteryLevel
            return Peripheral(id: id.uuidString, name: pad.vendorName ?? "游戏手柄", transport: "游戏手柄",
                              percent: (0...1).contains(level) ? Int((level * 100).rounded()) : nil,
                              charging: battery.batteryState == .unknown ? nil : battery.batteryState == .charging)
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                var rows = try await Task.detached(priority: .utility) { try BatteryScanner.scan() }.value
                rows += controllers()
                var next: [String: Int] = [:]
                for index in rows.indices {
                    let id = rows[index].id
                    if rows[index].percent == nil, let last = previous[id] {
                        rows[index].percent = last
                        rows[index].state += " · 上次电量"
                    }
                    next[id] = rows[index].percent
                }
                previous = next
                devices = rows
                updated = Date()
                message = nil
            } catch { message = "刷新失败 · " + error.localizedDescription }
        }
    }
}

@main
enum Launcher {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--test") {
            let devices = try BatteryScanner.scan()
            print("HID peripherals: " + String(devices.count))
            for device in devices {
                print(device.name, device.percent.map { String($0) + "%" } ?? "—", device.state)
            }
        } else {
            Voltide.main()
        }
    }
}

struct Voltide: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra("Voltide 外设电量", systemImage: "bolt.circle") {
            BatteryPanel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct BatteryPanel: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voltide").font(.title2.weight(.semibold))
                    Text("外设电量").foregroundStyle(.secondary)
                }
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).disabled(monitor.refreshing).help("立即刷新").accessibilityLabel("立即刷新")
                Menu {
                    Picker("刷新间隔", selection: $monitor.interval) {
                        ForEach([15, 30, 90], id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                    if loginStatus == .requiresApproval {
                        Button("在系统设置中批准登录项") { SMAppService.openSystemSettingsLoginItems() }
                    } else {
                        Toggle("登录时启动", isOn: Binding(get: { loginStatus == .enabled }, set: setLogin))
                    }
                    Divider()
                    Button("退出 Voltide") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).fixedSize().accessibilityLabel("更多选项").help("更多选项")
            }
            if monitor.devices.isEmpty {
                ContentUnavailableView(monitor.refreshing ? "正在读取外设" : "暂无外设电量",
                                       systemImage: "battery.0percent",
                                       description: Text("连接可报告电量的外设后刷新。"))
                    .frame(height: 134)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.devices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.headline).lineLimit(2)
                                    Text(device.transport + " · " + (device.charging == true ? "充电中" : device.state))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.percent.map { "\($0)%" } ?? "—")
                                    .font(.title3.monospacedDigit()).bold()
                                Image(systemName: device.batterySymbol)
                                    .foregroundStyle(device.percent.map { $0 < 20 ? Color.red : $0 < 50 ? .orange : .green } ?? .secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 10)
                            if device.id != monitor.devices.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(320, CGFloat(monitor.devices.count * 67)))
            }
            Divider()
            if let error = loginError ?? monitor.message {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let date = monitor.updated {
                HStack { Text("上次更新"); Text(date, style: .time) }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(width: 344)
        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.regularMaterial) } }
        .onAppear { loginStatus = SMAppService.mainApp.status; monitor.panelVisible(true) }
        .onDisappear { monitor.panelVisible(false) }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }
}
