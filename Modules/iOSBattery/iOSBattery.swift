//
//  iOSBattery.swift
//  Stats
//
//  Reads connected iOS devices via pymobiledevice3 (Python).
//

import Cocoa
import Kit

/// Synthetic UDID for install / error status rows (not a connected device).
let iOSBatteryStatusUDID = "__ios_battery_status__"

/// One connected iOS device snapshot (USB or Wi‑Fi).
struct iOSBattery_DeviceSnapshot: Codable {
    var deviceName: String? = nil
    var productType: String? = nil
    var productVersion: String? = nil
    var udid: String? = nil
    /// e.g. "Cable", "Wi‑Fi sync"
    var connection: String? = nil
    
    var currentCapacityPercent: Int? = nil
    var isCharging: Bool? = nil
    var cycleCount: Int? = nil
    
    var temperatureC: Double? = nil
    var virtualTemperatureC: Double? = nil
    var voltageMV: Int? = nil
    
    var designCapacityMAh: Int? = nil
    var appleRawMaxCapacityMAh: Int? = nil
    var nominalChargeCapacityMAh: Int? = nil
    /// Battery health % from diagnostics (`BatteryHealthMetric`) when reported as 0–100.
    var fullChargeCapacityPercent: Int? = nil
    /// Health % from Python bridge (`BatteryHealthPercent`), may include decimals.
    var batteryHealthPercent: Double? = nil
    
    var serial: String? = nil
    var manufacturer: String? = nil
    var manufacturerDataHex: String? = nil
    
    var updateTime: Double? = nil
    
    /// All capacity-related diagnostics keys → display string (raw key names in UI).
    var capacityFields: [String: String] = [:]
    var manufactureDateRaw: String? = nil
    var manufactureDateDecoded: String? = nil
    var dateOfFirstUseRaw: String? = nil
    var dateOfFirstUseDecoded: String? = nil
    
    /// Human-readable issue when lockdown/diagnostics could not be read completely.
    var lastError: String? = nil
    
    /// True when values are from the last successful read (device temporarily unreachable).
    var isStale: Bool = false
    
    /// Battery health % — full-charge mAh vs `designCapacityMAh` (same as iOS “maximum capacity”).
    var healthPercent: Double? {
        if let h = batteryHealthPercent, h > 0, h <= 100 { return h }
        guard let design = designCapacityMAh, design > 100 else {
            if let fcc = fullChargeCapacityPercent, (1...100).contains(fcc) { return Double(fcc) }
            return nil
        }
        let maxCap = appleRawMaxCapacityMAh ?? nominalChargeCapacityMAh
        guard let maxCap, maxCap > 0 else {
            if let fcc = fullChargeCapacityPercent, (1...100).contains(fcc) { return Double(fcc) }
            return nil
        }
        return min(100.0, Double(maxCap) / Double(design) * 100.0)
    }
    
    var formattedHealth: String {
        guard let health = healthPercent else { return "—" }
        let pct = health.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f%%", health)
            : String(format: "%.2f%%", health)
        guard let design = designCapacityMAh else { return pct }
        let maxCap = appleRawMaxCapacityMAh ?? nominalChargeCapacityMAh
        if let maxCap {
            return "\(pct) (\(maxCap)/\(design) mAh)"
        }
        return "\(pct) (design \(design) mAh)"
    }
    
    mutating func mergeFrom(_ newer: iOSBattery_DeviceSnapshot) {
        if let v = newer.deviceName { deviceName = v }
        if let v = newer.productType { productType = v }
        if let v = newer.productVersion { productVersion = v }
        if let v = newer.udid { udid = v }
        if let v = newer.connection { connection = v }
        if let v = newer.currentCapacityPercent { currentCapacityPercent = v }
        if let v = newer.isCharging { isCharging = v }
        if let v = newer.cycleCount { cycleCount = v }
        if let v = newer.temperatureC { temperatureC = v }
        if let v = newer.virtualTemperatureC { virtualTemperatureC = v }
        if let v = newer.voltageMV { voltageMV = v }
        if let v = newer.designCapacityMAh { designCapacityMAh = v }
        if let v = newer.appleRawMaxCapacityMAh { appleRawMaxCapacityMAh = v }
        if let v = newer.nominalChargeCapacityMAh { nominalChargeCapacityMAh = v }
        if let v = newer.fullChargeCapacityPercent { fullChargeCapacityPercent = v }
        if let v = newer.batteryHealthPercent { batteryHealthPercent = v }
        if let v = newer.serial { serial = v }
        if let v = newer.manufacturer { manufacturer = v }
        if let v = newer.manufacturerDataHex { manufacturerDataHex = v }
        if let v = newer.updateTime { updateTime = v }
        if !newer.capacityFields.isEmpty { capacityFields = newer.capacityFields }
        if let v = newer.manufactureDateRaw { manufactureDateRaw = v }
        if let v = newer.manufactureDateDecoded { manufactureDateDecoded = v }
        if let v = newer.dateOfFirstUseRaw { dateOfFirstUseRaw = v }
        if let v = newer.dateOfFirstUseDecoded { dateOfFirstUseDecoded = v }
        if let v = newer.lastError, !v.isEmpty { lastError = v }
        isStale = newer.isStale
    }
    
