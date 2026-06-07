//
//  iOSBatteryPreview.swift
//  Stats
//
//  Static module preview for the iOS Battery module (like CPU / RAM).
//
//  Reads the persisted device index from the store and shows every device that has
//  been recorded — connected or not (connected ones first). Each device keeps a stable
//  color; the two history charts group the SAME metric for ALL devices together (one
//  colored line per device) instead of one chart per device.
//

import Cocoa
import Kit

/// Stable palette: a device keeps the same color across reads (assigned by sorted UDID).
private let iOSBatteryDeviceColors: [NSColor] = [
    .systemBlue, .systemRed, .systemGreen, .systemOrange,
    .systemPurple, .systemTeal, .systemPink, .systemYellow,
    .systemIndigo, .systemBrown
]

/// Builds chart points from persisted samples, stamping each point with its real timestamp.
private func historyPoints(_ samples: [iOSBatteryHistorySample], _ map: (iOSBatteryHistorySample) -> Double?) -> [DoubleValue] {
    samples.compactMap { s in
        guard let v = map(s) else { return nil }
        var dv = DoubleValue(v)
        dv.ts = Date(timeIntervalSince1970: s.t)
        return dv
    }
}

/// A device to render in the preview, plus whether it is currently connected and its color.
private struct iOSBatteryPreviewDevice {
    let snapshot: iOSBattery_DeviceSnapshot
    let connected: Bool
    let color: NSColor
}

private enum iOSBatteryRange: Int, CaseIterable {
    case month = 0
    case sixMonths = 1
    case year = 2
    case max = 3

    var title: String {
        switch self {
        case .month: return "1M"
        case .sixMonths: return "6M"
        case .year: return "1Y"
        case .max: return "Max"
        }
    }

    var lookback: TimeInterval {
        switch self {
        case .month: return 30 * 24 * 3600
        case .sixMonths: return 180 * 24 * 3600
        case .year: return 365 * 24 * 3600
        case .max: return .infinity
        }
    }
}

internal final class iOSBatteryPreview: PreviewWrapper {
    private var panels: [String: iOSBatteryDevicePanel] = [:]
    private var signature: [String] = []

    private let cyclesChart = iOSBatteryMultiLineChart(fixedYMax: nil) { "\(Int($0.rounded()))" }
    private let healthChart = iOSBatteryMultiLineChart(fixedYMax: 100) { "\(Int($0.rounded()))%" }

    private let rangeControl: NSSegmentedControl = {
        let c = NSSegmentedControl(
            labels: iOSBatteryRange.allCases.map { $0.title },
            trackingMode: .selectOne, target: nil, action: nil
        )
        c.segmentStyle = .rounded
        c.controlSize = .small
        c.translatesAutoresizingMaskIntoConstraints = false
        return c
    }()
    private var selectedRange: iOSBatteryRange = .month

    public init(_ module: ModuleType) {
        super.init(type: module)
        let saved = Store.shared.int(key: "iOSBattery_rangeIndex", defaultValue: iOSBatteryRange.month.rawValue)
        self.selectedRange = iOSBatteryRange(rawValue: saved) ?? .month
        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.rangeChanged(_:))
        self.rangeControl.selectedSegment = self.selectedRange.rawValue
        
