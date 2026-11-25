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
            let app = NSApplication.shared
            let delegate = MenuBarController()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = Monitor()
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = item.button else { return }
        if let icon = NSImage(named: "MenuBarTemplate") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            icon.accessibilityDescription = "Voltide 外设电量"
            button.image = icon
        }
        button.toolTip = "Voltide 外设电量"
        button.target = self
        button.action = #selector(togglePanel)

        // Let the popover composite its own backdrop through the hosting view.
        let host = NSHostingController(rootView: BatteryPanel(monitor: monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func popoverWillShow(_ notification: Notification) { monitor.panelVisible(true) }
    func popoverDidClose(_ notification: Notification) { monitor.panelVisible(false) }
}

struct BatteryPanel: View {
    @ObservedObject var monitor: Monitor
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("外设电量").font(.title3.weight(.semibold))
                Spacer()
                Button { monitor.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 16)
                }
                .buttonStyle(.accessoryBar).disabled(monitor.refreshing).help("立即刷新").accessibilityLabel("立即刷新")
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
                } label: { Image(systemName: "gearshape").frame(width: 18, height: 16) }
                .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.accessoryBar).fixedSize().accessibilityLabel("更多选项").help("更多选项")
            }
            .padding(.bottom, 12)
            Divider()
            if monitor.devices.isEmpty {
                ContentUnavailableView(monitor.refreshing ? "正在读取外设" : "暂无外设电量",
                                       systemImage: "battery.0percent",
                                       description: Text("连接可报告电量的外设后刷新。"))
                    .frame(height: 134)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.devices) { device in
                            DeviceRow(device: device)
                            if device.id != monitor.devices.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(320, CGFloat(monitor.devices.count * 65) + CGFloat(monitor.devices.count - 1)))
            }
            Divider()
            if let error = loginError ?? monitor.message {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let date = monitor.updated {
                    Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                } else { Text("正在读取…") }
                Spacer()
                Text("每 \(monitor.interval) 秒")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 11)
        }
        .padding(16).frame(width: 344)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }
}

private struct DeviceRow: View {
    let device: Peripheral

    var body: some View {
        let level = device.percent ?? 0
        let color: Color = device.state != "已连接" ? .secondary : level < 20 ? .red : level < 50 ? .orange : .green
        HStack(spacing: 12) {
            Image(systemName: device.deviceSymbol)
                .font(.system(size: 21)).foregroundStyle(.secondary)
                .frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline).lineLimit(2)
                Text(device.state != "已连接" ? device.state : device.charging == true ? "充电中" : device.transport)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(device.percent.map { "\($0)%" } ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(device.percent == nil ? Color.secondary : color)
                Capsule().fill(.secondary.opacity(0.22)).frame(width: 48, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: 48 * CGFloat(level) / 100)
                    }
            }
        }
        .frame(height: 65)
        .accessibilityElement(children: .combine)
    }
}