    /// Best label for UI — never generic "Unknown" when we have any identifier.
    var displayName: String {
        if let name = deviceName, !name.isEmpty { return name }
        if let type = productType, !type.isEmpty { return type }
        if let udid, !udid.isEmpty {
            return udid.count > 12 ? String(udid.prefix(8)) + "…" : udid
        }
        return ""
    }
    
    var isIdentified: Bool { !displayName.isEmpty }
    
    /// True when this row is a status message, not a real iOS device.
    var isStatusRow: Bool { udid == iOSBatteryStatusUDID }
    
    /// True when the device has a real UDID from lockdown (show full popup).
    var isConnectedDevice: Bool {
        guard let udid, !udid.isEmpty, udid != iOSBatteryStatusUDID else { return false }
        return true
    }
    
    var formattedVirtualTemperature: String {
        guard let t = virtualTemperatureC else { return "—" }
        return "\(temperature(t, fractionDigits: 1))"
    }
    
    var formattedManufactureDate: String {
        if let decoded = manufactureDateDecoded, !decoded.isEmpty {
            return decoded
        }
        return manufactureDateRaw ?? "—"
    }
    
    var formattedDateOfFirstUse: String {
        if let decoded = dateOfFirstUseDecoded, !decoded.isEmpty {
            return decoded
        }
        return dateOfFirstUseRaw ?? "—"
    }
    
    var formattedUpdateTime: String {
        guard let t = updateTime else { return "—" }
        if t > 1_000_000_000 {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            return f.string(from: Date(timeIntervalSince1970: t))
        }
        return String(format: "%.0f", t)
    }
}

/// Reader intervals for iOS Battery (includes long refresh for pymobiledevice3).
/// IOPMPowerSource / BatteryData capacity keys (displayed with exact names in UI).
let iOSBatteryCapacityFieldKeys: [String] = [
    "AbsoluteCapacity",
    "AppleRawCurrentCapacity",
    "AppleRawMaxCapacity",
    "CurrentCapacity",
    "DesignCapacity",
    "MaxCapacity",
    "NominalChargeCapacity",
    "TimeRemaining",
    "TrueRemainingCapacity"
]

let iOSBatteryHiddenCapacityKeys: Set<String> = ["Dod0AtQualifiedQmax", "FccComp1", "FccComp2", "Qmax"]

func iOSBatteryFormatCapacityValue(key: String, raw: String?) -> String {
    guard let raw, raw != "—" else { return "—" }
    if key == "TimeRemaining", let minutes = Int(raw.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") {
        if (0...9999).contains(minutes) {
            return "\(minutes) min"
        }
        return "\(raw) (unexpected; may be invalid)"
    }
    return raw
}

let iOSBatteryUpdateIntervals: [KeyValue_t] = ReaderUpdateIntervals + [
    KeyValue_t(key: "3600", value: "1 hr"),
    KeyValue_t(key: "21600", value: "6 hr"),
    KeyValue_t(key: "43200", value: "12 hr"),
    KeyValue_t(key: "86400", value: "24 hr")
]

/// Aggregate reader value: one entry per discovered device.
struct iOSBattery_Usage: Codable {
    var devices: [iOSBattery_DeviceSnapshot]
    
    init(devices: [iOSBattery_DeviceSnapshot] = []) {
        self.devices = devices
    }
    