        self.cyclesChart.setLookback(self.selectedRange.lookback)
        self.healthChart.setLookback(self.selectedRange.lookback)
        self.rebuild(devices: [])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let range = iOSBatteryRange(rawValue: sender.selectedSegment) else { return }
        self.selectedRange = range
        Store.shared.set(key: "iOSBattery_rangeIndex", value: range.rawValue)
        self.cyclesChart.setLookback(range.lookback)
        self.healthChart.setLookback(range.lookback)
    }

    private func rangeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Constants.Settings.margin,
            bottom: 0,
            right: Constants.Settings.margin
        )
        row.addArrangedSubview(NSView())          // push the control to the right
        row.addArrangedSubview(self.rangeControl)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    private func getHistorySpan() -> TimeInterval {
        var oldest: Double = Date().timeIntervalSince1970
        for udid in iOSBatteryHistory.knownUDIDs() {
            let samples = iOSBatteryHistory.samples(for: udid)
            if let first = samples.first {
                oldest = min(oldest, first.t)
            }
        }
        return Date().timeIntervalSince1970 - oldest
    }

    private func updateRangeAvailability() {
        let span = self.getHistorySpan()
        for range in iOSBatteryRange.allCases {
            let enabled: Bool
            if range == .month {
                enabled = true
            } else if range == .max {
                enabled = span > iOSBatteryRange.month.lookback
            } else {
                if let prev = iOSBatteryRange(rawValue: range.rawValue - 1) {
                    enabled = span > prev.lookback
                } else {
                    enabled = true
                }
            }
            self.rangeControl.setEnabled(enabled, forSegment: range.rawValue)
        }
        
        var currentRange = self.selectedRange
        if !self.rangeControl.isEnabled(forSegment: currentRange.rawValue) {
            for range in iOSBatteryRange.allCases.reversed() where self.rangeControl.isEnabled(forSegment: range.rawValue) {
                currentRange = range
                break
            }
            self.selectedRange = currentRange
            self.rangeControl.selectedSegment = currentRange.rawValue
            Store.shared.set(key: "iOSBattery_rangeIndex", value: currentRange.rawValue)
            self.cyclesChart.setLookback(currentRange.lookback)
            self.healthChart.setLookback(currentRange.lookback)
        }
    }

    internal func usageCallback(_ value: iOSBattery_Usage) {
        DispatchQueue.main.async {
            let devices = Self.mergedDevices(value)
            // Rebuild only when the set of devices or their connection state changes
            // (a connect/disconnect updates the panel header + ordering).
            let signature = devices.map { "\($0.snapshot.udid ?? "")|\($0.connected)" }
            if signature != self.signature {
                self.rebuild(devices: devices)
            }

            let visible = self.window?.isVisible ?? false
            var cycleSeries: [iOSBatteryMultiLineChart.Series] = []
            var healthSeries: [iOSBatteryMultiLineChart.Series] = []
            for item in devices {
                guard let udid = item.snapshot.udid else { continue }
                let samples = iOSBatteryHistory.samples(for: udid)
                self.panels[udid]?.update(item.snapshot, connected: item.connected, visible: visible)

                let name = item.snapshot.displayName.isEmpty ? localizedString("iOS device") : item.snapshot.displayName
                let cycles = historyPoints(samples) { $0.cycles.map(Double.init) }
                let health = historyPoints(samples) { $0.health }
                if !cycles.isEmpty { cycleSeries.append(.init(name: name, color: item.color, points: cycles)) }
                if !health.isEmpty { healthSeries.append(.init(name: name, color: item.color, points: health)) }
            }
            self.cyclesChart.setLookback(self.selectedRange.lookback)
            self.healthChart.setLookback(self.selectedRange.lookback)
            self.cyclesChart.setSeries(cycleSeries)
            self.healthChart.setSeries(healthSeries)
            self.updateRangeAvailability()
        }
    }

    /// Union of currently-connected devices and every device persisted in the store.
    /// Live snapshots win; devices that aren't connected are reconstructed (stale) from
    /// their stored record. Connected devices are listed first; within each group the
    /// order is stable (by UDID). Colors are assigned by sorted UDID so they don't shift.
    private static func mergedDevices(_ value: iOSBattery_Usage) -> [iOSBatteryPreviewDevice] {
        var live: [String: iOSBattery_DeviceSnapshot] = [:]
        for d in value.connectedDevices {
            guard let udid = d.udid, !udid.isEmpty else { continue }
            live[udid] = d
        }

        var udids = Set(live.keys)
        udids.formUnion(iOSBatteryHistory.knownUDIDs())

        let sortedUDIDs = udids.sorted()
        var colorOf: [String: NSColor] = [:]
        for (i, udid) in sortedUDIDs.enumerated() {
            colorOf[udid] = iOSBatteryDeviceColors[i % iOSBatteryDeviceColors.count]
        }

        let devices: [iOSBatteryPreviewDevice] = sortedUDIDs.compactMap { udid in
            let color = colorOf[udid] ?? .systemBlue
            if let d = live[udid] {
                return iOSBatteryPreviewDevice(snapshot: d, connected: true, color: color)
            }
            guard let rec = iOSBatteryHistory.deviceRecord(for: udid) else { return nil }
            return iOSBatteryPreviewDevice(snapshot: rec.snapshot, connected: false, color: color)
        }

        // Connected first, then disconnected; stable within each group.
        return devices.sorted { a, b in
            if a.connected != b.connected { return a.connected }
            return (a.snapshot.udid ?? "") < (b.snapshot.udid ?? "")
        }
    }

    private func rebuild(devices: [iOSBatteryPreviewDevice]) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.panels.removeAll()
        self.signature = devices.map { "\($0.snapshot.udid ?? "")|\($0.connected)" }

        guard !devices.isEmpty else {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Status"), component: ValueField(frame: .zero, localizedString("No devices recorded")))
            ]))
            self.addArrangedSubview(NSView())
            return
        }

        // One summary section per device (connected first).
        for item in devices {
            guard let udid = item.snapshot.udid, !udid.isEmpty else { continue }
            let panel = iOSBatteryDevicePanel(item.snapshot, connected: item.connected, color: item.color)
            self.panels[udid] = panel
            self.addArrangedSubview(panel.section)
        }

        // Add range selector row
        self.addArrangedSubview(self.rangeRow())

        // Shared per-metric charts: every device on the same chart, one color per device.
        self.addArrangedSubview(PreferencesSection(title: localizedString("Cycle count history"), [chartContainer(self.cyclesChart)]))
        self.addArrangedSubview(PreferencesSection(title: localizedString("Health history"), [chartContainer(self.healthChart)]))
        self.addArrangedSubview(NSView())
    }

    private func chartContainer(_ chart: NSView) -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin*2
        view.heightAnchor.constraint(equalToConstant: 130).isActive = true
        view.addArrangedSubview(chart)
        return view
    }
}

