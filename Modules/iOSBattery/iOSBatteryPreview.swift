//
//  iOSBatteryPreview.swift
//  Stats
//
//  Static module preview for the iOS Battery module (like CPU / RAM).
//  Renders one panel per connected device, each with persisted
//  cycle-count and health history.
//

import Cocoa
import Kit

/// Builds chart points from persisted samples, stamping each point with its real timestamp.
/// A single sample is duplicated so a flat line is drawn instead of a lone dot.
fileprivate func historyPoints(_ samples: [iOSBatteryHistorySample], _ map: (iOSBatteryHistorySample) -> Double?) -> [DoubleValue] {
    let pts: [DoubleValue] = samples.compactMap { s in
        guard let v = map(s) else { return nil }
        var dv = DoubleValue(v)
        dv.ts = Date(timeIntervalSince1970: s.t)
        return dv
    }
    return pts.count == 1 ? [pts[0], pts[0]] : pts
}

internal final class iOSBatteryPreview: PreviewWrapper {
    private var panels: [String: iOSBatteryDevicePanel] = [:]
    private var orderedUDIDs: [String] = []

    public init(_ module: ModuleType) {
        super.init(type: module)
        self.rebuild(devices: [])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func usageCallback(_ value: iOSBattery_Usage) {
        DispatchQueue.main.async {
            // Stable order so the panels don't reshuffle between reads (reader returns them unordered).
            let devices = value.connectedDevices.sorted { ($0.udid ?? "") < ($1.udid ?? "") }
            let udids = devices.compactMap { $0.udid }.filter { !$0.isEmpty }

            if udids != self.orderedUDIDs {
                self.rebuild(devices: devices)
            }

            let visible = self.window?.isVisible ?? false
            for d in devices {
                guard let udid = d.udid, let panel = self.panels[udid] else { continue }
                panel.update(d, samples: iOSBatteryHistory.samples(for: udid), visible: visible)
            }
        }
    }

    private func rebuild(devices: [iOSBattery_DeviceSnapshot]) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.panels.removeAll()
        self.orderedUDIDs = devices.compactMap { $0.udid }.filter { !$0.isEmpty }

        guard !self.orderedUDIDs.isEmpty else {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Status"), component: ValueField(frame: .zero, localizedString("No devices connected")))
            ]))
            self.addArrangedSubview(NSView())
            return
        }

        for d in devices {
            guard let udid = d.udid, !udid.isEmpty else { continue }
            let panel = iOSBatteryDevicePanel(d)
            self.panels[udid] = panel
            panel.sections.forEach { self.addArrangedSubview($0) }
        }
        self.addArrangedSubview(NSView())
    }
}

/// Per-device preview: a battery summary plus cycle-count and health history charts.
private final class iOSBatteryDevicePanel {
    let udid: String
    private var initialized: Bool = false

    private let circle = PieChartView(drawValue: true)
    private var chargeField: NSTextField?
    private var healthField: NSTextField?
    private var cyclesField: NSTextField?
    private var chargingField: NSTextField?

    private let cyclesChart = LineChartView(num: 1000)
    private let healthChart = LineChartView(num: 1000)

    private(set) var sections: [NSView] = []

    init(_ device: iOSBattery_DeviceSnapshot) {
        self.udid = device.udid ?? ""

        self.circle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.circle.toolTip = localizedString("Battery")

        // Cycle counts are absolute: keep the y-axis (consistent with the health chart) but
        // label it with real cycle numbers derived from the data max instead of percentages.
        self.cyclesChart.setColor(NSColor.systemOrange)
        self.cyclesChart.setLegend(x: true, y: true)
        self.cyclesChart.setYLegendFormatter { "\(Int($0.rounded()))" }
        self.cyclesChart.setToolTipFunc { "\(Int($0.value.rounded())) \(localizedString("cycles"))" }

        self.healthChart.setColor(NSColor.systemGreen)
        self.healthChart.setLegend(x: true, y: true)

        let name = device.displayName.isEmpty ? localizedString("iOS device") : device.displayName
        let subtitle = [device.productType, device.productVersion].compactMap { $0 }.joined(separator: " · ")

        self.sections = [
            PreferencesSection(title: name, subtitle: subtitle, [self.summaryView()]),
            PreferencesSection(title: localizedString("Cycle count history"), [self.chartContainer(self.cyclesChart)]),
            PreferencesSection(title: localizedString("Health history"), [self.chartContainer(self.healthChart)])
        ]
    }

    private func summaryView() -> NSView {
        let view = NSStackView()
        view.distribution = .fill
        view.orientation = .horizontal
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 90).isActive = true
        view.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        view.spacing = Constants.Settings.margin

        let details = NSStackView()
        details.orientation = .vertical
        details.distribution = .fillEqually
        details.spacing = 2
        self.chargeField = previewRow(details, title: "\(localizedString("Charge")):", value: "—")
        self.healthField = previewRow(details, title: "\(localizedString("Health")):", value: "—")
        self.cyclesField = previewRow(details, title: "\(localizedString("Cycles")):", value: "—")
        self.chargingField = previewRow(details, title: "\(localizedString("Is charging")):", value: "—")

        view.addArrangedSubview(self.circle)
        view.addArrangedSubview(details)
        return view
    }

    private func chartContainer(_ chart: LineChartView) -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin*2
        view.heightAnchor.constraint(equalToConstant: 120).isActive = true
        view.addArrangedSubview(chart)
        return view
    }

    func update(_ d: iOSBattery_DeviceSnapshot, samples: [iOSBatteryHistorySample], visible: Bool) {
        if visible || !self.initialized {
            let percent = Double(d.currentCapacityPercent ?? 0) / 100.0
            let charging = d.isCharging ?? false
            self.circle.setValue(percent)
            self.circle.setSegments([ColorValue(percent, color: charging ? NSColor.systemGreen : NSColor.systemBlue)])
            self.circle.toolTip = "\(localizedString("Battery")): \(d.currentCapacityPercent.map { "\($0)%" } ?? "—")"

            self.chargeField?.stringValue = d.currentCapacityPercent.map { "\($0)%" } ?? "—"
            self.healthField?.stringValue = d.formattedHealth
            self.cyclesField?.stringValue = d.cycleCount.map(String.init) ?? "—"
            self.chargingField?.stringValue = charging ? localizedString("Yes") : localizedString("No")
            self.initialized = true
        }

        // Charts reflect the persisted history regardless of window visibility.
        self.cyclesChart.setPoints(historyPoints(samples) { $0.cycles.map(Double.init) })
        self.healthChart.setPoints(historyPoints(samples) { $0.health.map { $0 / 100.0 } })
    }
}