    var connectedDevices: [iOSBattery_DeviceSnapshot] {
        devices.filter(\.isConnectedDevice)
    }
    
    /// Prefer a named device with battery data, then any identified device.
    var primaryDevice: iOSBattery_DeviceSnapshot? {
        let connected = connectedDevices
        if let d = connected.first(where: { $0.isIdentified && $0.currentCapacityPercent != nil }) { return d }
        if let d = connected.first(where: { $0.isIdentified }) { return d }
        if let d = connected.first(where: { $0.currentCapacityPercent != nil }) { return d }
        return connected.first
    }
}

// MARK: - Settings (module tab)

internal final class iOSBatterySettings: NSStackView, Settings_v {
    private let module: ModuleType
    private var lastUsage: iOSBattery_Usage?
    private var updateIntervalValue: Int = 30
    
    public var setInterval: ((_ value: Int) -> Void) = { _ in }
    public var refreshNow: (() -> Void) = { }
    /// Called from `load(widgets:)` to pull the reader's latest cached value.
    public var syncFromReader: (() -> iOSBattery_Usage?)? = nil

    public init(_ module: ModuleType) {
        self.module = module
        self.updateIntervalValue = Store.shared.int(key: "\(module.stringValue)_updateInterval", defaultValue: self.updateIntervalValue)
        super.init(frame: .zero)
        
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        self.alignment = .width
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        if let usage = self.syncFromReader?() {
            self.lastUsage = usage
        }
        self.rebuildOnMain()
    }
    
    func apply(_ usage: iOSBattery_Usage) {
        self.lastUsage = usage
        self.rebuildOnMain()
    }
    
    private func rebuildOnMain() {
        let work: () -> Void = { [weak self] in
            self?.rebuild()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    private func rebuild() {
        self.subviews.forEach { $0.removeFromSuperview() }

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: self.intervalAndRefreshRow())
        ]))
        
        guard let usage = self.lastUsage else {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(
                    localizedString("Status"),
                    component: ValueField(frame: .zero, localizedString("Waiting for first read…"))
                )
            ]))
            return
        }
        
        let connected = usage.connectedDevices
        if connected.isEmpty {
            let status = usage.devices.first(where: \.isStatusRow)?.lastError
            let text = (status?.isEmpty == false) ? status! : localizedString("No devices connected")
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(
                    localizedString("Status"),
                    component: self.valueMultiline(text)
                )
            ]))
            return
        }
        
        for (index, d) in connected.enumerated() {
            let header = d.displayName.isEmpty ? "Device \(index + 1)" : d.displayName
            let subtitle = [d.productType, d.productVersion].compactMap { $0 }.joined(separator: " · ")
            
            var rows: [PreferencesRow] = []
            rows.append(PreferencesRow("UDID", component: self.valueMultiline(d.udid ?? "—")))
            rows.append(PreferencesRow(localizedString("Name"), component: ValueField(frame: .zero, d.deviceName ?? "—")))
            rows.append(PreferencesRow(localizedString("Type"), component: ValueField(frame: .zero, d.productType ?? "—")))
            rows.append(PreferencesRow(localizedString("iOS Version"), component: ValueField(frame: .zero, d.productVersion ?? "—")))
            rows.append(PreferencesRow(localizedString("Connection"), component: ValueField(frame: .zero, d.connection ?? "—")))
            rows.append(PreferencesRow(localizedString("Charge"), component: ValueField(frame: .zero, d.currentCapacityPercent.map { "\($0)%" } ?? "—")))
            rows.append(PreferencesRow(localizedString("Is charging"), component: ValueField(frame: .zero, self.yesNo(d.isCharging))))
            rows.append(PreferencesRow(localizedString("Cycles"), component: ValueField(frame: .zero, d.cycleCount.map(String.init) ?? "—")))
            rows.append(PreferencesRow(localizedString("Health"), component: ValueField(frame: .zero, d.formattedHealth)))
            rows.append(PreferencesRow(localizedString("Temperature"), component: ValueField(frame: .zero, self.tempString(d))))
            rows.append(PreferencesRow("Virtual temperature", component: ValueField(frame: .zero, d.formattedVirtualTemperature)))
            rows.append(PreferencesRow(localizedString("Voltage"), component: ValueField(frame: .zero, d.voltageMV.map { "\($0) mV" } ?? "—")))
            rows.append(PreferencesRow("Manufacturer", component: ValueField(frame: .zero, d.manufacturer ?? "—")))
            rows.append(PreferencesRow("ManufactureDate", component: ValueField(frame: .zero, d.formattedManufactureDate)))
            rows.append(PreferencesRow("DateOfFirstUse", component: ValueField(frame: .zero, d.formattedDateOfFirstUse)))
            rows.append(PreferencesRow("Serial", component: ValueField(frame: .zero, d.serial ?? "—")))
            for key in iOSBatteryCapacityFieldKeys {
                let value = iOSBatteryFormatCapacityValue(key: key, raw: d.capacityFields[key])
                rows.append(PreferencesRow(key, component: ValueField(frame: .zero, value)))
            }
            for key in d.capacityFields.keys.sorted()
                where !iOSBatteryCapacityFieldKeys.contains(key) && !iOSBatteryHiddenCapacityKeys.contains(key) {
                let value = iOSBatteryFormatCapacityValue(key: key, raw: d.capacityFields[key])
                rows.append(PreferencesRow(key, component: ValueField(frame: .zero, value)))
            }
            rows.append(PreferencesRow("UpdateTime", component: ValueField(frame: .zero, d.formattedUpdateTime)))
            if let err = d.lastError, !err.isEmpty {
                rows.append(PreferencesRow(localizedString("Diagnostics"), component: self.valueMultiline(err)))
            }
            
            self.addArrangedSubview(PreferencesSection(title: header, subtitle: subtitle, rows))
        }
    }
    
    private func valueMultiline(_ text: String) -> NSView {
        let v = ValueField(frame: .zero, text)
        v.cell?.usesSingleLineMode = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }
    
    private func yesNo(_ v: Bool?) -> String {
        guard let v else { return "—" }
        return v ? localizedString("Yes") : localizedString("No")
    }
    
    private func intervalAndRefreshRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let select = selectView(
            action: #selector(self.changeUpdateInterval(_:)),
            items: iOSBatteryUpdateIntervals,
            selected: "\(self.updateIntervalValue)"
        )
        select.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let refresh = buttonView(#selector(self.refreshClicked(_:)), text: localizedString("Refresh"))
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(select)
        row.addArrangedSubview(refresh)
        return row
    }
    
    private func tempString(_ d: iOSBattery_DeviceSnapshot) -> String {
        guard let t = d.temperatureC else { return "—" }
        return "\(temperature(t, fractionDigits: 1))"
    }
    
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.module.stringValue)_updateInterval", value: value)
        self.setInterval(value)
    }
    
    @objc private func refreshClicked(_ sender: NSButton) {
        self.refreshNow()
    }
}