/// Per-device summary: a colored swatch (matching its chart line), battery pie, and metrics.
private final class iOSBatteryDevicePanel {
    let udid: String
    private var initialized: Bool = false

    private let circle = PieChartView(drawValue: true)
    private var chargeField: NSTextField?
    private var healthField: NSTextField?
    private var cyclesField: NSTextField?
    private var chargingField: NSTextField?

    private(set) var section: NSView

    init(_ device: iOSBattery_DeviceSnapshot, connected: Bool, color: NSColor) {
        self.udid = device.udid ?? ""

        self.circle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.circle.heightAnchor.constraint(equalToConstant: 90).isActive = true
        self.circle.toolTip = localizedString("Health")

        let name = device.displayName.isEmpty ? localizedString("iOS device") : device.displayName
        var subtitle = [device.productType, device.productVersion].compactMap { $0 }.joined(separator: " · ")
        if !connected {
            let offline = "\(localizedString("Disconnected")) — \(localizedString("last seen")): \(device.formattedUpdateTime)"
            subtitle = subtitle.isEmpty ? offline : "\(subtitle) · \(offline)"
        }

        let summary = iOSBatteryDevicePanel.summaryView(circle: self.circle, color: color)
        self.chargeField = summary.charge
        self.healthField = summary.health
        self.cyclesField = summary.cycles
        self.chargingField = summary.charging

        self.section = PreferencesSection(title: name, subtitle: subtitle, [summary.view])
    }

