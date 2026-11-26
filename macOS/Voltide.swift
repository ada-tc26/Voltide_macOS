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
    private var history = ReadingHistory()
    @Published private(set) var aliases = UserDefaults.standard.dictionary(forKey: "deviceAliases") as? [String: String] ?? [:]

    func setAlias(_ value: String, for key: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases[key] = name.isEmpty ? nil : String(name.prefix(80))
        UserDefaults.standard.set(aliases, forKey: "deviceAliases")
    }
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
            var row = Peripheral(id: id.uuidString, name: pad.vendorName ?? "游戏手柄", transport: "游戏手柄",
                              percent: (0...1).contains(level) ? Int((level * 100).rounded()) : nil,
                              charging: battery.batteryState == .unknown ? nil : battery.batteryState == .charging)
            let peers = connected.filter { $0.vendorName == pad.vendorName && $0.productCategory == pad.productCategory }
            if peers.count == 1 { row.aliasKey = "controller-\(pad.productCategory)-\(row.name)" }
            return row
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let batches = await Task.detached(priority: .utility) { BatteryScanner.scan() }.value
            for batch in batches { history.apply(batch) }
            // Use fresh Bluetooth identities when the controller API reports the same pad.
            let bluetooth = batches.first { $0.source == .bluetooth }?.rows ?? []
            let pads = controllers()
            history.apply(ScanBatch(.controller) {
                pads.map { pad in
                    let matches = bluetooth.filter { $0.deviceSymbol == "gamecontroller" &&
                        $0.name.caseInsensitiveCompare(pad.name) == .orderedSame }
                    guard matches.count == 1, pads.filter({ $0.name == pad.name }).count == 1 else { return pad }
                    var row = matches[0]
                    row.componentLevels = []
                    row.percent = pad.percent
                    row.charging = pad.charging
                    return row
                }
            })
            devices = history.devices
            updated = Date()
            let failures = batches.filter { $0.rows == nil }.map { $0.source.rawValue }
            message = failures.isEmpty ? nil : failures.joined(separator: "、") + "采集失败"

        }
    }
}

@main
enum Launcher {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--test") {
            let batches = BatteryScanner.scan()
            var history = ReadingHistory()
            for batch in batches {
                history.apply(batch)
                if batch.rows == nil { print(batch.source.rawValue + "采集失败") }
            }
            let devices = history.devices
            print("Peripherals: " + String(devices.count))
            for device in devices {
                let levels = device.componentLevels.map { "\($0.label) \($0.percent)%" }
                let values = [device.percent.map { "\($0)%" }].compactMap { $0 } + levels
                print(device.name, values.isEmpty ? "—" : values.joined(separator: " · "), device.statusText)
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
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = item.button else { return }
        if let icon = NSImage(named: "MenuBarTemplate") {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            icon.accessibilityDescription = "Voltide 外设电量"
            button.imagePosition = .imageOnly
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
                            DeviceRow(device: device, monitor: monitor)
                            if device.id != monitor.devices.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(320, monitor.devices.reduce(CGFloat.zero) { $0 + DeviceRow.height(for: $1) } + CGFloat(monitor.devices.count - 1)))
            }
            Divider()
            if let error = loginError ?? monitor.message {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let date = monitor.updated {
                    Text("刷新于 \(date.formatted(date: .omitted, time: .shortened))")
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

    @ObservedObject var monitor: Monitor
    @State private var editing = false
    @State private var draft = ""

    private var aliasKey: String { device.aliasKey ?? device.id }
    private func editAlias() {
        draft = monitor.aliases[aliasKey] ?? ""
        editing = true
    }

    static func height(for device: Peripheral) -> CGFloat {
        device.componentLevels.isEmpty ? 70 : 115
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: device.deviceSymbol)
                    .font(.system(size: 21)).foregroundStyle(.secondary)
                    .frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: editAlias) {
                        Text(monitor.aliases[aliasKey] ?? device.name).font(.headline).lineLimit(2)
                    }
                    .buttonStyle(.plain).help("编辑设备别名 · " + device.name)
                    .popover(isPresented: $editing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("设备别名").font(.headline)
                            Text(device.name).font(.caption).foregroundStyle(.secondary)
                            TextField("使用原名", text: $draft)
                                .onSubmit { monitor.setAlias(draft, for: aliasKey); editing = false }
                            HStack {
                                Button("恢复原名") { monitor.setAlias("", for: aliasKey); editing = false }
                                Spacer()
                                Button("保存") { monitor.setAlias(draft, for: aliasKey); editing = false }
                            }
                        }.padding().frame(width: 240)
                    }
                    Text(device.statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if device.percent != nil || device.componentLevels.isEmpty {
                    BatteryGauge(percent: device.percent, readAt: device.readAt, stale: device.stale)
                        .frame(width: device.stale ? 86 : 54)
                }
            }
            if !device.componentLevels.isEmpty {
                HStack(spacing: 16) {
                    ForEach(device.componentLevels, id: \.label) { component in
                        BatteryGauge(percent: component.percent, label: component.label, readAt: component.readAt, stale: component.stale)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .frame(height: Self.height(for: device))
        .contextMenu { Button("编辑设备别名", action: editAlias) }
        .accessibilityElement(children: .contain)
    }
}

private struct BatteryGauge: View {
    let percent: Int?
    var label: String? = nil
    var readAt: Date?
    var stale = false

    var body: some View {
        let level = percent ?? 0
        let color: Color = stale || percent == nil ? .secondary : level < 20 ? .red : level < 50 ? .orange : .green
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 2) {
                if let label {
                    Text(label).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(percent.map { "\($0)%" } ?? "—")
                    .fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
            }
            .font(label == nil ? .title3 : .caption)
            .lineLimit(1)
            Capsule().fill(.secondary.opacity(0.22))
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(color).frame(width: geometry.size.width * CGFloat(level) / 100)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            if let readAt {
                Text((stale ? "上次 " : "") + readAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .help("最后成功读取：" + readAt.formatted())
            }
        }
    }
}