// MARK: - Python management (top-level "Python" tab)

internal final class iOSBatteryPythonSettings: NSStackView, Settings_v {
    /// Set by the module to trigger a fresh reader read after install / switch.
    public var refreshNow: (() -> Void) = { }

    private var pythonStatus: IOBatteryPy.EnvironmentStatus?
    private var pythonBusy: Bool = false
    private var pythonLog: String = ""
    private weak var pythonLogField: ValueField?

    public init(_ module: ModuleType) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        self.alignment = .width
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func load(widgets: [widget_t]) {
        if self.pythonStatus == nil && !self.pythonBusy {
            self.scanPython()
        } else {
            self.rebuildOnMain()
        }
    }

    private func rebuildOnMain() {
        if Thread.isMainThread {
            self.rebuild()
        } else {
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
        }
    }

    private func rebuild() {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.buildPythonTab()
    }

    private func valueMultiline(_ text: String) -> NSView {
        let v = ValueField(frame: .zero, text)
        v.cell?.usesSingleLineMode = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func buildPythonTab() {
        // Status
        var statusRows: [PreferencesRow] = []
        if let s = self.pythonStatus {
            let stateText: String
            if let v = s.moduleVersion {
                stateText = "\(localizedString("Installed")) (pymobiledevice3 \(v))"
            } else {
                stateText = localizedString("Not installed")
            }
            statusRows.append(PreferencesRow("pymobiledevice3", component: ValueField(frame: .zero, stateText)))
            let active = s.active.map { d in d.path + (d.version.map { " (Python \($0))" } ?? "") } ?? "—"
            statusRows.append(PreferencesRow(localizedString("Active Python"), component: self.valueMultiline(active)))
        } else {
            statusRows.append(PreferencesRow(localizedString("Status"), component: ValueField(frame: .zero, localizedString("Scanning…"))))
        }
        self.addArrangedSubview(PreferencesSection(statusRows))

        // Managed install / uninstall
        self.addArrangedSubview(PreferencesSection(title: localizedString("Managed environment"), [
            PreferencesRow(
                localizedString("Private install"),
                localizedString("Isolated env; system Python untouched."),
                component: self.managedActionsRow()
            )
        ]))

        // Detected interpreters — install into / use / remove on any Python on this Mac.
        if let s = self.pythonStatus, !s.detected.isEmpty {
            let rows = s.detected.map { self.detectedRow($0) }
            self.addArrangedSubview(PreferencesSection(title: localizedString("Detected Python environments"), rows))
        }
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Detection"), component: {
                let b = self.buttonView(#selector(self.rescanClicked(_:)), text: localizedString("Rescan"))
                b.isEnabled = !self.pythonBusy
                return b
            }())
        ]))

        // Log
        if self.pythonBusy || !self.pythonLog.isEmpty {
            self.addArrangedSubview(PreferencesSection(title: localizedString("Log"), [
                PreferencesRow(component: self.logComponent())
            ]))
        }
    }

    private func managedActionsRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let installed = self.pythonStatus?.hasManaged ?? IOBatteryPy.hasManagedVenv
        let install = self.buttonView(#selector(self.installManagedClicked(_:)), text: installed ? localizedString("Reinstall") : localizedString("Install"))
        install.isEnabled = !self.pythonBusy
        install.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(install)

        if installed {
            let remove = self.buttonView(#selector(self.uninstallManagedClicked(_:)), text: localizedString("Uninstall"))
            remove.isEnabled = !self.pythonBusy
            remove.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(remove)
        }

        if self.pythonBusy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            row.addArrangedSubview(spinner)
        }
        return row
    }

    private func detectedRow(_ env: IOBatteryPy.DetectedPython) -> PreferencesRow {
        let right = NSStackView()
        right.orientation = .horizontal
        right.spacing = 8
        right.alignment = .centerY

        right.addArrangedSubview(ValueField(frame: .zero, env.hasModule ? localizedString("pymobiledevice3 ✓") : "—"))
        if env.hasModule {
            if env.isActive {
                right.addArrangedSubview(ValueField(frame: .zero, localizedString("Active")))
            } else {
                let use = self.buttonView(#selector(self.useEnvClicked(_:)), text: localizedString("Use"))
                use.identifier = NSUserInterfaceItemIdentifier(env.path)
                use.isEnabled = !self.pythonBusy
                use.setContentHuggingPriority(.required, for: .horizontal)
                right.addArrangedSubview(use)
            }
            if !env.isManaged {
                let remove = self.buttonView(#selector(self.removeEnvClicked(_:)), text: localizedString("Remove"))
                remove.identifier = NSUserInterfaceItemIdentifier(env.path)
                remove.isEnabled = !self.pythonBusy
                remove.setContentHuggingPriority(.required, for: .horizontal)
                right.addArrangedSubview(remove)
            }
        } else {
            let install = self.buttonView(#selector(self.installHereClicked(_:)), text: localizedString("Install here"))
            install.identifier = NSUserInterfaceItemIdentifier(env.path)
            install.isEnabled = !self.pythonBusy
            install.setContentHuggingPriority(.required, for: .horizontal)
            right.addArrangedSubview(install)
        }

        let title = env.version.map { "Python \($0)" } ?? "Python"
        return PreferencesRow(title, env.path, component: right)
    }

    private func logComponent() -> NSView {
        let v = ValueField(frame: .zero, self.pythonLog.isEmpty ? localizedString("Working…") : self.pythonLog)
        v.cell?.usesSingleLineMode = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.pythonLogField = v
        return v
    }

    private func appendLog(_ chunk: String) {
        self.pythonLog += chunk
        if self.pythonLog.count > 8000 {
            self.pythonLog = String(self.pythonLog.suffix(8000))
        }
        self.pythonLogField?.stringValue = self.pythonLog
    }

    private func scanPython() {
        self.pythonBusy = true
        self.rebuild()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = IOBatteryPy.environmentStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pythonStatus = status
                self.pythonBusy = false
                self.rebuild()
            }
        }
    }

    private func startInstall(_ target: IOBatteryPy.InstallTarget) {
        guard !self.pythonBusy else { return }
        self.pythonBusy = true
        self.pythonLog = ""
        self.rebuild()
        IOBatteryPy.install(into: target, onProgress: { [weak self] chunk in
            DispatchQueue.main.async { self?.appendLog(chunk) }
        }, completion: { [weak self] ok, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendLog("\n" + message + "\n")
                self.pythonBusy = false
                self.scanPython()
                if ok { self.refreshNow() }
            }
        })
    }

    private func startUninstall(_ target: IOBatteryPy.InstallTarget) {
        guard !self.pythonBusy else { return }
        self.pythonBusy = true
        self.rebuild()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (_, message) = IOBatteryPy.uninstall(from: target)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pythonLog = message
                self.pythonBusy = false
                self.scanPython()
            }
        }
    }

    @objc private func rescanClicked(_ sender: NSButton) {
        guard !self.pythonBusy else { return }
        self.scanPython()
    }

    @objc private func installManagedClicked(_ sender: NSButton) {
        self.startInstall(.managed)
    }

    @objc private func uninstallManagedClicked(_ sender: NSButton) {
        self.startUninstall(.managed)
    }

    @objc private func installHereClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        self.startInstall(.interpreter(path))
    }

    @objc private func removeEnvClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        self.startUninstall(.interpreter(path))
    }

    @objc private func useEnvClicked(_ sender: NSButton) {
        guard !self.pythonBusy, let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        IOBatteryPy.setActivePython(path)
        self.scanPython()
        self.refreshNow()
    }
}