    private static func summaryView(circle: PieChartView, color: NSColor) -> (view: NSView, charge: NSTextField, health: NSTextField, cycles: NSTextField, charging: NSTextField) {
        let view = NSStackView()
        view.distribution = .fill
        view.orientation = .horizontal
        view.alignment = .centerY
        view.translatesAutoresizingMaskIntoConstraints = false
        // The pie chart is pinned to a fixed 90x90 (see init); the panel sizes to
        // its tallest column (the 4 detail rows) so no row gets squished.
        view.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        view.spacing = Constants.Settings.margin

        // Color swatch tying this device to its line in the shared charts.
        let swatch = ColorView(frame: NSRect(x: 0, y: 0, width: 6, height: 6), color: color, state: true, radius: 3)
        swatch.widthAnchor.constraint(equalToConstant: 6).isActive = true
        swatch.toolTip = localizedString("Chart color")

        let details = NSStackView()
        details.orientation = .vertical
        details.distribution = .fillEqually
        details.spacing = 2
        let charge = previewRow(details, title: "\(localizedString("Charge")):", value: "—")
        let health = previewRow(details, title: "\(localizedString("Health")):", value: "—")
        let cycles = previewRow(details, title: "\(localizedString("Cycles")):", value: "—")
        let charging = previewRow(details, title: "\(localizedString("Is charging")):", value: "—")

        view.addArrangedSubview(swatch)
        view.addArrangedSubview(circle)
        view.addArrangedSubview(details)
        return (view, charge, health, cycles, charging)
    }

    func update(_ d: iOSBattery_DeviceSnapshot, connected: Bool, visible: Bool) {
        guard visible || !self.initialized else { return }
        let charging = d.isCharging ?? false
        // The circle shows battery health; disconnected devices show their last-known value dimmed.
        let health = (d.healthPercent ?? 0) / 100.0
        let color: NSColor = !connected ? NSColor.systemGray : NSColor.systemGreen
        self.circle.setValue(health)
        self.circle.setSegments([ColorValue(health, color: color)])
        self.circle.toolTip = "\(localizedString("Health")): \(d.formattedHealth)"

        self.chargeField?.stringValue = d.currentCapacityPercent.map { "\($0)%" } ?? "—"
        self.healthField?.stringValue = d.formattedHealth
        self.cyclesField?.stringValue = d.cycleCount.map(String.init) ?? "—"
        self.chargingField?.stringValue = connected ? (charging ? localizedString("Yes") : localizedString("No")) : "—"
        self.initialized = true
    }
}

/// A lightweight multi-series line chart: every series shares one X (real time) and one
/// Y scale, each drawn in its own color, with a color→name legend. Used to show the same
/// metric for all devices on a single chart.
private final class iOSBatteryMultiLineChart: NSView {
    struct Series {
        let name: String
        let color: NSColor
        let points: [DoubleValue]
    }

    private struct Projected {
        let point: CGPoint
        let value: Double
        let date: Date
        let name: String
        let color: NSColor
    }

    private var series: [Series] = []
    private let fixedYMax: Double?
    private let yFormatter: (Double) -> String
    private let axisFormatter = DateFormatter()
    private let tooltipFormatter = DateFormatter()
    private var lookback: TimeInterval = 30 * 24 * 3600

