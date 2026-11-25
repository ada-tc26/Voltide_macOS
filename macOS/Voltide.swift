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

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = Monitor()
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    private var anchor = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "battery.100percent.bolt", accessibilityDescription: "Voltide 外设电量")
        button.toolTip = "Voltide 外设电量"
        button.target = self
        button.action = #selector(togglePanel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.close(); return }
        guard let button = item.button, let window = button.window, let screen = window.screen else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let width: CGFloat = 344
        let left = max(screen.frame.minX + 4, min(anchor.midX - width / 2, screen.frame.maxX - width - 4))
        let shape = PanelOutline(tipX: anchor.midX - left)
        let content = BatteryPanel(monitor: monitor)
            .padding(.top, PanelOutline.tipHeight)
            .background { PanelBackdrop(shape: shape) }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.position(size: size, left: left)
            }
        let host = NSHostingView(rootView: content.fixedSize())
        panel.contentView = host
        position(size: host.fittingSize, left: left)
        panel.makeKeyAndOrderFront(nil)
        monitor.panelVisible(true)
    }

    private func position(size: CGSize, left: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        panel.setFrame(NSRect(x: left, y: anchor.minY - size.height, width: size.width, height: size.height),
                       display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) { panel.close() }
    func windowWillClose(_ notification: Notification) { monitor.panelVisible(false) }
}

private struct PanelOutline: Shape {
    static let tipHeight: CGFloat = 9
    let tipX: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: 0, y: Self.tipHeight, width: rect.width, height: rect.height - Self.tipHeight)
        let r: CGFloat = 19
        let x = min(max(28, tipX), rect.width - 28)
        var path = Path()
        path.move(to: CGPoint(x: r, y: body.minY))
        path.addLine(to: CGPoint(x: x - 11, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: x - 3, y: 2), control: CGPoint(x: x - 8, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: x + 3, y: 2), control: CGPoint(x: x, y: -1))
        path.addQuadCurve(to: CGPoint(x: x + 11, y: body.minY), control: CGPoint(x: x + 8, y: body.minY))
        let topRight = CGPoint(x: body.maxX, y: body.minY)
        let bottomRight = CGPoint(x: body.maxX, y: body.maxY)
        let bottomLeft = CGPoint(x: body.minX, y: body.maxY)
        let topLeft = CGPoint(x: body.minX, y: body.minY)
        path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: r)
        path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: r)
        path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: r)
        path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: r)
        path.closeSubpath()
        return path
    }
}

private struct PanelBackdrop: View {
    let shape: PanelOutline
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
        else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

struct BatteryPanel: View {
    @ObservedObject var monitor: Monitor
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("外设电量").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button { monitor.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 22)
                }
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
                } label: { Image(systemName: "gearshape").frame(width: 22, height: 20) }
                .menuStyle(.button).buttonStyle(.glass).fixedSize().accessibilityLabel("更多选项").help("更多选项")
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
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
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