public final class iOSBattery: Module {
    private let popupView: iOSBatteryPopup
    private let portalView: iOSBatteryPortal
    private let settingsContent: iOSBatterySettings
    private let pythonSettingsContent: iOSBatteryPythonSettings

    private var usageReader: iOSBatteryReader? = nil

    public init() {
        self.popupView = iOSBatteryPopup(.iOSBattery)
        self.portalView = iOSBatteryPortal(.iOSBattery)
        self.settingsContent = iOSBatterySettings(.iOSBattery)
        self.pythonSettingsContent = iOSBatteryPythonSettings(.iOSBattery)

        super.init(
            moduleType: .iOSBattery,
            popup: self.popupView,
            settings: self.settingsContent,
            portal: self.portalView,
            notifications: nil,
            preview: nil,
            configName: "iOSBattery.config",
            configBundle: Bundle.main,
            extraSettings: [(localizedString("Python"), self.pythonSettingsContent)]
        )

        self.settingsContent.setInterval = { [weak self] value in
            self?.usageReader?.setInterval(value)
        }
        self.settingsContent.refreshNow = { [weak self] in
            guard let reader = self?.usageReader else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                reader.read()
            }
        }
        self.settingsContent.syncFromReader = { [weak self] in
            self?.usageReader?.value
        }
        self.pythonSettingsContent.refreshNow = { [weak self] in
            guard let reader = self?.usageReader else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                reader.read()
            }
        }
        
        self.usageReader = iOSBatteryReader(.iOSBattery) { [weak self] value in
            guard let self, let value else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settingsContent.apply(value)
                self.popupView.usageCallback(value)
                self.portalView.usageCallback(value)
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let primary = value.primaryDevice
                let percent = Double(primary?.currentCapacityPercent ?? 0) / 100.0
                let charging = primary?.isCharging ?? false
                self.menuBar.widgets.filter { $0.isActive }.forEach { (w: SWidget) in
                    switch w.item {
                    case let widget as Mini:
                        widget.setValue(percent)
                        widget.setColorZones((0.15, 0.3))
                    case let widget as BarChart:
                        widget.setValue([[ColorValue(percent)]])
                        widget.setColorZones((0.15, 0.3))
                    case let widget as BatteryWidget:
                        widget.setValue(
                            percentage: percent,
                            ACStatus: charging,
                            isCharging: charging,
                            optimizedCharging: false,
                            time: 0
                        )
                    case let widget as BatteryDetailsWidget:
                        widget.setValue(percentage: percent, time: 0)
                    default:
                        break
                    }
                }
            }
        }
        
        self.setReaders([self.usageReader])
    }
    
    public override func isAvailable() -> Bool { true }
}