    private var projected: [Projected] = []
    private var hoverLocation: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(fixedYMax: Double?, yFormatter: @escaping (Double) -> String) {
        self.fixedYMax = fixedYMax
        self.yFormatter = yFormatter
        super.init(frame: .zero)
        self.axisFormatter.dateStyle = .short
        self.axisFormatter.timeStyle = .none
        self.tooltipFormatter.dateStyle = .short
        self.tooltipFormatter.timeStyle = .short
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLookback(_ value: TimeInterval) {
        self.lookback = value
        self.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.trackingArea { self.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        self.hoverLocation = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        self.hoverLocation = nil
        self.needsDisplay = true
    }

    func setSeries(_ newValue: [Series]) {
        self.series = newValue.filter { !$0.points.isEmpty }
        self.needsDisplay = true
    }

    private var darkMode: Bool {
        self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        let n = v / mag
        let step: Double = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 5 ? 5 : 10))
        return step * mag
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        let textColor = (self.darkMode ? NSColor.white : NSColor.textColor)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .light)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor.withAlphaComponent(0.5)]

        guard !self.series.isEmpty else {
            let str = localizedString("No history yet") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .light), .foregroundColor: textColor.withAlphaComponent(0.5)]
            let size = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: (self.bounds.width - size.width)/2, y: (self.bounds.height - size.height)/2), withAttributes: attrs)
            return
        }

        let yAxisWidth: CGFloat = 34
        let xAxisHeight: CGFloat = 13
        let legendHeight: CGFloat = 13
        let chartRect = NSRect(
            x: yAxisWidth,
            y: xAxisHeight,
            width: max(1, self.bounds.width - yAxisWidth - 4),
            height: max(1, self.bounds.height - xAxisHeight - legendHeight - 2)
        )

        let allValues = self.series.flatMap { $0.points.map { $0.value } }
        let yMax = max(1, self.fixedYMax ?? self.niceCeil(allValues.max() ?? 1))
        let allTS = self.series.flatMap { $0.points.map { $0.ts.timeIntervalSince1970 } }
        let now = Date().timeIntervalSince1970
        let tMin = self.lookback == .infinity ? (allTS.min() ?? (now - 30 * 24 * 3600)) : (now - self.lookback)
        let tMax = now

        func xFor(_ ts: Double) -> CGFloat { chartRect.minX + CGFloat((ts - tMin) / (tMax - tMin)) * chartRect.width }
        func yFor(_ v: Double) -> CGFloat { chartRect.minY + CGFloat(min(max(v, 0), yMax) / yMax) * chartRect.height }

        // Horizontal grid + y labels.
        let gridColor = (self.darkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.06)
        let hairline = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        for step in [0, 25, 50, 75, 100] {
            let ly = chartRect.minY + CGFloat(step) / 100 * chartRect.height
            gridColor.setStroke()
            let g = NSBezierPath()
            g.move(to: CGPoint(x: chartRect.minX, y: ly))
            g.line(to: CGPoint(x: chartRect.maxX, y: ly))
            g.lineWidth = hairline
            g.stroke()
            (self.yFormatter(yMax * Double(step) / 100) as NSString).draw(at: CGPoint(x: 0, y: ly - 5), withAttributes: labelAttrs)
        }

        let span = tMax - tMin
        let day: Double = 86400
        let minorInterval: Double
        let majorInterval: Double

        if span <= 35 * day {
            minorInterval = day
            majorInterval = 10 * day
        } else if span <= 185 * day {
            minorInterval = 5 * day
            majorInterval = 30 * day
        } else if span <= 370 * day {
            minorInterval = 30 * day
            majorInterval = 90 * day
        } else {
            let totalDays = span / day
            if totalDays <= 730 {
                minorInterval = 30 * day
                majorInterval = 180 * day
            } else {
                minorInterval = 180 * day
                majorInterval = 365 * day
            }
        }

        // Vertical grid lines: Major and Minor.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date(timeIntervalSince1970: tMax)).timeIntervalSince1970
        var t = startOfToday
        while t >= tMin {
            let daysAgo = Int(round((startOfToday - t) / 86400))
            
            let majorDays = Int(round(majorInterval / 86400))
            let minorDays = Int(round(minorInterval / 86400))
            
            let isMajor = daysAgo % majorDays == 0
            let isMinor = daysAgo % minorDays == 0

            let x = xFor(t)
            if x >= chartRect.minX && x <= chartRect.maxX {
                if isMajor || isMinor {
                    let line = NSBezierPath()
                    line.move(to: CGPoint(x: x, y: chartRect.minY))
                    line.line(to: CGPoint(x: x, y: chartRect.maxY))
                    line.lineWidth = hairline

                    if isMajor {
                        (self.darkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.08).setStroke()
                        line.stroke()

                        let str = self.axisFormatter.string(from: Date(timeIntervalSince1970: t)) as NSString
                        let size = str.size(withAttributes: labelAttrs)
                        let lx = max(chartRect.minX, min(x - size.width / 2, self.bounds.width - size.width))
                        str.draw(at: CGPoint(x: lx, y: 0), withAttributes: labelAttrs)
                    } else {
                        (self.darkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.03).setStroke()
                        line.stroke()
                    }
                }
            }
            t -= 86400
        }

        // One line per series.
        self.projected.removeAll()
        for s in self.series {
            let pts = s.points.sorted { $0.ts < $1.ts }
            s.color.setStroke()
            s.color.setFill()

            for p in pts {
                self.projected.append(Projected(
                    point: CGPoint(x: xFor(p.ts.timeIntervalSince1970), y: yFor(p.value)),
                    value: p.value,
                    date: p.ts,
                    name: s.name,
                    color: s.color
                ))
            }

            if pts.count == 1 {
                let p = CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value))
                NSBezierPath(ovalIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value)))
            for p in pts.dropFirst() {
                path.line(to: CGPoint(x: xFor(p.ts.timeIntervalSince1970), y: yFor(p.value)))
            }
            path.lineWidth = max(hairline, 1)
            path.lineJoinStyle = .round
            path.stroke()
        }

        // Legend: color swatch + device name, left to right, until we run out of width.
        let legendAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor.withAlphaComponent(0.8)]
        let swatch: CGFloat = 7
        let legendY = self.bounds.height - legendHeight
        var lx = chartRect.minX
        for s in self.series {
            guard lx < self.bounds.width - 24 else { break }
            s.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: lx, y: legendY + (legendHeight - swatch) / 2, width: swatch, height: swatch), xRadius: 1.5, yRadius: 1.5).fill()
            lx += swatch + 4
            let name = s.name as NSString
            let size = name.size(withAttributes: legendAttrs)
            name.draw(at: CGPoint(x: lx, y: legendY + (legendHeight - size.height) / 2), withAttributes: legendAttrs)
            lx += size.width + 12
        }

        self.drawHoverTooltip(chartRect: chartRect, textColor: textColor)
    }

    private func drawHoverTooltip(chartRect: NSRect, textColor: NSColor) {
        guard let loc = self.hoverLocation else { return }

        // Find nearest projected point to the cursor (weighting X coordinate heavier so hover feels natural).
        var nearestPoint: Projected?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in self.projected {
            let dx = p.point.x - loc.x
            let dy = p.point.y - loc.y
            let dist = dx * dx * 2 + dy * dy
            if dist < bestDist {
                bestDist = dist
                nearestPoint = p
            }
        }

        guard let hit = nearestPoint, abs(hit.point.x - loc.x) < 40 else { return }

        // Draw a highlighted dot on the hovered point
        hit.color.setFill()
        NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5)).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5))
        ring.lineWidth = 1
        ring.stroke()

        let formattedVal = self.yFormatter(hit.value)
        let formattedDate = self.tooltipFormatter.string(from: hit.date)
        let text = "\(hit.name) · \(formattedVal) · \(formattedDate)"
        self.drawTooltipBox(text, anchorX: hit.point.x, anchorY: hit.point.y, textColor: textColor)
    }

    private func drawTooltipBox(_ text: String, anchorX: CGFloat, anchorY: CGFloat, textColor: NSColor) {
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: textColor
        ]
        let textSize = ns.size(withAttributes: attrs)
        let padding: CGFloat = 5
        let boxW = textSize.width + padding * 2
        let boxH = textSize.height + padding
        var boxX = anchorX + 8
        if boxX + boxW > self.bounds.width { boxX = anchorX - 8 - boxW }
        var boxY = anchorY + 8
        if boxY + boxH > self.bounds.height { boxY = anchorY - 8 - boxH }
        boxX = max(0, boxX)
        boxY = max(0, boxY)

        let box = NSBezierPath(roundedRect: NSRect(x: boxX, y: boxY, width: boxW, height: boxH), xRadius: 4, yRadius: 4)
        (self.darkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.9).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        box.stroke()
        ns.draw(at: CGPoint(x: boxX + padding, y: boxY + padding / 2), withAttributes: attrs)
    }
}
