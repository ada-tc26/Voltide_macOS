import Foundation

func panelTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    let format: Date.FormatString = "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
    return date.formatted(.verbatim(format, locale: Locale(identifier: "en_US_POSIX"),
                                    timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
}

enum ScanSource: String, CaseIterable {
    case registry = "系统 HID", bluetooth = "蓝牙", receiver = "接收器", controller = "手柄"
}

struct ScanBatch {
    let source: ScanSource
    let rows: [Peripheral]?
    let time: Date

    init(_ source: ScanSource, time: Date? = nil, read: () throws -> [Peripheral]) {
        self.source = source
        self.rows = try? read()
        self.time = time ?? Date()
    }
}

struct ReadingHistory {
    static let lifetime: TimeInterval = 15 * 60
    private var snapshots: [ScanSource: [String: Peripheral]] = [:]

    mutating func apply(_ batch: ScanBatch) {
        let previous = snapshots[batch.source] ?? [:]
        let failed = batch.rows == nil
        var next: [String: Peripheral] = [:]
        for var row in batch.rows ?? Array(previous.values) {
            let old = previous[row.id]
            if failed {
                guard let seen = row.lastSeen, batch.time.timeIntervalSince(seen) < Self.lifetime else { continue }
                row.state = "采集失败"
                row.percent = nil
                row.componentLevels = []
                row.charging = nil
            } else { row.lastSeen = batch.time }

            if row.percent != nil {
                row.readAt = batch.time
                row.stale = false
            } else if let old, let date = old.readAt, batch.time.timeIntervalSince(date) < Self.lifetime {
                if batch.source == .receiver, row.state != "已连接" { row.name = old.name }
                row.percent = old.percent
                row.readAt = date
                row.stale = true
            } else {
                row.readAt = nil
                row.stale = false
            }
            for i in row.componentLevels.indices {
                row.componentLevels[i].readAt = batch.time
            }
            for var component in old?.componentLevels ?? [] {
                guard !row.componentLevels.contains(where: { $0.label == component.label }),
                      let date = component.readAt, batch.time.timeIntervalSince(date) < Self.lifetime else { continue }
                component.stale = true
                row.componentLevels.append(component)
            }
            let order = ["左耳", "右耳", "充电盒"]
            row.componentLevels.sort { (order.firstIndex(of: $0.label) ?? 3) < (order.firstIndex(of: $1.label) ?? 3) }
            next[row.id] = row
        }
        snapshots[batch.source] = next
    }

    var devices: [Peripheral] {
        var merged: [String: Peripheral] = [:]
        for source in ScanSource.allCases {
            guard let snapshot = snapshots[source] else { continue }
            for var row in snapshot.values {
                if let existing = merged[row.id] {
                    if let date = existing.readAt, row.readAt == nil || (row.stale && (!existing.stale || date > (row.readAt ?? .distantPast))) {
                        row.percent = existing.percent
                        row.readAt = date
                        row.stale = existing.stale
                    }
                    row.charging = row.charging ?? existing.charging
                    if row.state == "采集失败" && existing.state != "采集失败" { row.state = existing.state }
                    if row.componentLevels.isEmpty { row.componentLevels = existing.componentLevels }
                }
                merged[row.id] = row
            }
        }
        return merged.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
