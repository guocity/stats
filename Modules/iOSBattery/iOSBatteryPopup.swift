//
//  iOSBatteryPopup.swift
//  Stats
//

import Cocoa
import Kit

// MARK: - Popup field visibility

enum iOSBatteryPopupField: String, CaseIterable {
    case name, type, iosVersion, connection, udid
    case charge, isCharging, cycles, health, temperature, virtualTemperature, voltage
    case manufacturer, manufactureDate, dateOfFirstUse, serial, updateTime
    
    var section: String {
        switch self {
        case .name, .type, .iosVersion, .connection, .udid: return localizedString("Device")
        default: return localizedString("Battery")
        }
    }
    
    var label: String {
        switch self {
        case .name: return localizedString("Name")
        case .type: return localizedString("Type")
        case .iosVersion: return localizedString("iOS Version")
        case .connection: return localizedString("Connection")
        case .udid: return "UDID"
        case .charge: return localizedString("Charge")
        case .isCharging: return localizedString("Is charging")
        case .cycles: return localizedString("Cycles")
        case .health: return localizedString("Health")
        case .temperature: return localizedString("Temperature")
        case .virtualTemperature: return "VirtualTemperature"
        case .voltage: return localizedString("Voltage")
        case .manufactureDate: return "ManufactureDate"
        case .manufacturer: return "Manufacturer"
        case .dateOfFirstUse: return "DateOfFirstUse"
        case .serial: return "Serial"
        case .updateTime: return "UpdateTime"
        }
    }
    
    var defaultVisible: Bool {
        switch self {
        case .udid: return false
        default: return true
        }
    }
    
    var storeKey: String { "iOSBattery_popup_\(rawValue)" }
    
    static func isVisible(_ field: iOSBatteryPopupField) -> Bool {
        Store.shared.bool(key: field.storeKey, defaultValue: field.defaultVisible)
    }
}

private func iOSBatteryCapacityStoreKey(_ key: String) -> String {
    "iOSBattery_popup_cap_\(key)"
}

private func iOSBatteryCapacityVisible(_ key: String) -> Bool {
    Store.shared.bool(key: iOSBatteryCapacityStoreKey(key), defaultValue: true)
}

// MARK: - Popup

internal final class iOSBatteryPopup: PopupWrapper {
    private let cache = PopupCache<iOSBattery_Usage>()
    private let contentWidth = Constants.Popup.width
    
    private let devicesStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = Constants.Popup.spacing
        stack.alignment = .leading
        return stack
    }()
    
    private var devicePanels: [String: iOSBatteryDevicePanel] = [:]
    private var emptyStateView: NSView?
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.spacing = 0
        self.orientation = .vertical
        self.addArrangedSubview(self.devicesStack)
        self.recalculateHeight()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func appear() {
        self.replay(self.cache, render: self.render)
    }
    
    public override func settings() -> NSView? {
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        let deviceFields: [iOSBatteryPopupField] = [.name, .type, .iosVersion, .connection, .udid]
        let batteryFields: [iOSBatteryPopupField] = [
            .charge, .isCharging, .cycles, .health, .temperature, .virtualTemperature, .voltage,
            .manufacturer, .manufactureDate, .dateOfFirstUse, .serial
        ]
        func rows(_ fields: [iOSBatteryPopupField]) -> [PreferencesRow] {
            fields.map { field in
                let btn = switchView(action: #selector(self.togglePopupField(_:)), state: iOSBatteryPopupField.isVisible(field))
                btn.identifier = NSUserInterfaceItemIdentifier(rawValue: field.rawValue)
                return PreferencesRow(field.label, component: btn)
            }
        }
        let capacityRows = iOSBatteryCapacityFieldKeys.map { key in
            let btn = switchView(action: #selector(self.toggleCapacityField(_:)), state: iOSBatteryCapacityVisible(key))
            btn.identifier = NSUserInterfaceItemIdentifier(rawValue: "cap:\(key)")
            return PreferencesRow(key, component: btn)
        }
        let deviceRows = rows(deviceFields)
        var batteryRows = rows(batteryFields)
        batteryRows.append(contentsOf: capacityRows)
        batteryRows.append(contentsOf: rows([.updateTime]))
        
        view.addArrangedSubview(PreferencesSection(title: localizedString("Device"), deviceRows))
        view.addArrangedSubview(PreferencesSection(title: localizedString("Battery"), batteryRows))
        
        return view
    }
    
    func usageCallback(_ value: iOSBattery_Usage) {
        self.apply(value, to: self.cache, render: self.render)
    }
    
    private func render(_ value: iOSBattery_Usage) {
        let connected = value.devices.filter(\.isConnectedDevice)
            .sorted { ($0.displayName, $0.udid ?? "") < ($1.displayName, $1.udid ?? "") }
        let keys = Set(connected.enumerated().map { self.deviceKey($0.element, index: $0.offset) })
        
        if connected.isEmpty {
            let statusMessage = value.devices.first(where: \.isStatusRow)?.lastError
            let message = self.emptyStateMessage(statusMessage: statusMessage)
            let showWiFiHint = statusMessage?.localizedCaseInsensitiveContains("Wi") == true
                || statusMessage?.localizedCaseInsensitiveContains("network") == true
            
            if let empty = self.emptyStateView {
                self.devicesStack.removeArrangedSubview(empty)
                empty.removeFromSuperview()
            }
            self.removeAllPanelsFromStack()
            self.devicePanels.values.forEach { $0.removeFromSuperview() }
            self.devicePanels.removeAll()
            let panel = iOSBatteryDevicePanel(width: self.contentWidth)
            panel.renderEmpty(message: message, showWiFiHint: showWiFiHint)
            self.emptyStateView = panel
            self.devicesStack.addArrangedSubview(panel)
            self.scheduleHeightUpdate()
            return
        }
        
        if let empty = self.emptyStateView {
            self.devicesStack.removeArrangedSubview(empty)
            empty.removeFromSuperview()
            self.emptyStateView = nil
        }
        
        let staleKeys = Set(self.devicePanels.keys).subtracting(keys)
        for key in staleKeys {
            if let panel = self.devicePanels[key] {
                self.devicesStack.removeArrangedSubview(panel)
                panel.removeFromSuperview()
            }
            self.devicePanels.removeValue(forKey: key)
        }
        
        self.removeAllPanelsFromStack()
        
        for (index, device) in connected.enumerated() {
            if index > 0 {
                self.devicesStack.addArrangedSubview(iOSBatteryDeviceDivider(width: self.contentWidth))
            }
            let key = deviceKey(device, index: index)
            let panel = self.devicePanels[key] ?? {
                let created = iOSBatteryDevicePanel(width: self.contentWidth)
                self.devicePanels[key] = created
                return created
            }()
            let title = device.displayName.isEmpty ? "Device \(index + 1)" : device.displayName
            panel.render(device, sectionTitle: title)
            self.devicesStack.addArrangedSubview(panel)
        }
        
        self.scheduleHeightUpdate()
    }
    
    private func emptyStateMessage(statusMessage: String?) -> String {
        guard let statusMessage, !statusMessage.isEmpty else {
            return localizedString("No devices connected")
        }
        if statusMessage.localizedCaseInsensitiveContains("no ios devices found")
            || statusMessage.localizedCaseInsensitiveContains("no devices") {
            return localizedString("No devices connected")
        }
        return statusMessage
    }
    
    private func deviceKey(_ device: iOSBattery_DeviceSnapshot, index: Int = 0) -> String {
        if let udid = device.udid, !udid.isEmpty { return udid }
        return "idx-\(index)"
    }
    
    private func removeAllPanelsFromStack() {
        self.devicesStack.arrangedSubviews.forEach {
            self.devicesStack.removeArrangedSubview($0)
        }
    }
    
    @objc private func togglePopupField(_ sender: NSControl) {
        guard let raw = sender.identifier?.rawValue,
              let field = iOSBatteryPopupField(rawValue: raw) else { return }
        Store.shared.set(key: field.storeKey, value: controlState(sender))
        self.devicePanels.values.forEach { $0.applyFieldVisibility() }
        self.scheduleHeightUpdate()
    }
    
    @objc private func toggleCapacityField(_ sender: NSControl) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("cap:") else { return }
        let key = String(raw.dropFirst(4))
        Store.shared.set(key: iOSBatteryCapacityStoreKey(key), value: controlState(sender))
        self.devicePanels.values.forEach { $0.applyFieldVisibility() }
        self.scheduleHeightUpdate()
    }
    
    private func scheduleHeightUpdate() {
        if Thread.isMainThread {
            self.recalculateHeight()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recalculateHeight()
            }
        }
    }
    
    private func recalculateHeight() {
        var h: CGFloat = 0
        let views = self.devicesStack.arrangedSubviews
        for (index, v) in views.enumerated() {
            h += max(v.fittingSize.height, 1)
            if index < views.count - 1 {
                h += self.devicesStack.spacing
            }
        }
        guard h > 0, abs(self.frame.size.height - h) > 0.5 else { return }
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback?(self.frame.size)
    }
}

// MARK: - Device divider

private final class iOSBatteryDeviceDivider: NSView {
    init(width: CGFloat) {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(line)
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: width),
            self.heightAnchor.constraint(equalToConstant: Constants.Popup.spacing * 2 + 1),
            line.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Constants.Popup.margins),
            line.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Constants.Popup.margins),
            line.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var fittingSize: NSSize {
        NSSize(width: bounds.width, height: Constants.Popup.spacing * 2 + 1)
    }
}

// MARK: - Percent bar (charge / health)

private final class iOSBatteryPercentBarView: NSView {
    private var fraction: Double = 0
    private var hasValue: Bool = false
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barH: CGFloat = 8
        let y = (bounds.height - barH) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: barH), xRadius: 3, yRadius: 3)
        (NSColor.separatorColor.withAlphaComponent(0.4)).setFill()
        track.fill()
        
        guard self.hasValue else { return }
        let fillW = max(0, min(bounds.width, bounds.width * CGFloat(self.fraction)))
        guard fillW > 0.5 else { return }
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: fillW, height: barH), xRadius: 3, yRadius: 3)
        self.fraction.batteryColor(color: true).setFill()
        fill.fill()
    }
    
    func setPercent(_ percent: Double?) {
        if let percent {
            self.hasValue = true
            self.fraction = max(0, min(1, percent / 100))
        } else {
            self.hasValue = false
            self.fraction = 0
        }
        self.needsDisplay = true
    }
}

// MARK: - Per-device panel

private final class iOSBatteryDevicePanel: NSView {
    private static let rowHeight: CGFloat = 22
    private static let barRowHeight: CGFloat = 28
    
    private let contentWidth: CGFloat
    private var panelHeightConstraint: NSLayoutConstraint!
    private var deviceSectionHeightConstraint: NSLayoutConstraint!
    private var batterySectionHeightConstraint: NSLayoutConstraint!
    
    private var rootStack: NSStackView?
    private var deviceSectionView: NSView?
    private var batterySectionView: NSView?
    private var deviceSeparatorLabel: NSTextField?
    private var valueFields: [iOSBatteryPopupField: ValueField] = [:]
    private var rowViews: [iOSBatteryPopupField: NSView] = [:]
    private var percentBars: [iOSBatteryPopupField: iOSBatteryPercentBarView] = [:]
    private var capacityValueFields: [String: ValueField] = [:]
    private var capacityRowViews: [String: NSView] = [:]
    private var extraCapacityKeys: [String] = []
    
    init(width: CGFloat) {
        self.contentWidth = width
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.panelHeightConstraint = self.heightAnchor.constraint(equalToConstant: 1)
        self.panelHeightConstraint.isActive = true
        self.widthAnchor.constraint(equalToConstant: width).isActive = true
        self.buildLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var fittingSize: NSSize {
        NSSize(width: self.contentWidth, height: self.panelHeightConstraint.constant)
    }
    
    private func buildLayout() {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.valueFields.removeAll()
        self.rowViews.removeAll()
        self.percentBars.removeAll()
        self.capacityValueFields.removeAll()
        self.capacityRowViews.removeAll()
        self.extraCapacityKeys.removeAll()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.rootStack = stack
        
        let deviceSection = self.makeSection(
            title: localizedString("Device"),
            fields: [.name, .type, .iosVersion, .connection, .udid],
            captureSeparator: true
        )
        let batterySection = self.makeBatterySection()
        self.deviceSectionView = deviceSection
        self.batterySectionView = batterySection
        stack.addArrangedSubview(deviceSection)
        stack.addArrangedSubview(batterySection)
        
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
        self.applyFieldVisibility()
    }
    
    private func makeSection(
        title: String,
        fields: [iOSBatteryPopupField],
        captureSeparator: Bool
    ) -> NSView {
        let h = self.sectionHeight(for: fields)
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: h)
        heightConstraint.isActive = true
        if captureSeparator {
            self.deviceSectionHeightConstraint = heightConstraint
        } else {
            self.batterySectionHeightConstraint = heightConstraint
        }
        
        let separator = separatorView(title, width: self.contentWidth)
        if captureSeparator {
            self.deviceSeparatorLabel = separator.subviews.first as? NSTextField
        }
        separator.translatesAutoresizingMaskIntoConstraints = false
        
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        
        for field in fields {
            if field == .charge || field == .health {
                let row = popupBarRow(inner, title: "\(field.label):", width: self.contentWidth)
                self.percentBars[field] = row.0
                self.valueFields[field] = row.1
                self.rowViews[field] = row.2
            } else {
                let multiline = field == .udid
                let row = popupRow(inner, title: "\(field.label):", value: "—", multiline: multiline, width: self.contentWidth)
                self.valueFields[field] = row.1
                self.rowViews[field] = row.2
            }
        }
        
        view.addSubview(separator)
        view.addSubview(inner)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Constants.Popup.separatorHeight),
            inner.topAnchor.constraint(equalTo: separator.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }
    
    private func makeBatterySection() -> NSView {
        let standardFields: [iOSBatteryPopupField] = [
            .charge, .isCharging, .cycles, .health, .temperature, .virtualTemperature, .voltage,
            .manufacturer, .manufactureDate, .dateOfFirstUse, .serial
        ]
        let h = self.batterySectionHeight(standardFields: standardFields)
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: h)
        heightConstraint.isActive = true
        self.batterySectionHeightConstraint = heightConstraint
        self.batterySectionView = view
        
        let separator = separatorView(localizedString("Battery"), width: self.contentWidth)
        separator.translatesAutoresizingMaskIntoConstraints = false
        
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        
        for field in standardFields {
            if field == .charge || field == .health {
                let row = popupBarRow(inner, title: "\(field.label):", width: self.contentWidth)
                self.percentBars[field] = row.0
                self.valueFields[field] = row.1
                self.rowViews[field] = row.2
            } else {
                let multiline = field == .udid
                let row = popupRow(inner, title: "\(field.label):", value: "—", multiline: multiline, width: self.contentWidth)
                self.valueFields[field] = row.1
                self.rowViews[field] = row.2
            }
        }
        
        for key in iOSBatteryCapacityFieldKeys {
            let row = popupRow(inner, title: "\(key):", value: "—", width: self.contentWidth)
            self.capacityValueFields[key] = row.1
            self.capacityRowViews[key] = row.2
        }
        
        let updateRow = popupRow(inner, title: "\(iOSBatteryPopupField.updateTime.label):", value: "—", width: self.contentWidth)
        self.valueFields[.updateTime] = updateRow.1
        self.rowViews[.updateTime] = updateRow.2
        
        view.addSubview(separator)
        view.addSubview(inner)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: Constants.Popup.separatorHeight),
            inner.topAnchor.constraint(equalTo: separator.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }
    
    private func syncExtraCapacityRows(keys: [String]) {
        guard let inner = self.batterySectionView?.subviews.last as? NSStackView else { return }
        let newKeys = keys.filter { !iOSBatteryCapacityFieldKeys.contains($0) }
        guard newKeys != self.extraCapacityKeys else { return }
        
        for key in self.extraCapacityKeys {
            self.capacityRowViews[key]?.removeFromSuperview()
            self.capacityValueFields.removeValue(forKey: key)
            self.capacityRowViews.removeValue(forKey: key)
        }
        self.extraCapacityKeys = newKeys
        
        for key in newKeys {
            let row = popupRow(nil, title: "\(key):", value: "—", width: self.contentWidth)
            if let updateRow = self.rowViews[.updateTime],
               let idx = inner.arrangedSubviews.firstIndex(of: updateRow) {
                inner.insertArrangedSubview(row.2, at: idx)
            } else {
                inner.addArrangedSubview(row.2)
            }
            self.capacityValueFields[key] = row.1
            self.capacityRowViews[key] = row.2
        }
    }
    
    func applyFieldVisibility() {
        for (field, row) in self.rowViews {
            row.isHidden = !iOSBatteryPopupField.isVisible(field)
        }
        for (key, row) in self.capacityRowViews {
            row.isHidden = !iOSBatteryCapacityVisible(key)
        }
        self.resizeSections()
    }
    
    private func resizeSections() {
        let deviceFields: [iOSBatteryPopupField] = [.name, .type, .iosVersion, .connection, .udid]
        let standardBattery: [iOSBatteryPopupField] = [
            .charge, .isCharging, .cycles, .health, .temperature, .virtualTemperature, .voltage,
            .manufacturer, .manufactureDate, .dateOfFirstUse, .serial
        ]
        let deviceH = sectionHeight(for: deviceFields)
        let batteryH = batterySectionHeight(standardFields: standardBattery)
        self.deviceSectionHeightConstraint?.constant = deviceH
        self.batterySectionHeightConstraint?.constant = batteryH
        self.panelHeightConstraint.constant = deviceH + batteryH
    }
    
    private func batterySectionHeight(standardFields: [iOSBatteryPopupField]) -> CGFloat {
        let visible = standardFields.filter(iOSBatteryPopupField.isVisible)
        var rowsH = visible.reduce(CGFloat(0)) { $0 + Self.height(for: $1) }
        let capKeys = iOSBatteryCapacityFieldKeys + self.extraCapacityKeys
        rowsH += CGFloat(capKeys.filter(iOSBatteryCapacityVisible).count) * Self.rowHeight
        if iOSBatteryPopupField.isVisible(.updateTime) {
            rowsH += Self.rowHeight
        }
        return rowsH + Constants.Popup.separatorHeight
    }
    
    private func sectionHeight(for fields: [iOSBatteryPopupField]) -> CGFloat {
        let visible = fields.filter(iOSBatteryPopupField.isVisible)
        guard !visible.isEmpty else {
            return Constants.Popup.separatorHeight + Self.rowHeight
        }
        let rowsH = visible.reduce(CGFloat(0)) { $0 + Self.height(for: $1) }
        return rowsH + Constants.Popup.separatorHeight
    }
    
    private static func height(for field: iOSBatteryPopupField) -> CGFloat {
        switch field {
        case .charge, .health: return barRowHeight
        default: return rowHeight
        }
    }
    
    func renderEmpty(message: String, showWiFiHint: Bool = false) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.rootStack = nil
        self.valueFields.removeAll()
        self.rowViews.removeAll()
        self.percentBars.removeAll()
        self.capacityValueFields.removeAll()
        self.capacityRowViews.removeAll()
        
        var text = message
        if showWiFiHint {
            text += "\n\n" + localizedString("For Wi‑Fi: enable “Show this iPhone when on Wi‑Fi” in Finder, then allow Local Network for Stats in System Settings → Privacy & Security.")
        }
        
        let lines = CGFloat(max(1, text.components(separatedBy: "\n").count))
        let h = 24 + (lines * 18) + (showWiFiHint ? 40 : 0)
        self.panelHeightConstraint.constant = max(h, 48)
        
        let label = ValueField(frame: .zero, text)
        label.alignment = .center
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: self.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Constants.Popup.margins),
            label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Constants.Popup.margins),
            label.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12)
        ])
    }
    
    func render(_ d: iOSBattery_DeviceSnapshot, sectionTitle: String) {
        if self.rootStack == nil {
            self.buildLayout()
        }
        
        self.deviceSeparatorLabel?.stringValue = sectionTitle
        
        let nameText: String = {
            let name = d.displayName
            return name.isEmpty ? (d.lastError ?? localizedString("Unknown")) : name
        }()
        
        self.set(.name, nameText)
        self.set(.type, d.productType ?? "—")
        self.set(.iosVersion, d.productVersion ?? "—")
        self.set(.connection, d.connection ?? "—")
        self.set(.udid, d.udid ?? "—")
        if let pct = d.currentCapacityPercent {
            self.percentBars[.charge]?.setPercent(Double(pct))
            var label = "\(pct)%"
            if d.isStale {
                label += " · " + localizedString("Last known values")
            }
            self.valueFields[.charge]?.stringValue = label
        } else {
            self.percentBars[.charge]?.setPercent(nil)
            self.valueFields[.charge]?.stringValue = "—"
        }
        self.set(.isCharging, d.isCharging.map { $0 ? localizedString("Yes") : localizedString("No") } ?? "—")
        self.set(.cycles, d.cycleCount.map(String.init) ?? "—")
        if let health = d.healthPercent {
            self.percentBars[.health]?.setPercent(health)
            self.valueFields[.health]?.stringValue = d.formattedHealth
            if let design = d.designCapacityMAh {
                let maxCap = d.appleRawMaxCapacityMAh ?? d.nominalChargeCapacityMAh
                self.percentBars[.health]?.toolTip = maxCap.map { "\($0) / \(design) mAh" } ?? "design \(design) mAh"
            }
        } else {
            self.percentBars[.health]?.setPercent(nil)
            self.valueFields[.health]?.stringValue = "—"
            self.percentBars[.health]?.toolTip = nil
        }
        self.set(.temperature, d.temperatureC.map { "\(temperature($0, fractionDigits: 1))" } ?? "—")
        self.set(.virtualTemperature, d.formattedVirtualTemperature)
        self.set(.voltage, d.voltageMV.map { "\($0) mV" } ?? "—")
        self.set(.manufacturer, d.manufacturer ?? "—")
        self.set(.manufactureDate, d.formattedManufactureDate)
        self.set(.dateOfFirstUse, d.formattedDateOfFirstUse)
        self.set(.serial, d.serial ?? "—")
        
        let extra = d.capacityFields.keys.filter {
            !iOSBatteryCapacityFieldKeys.contains($0) && !iOSBatteryHiddenCapacityKeys.contains($0)
        }.sorted()
        self.syncExtraCapacityRows(keys: extra)
        for key in iOSBatteryCapacityFieldKeys + extra {
            let raw = d.capacityFields[key]
            self.capacityValueFields[key]?.stringValue = iOSBatteryFormatCapacityValue(key: key, raw: raw)
            if key == "TimeRemaining", let raw {
                self.capacityValueFields[key]?.toolTip = localizedString("Minutes until battery is empty or full.")
            }
        }
        
        self.set(.updateTime, d.formattedUpdateTime)
        self.applyFieldVisibility()
    }
    
    private func set(_ field: iOSBatteryPopupField, _ value: String) {
        self.valueFields[field]?.stringValue = value
    }
}

private func popupRow(_ view: NSView? = nil, title: String, value: String, multiline: Bool = false, width: CGFloat) -> (LabelField, ValueField, NSView) {
    let lines: CGFloat = CGFloat(multiline ? value.filter { $0 == "\n" }.count + 1 : 1)
    let height = multiline ? ((lines*16) + (22-16)): 22
    
    let rowView: NSView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    
    let labelWidth = title.widthOfString(usingFont: .systemFont(ofSize: 12, weight: .regular)) + 4
    let labelView: LabelField = LabelField(frame: NSRect(x: 0, y: ((22-16)/2) + ((lines-1)*16), width: labelWidth, height: 16), title)
    let valueView: ValueField = ValueField(frame: NSRect(x: labelWidth, y: (22-16)/2, width: rowView.frame.width - labelWidth, height: multiline ? 16*lines : 16), value)
    
    if multiline {
        valueView.cell?.usesSingleLineMode = false
    }
    
    rowView.addSubview(labelView)
    rowView.addSubview(valueView)
    
    if let view = view as? NSStackView {
        rowView.heightAnchor.constraint(equalToConstant: rowView.bounds.height).isActive = true
        view.addArrangedSubview(rowView)
    } else if let view {
        view.addSubview(rowView)
    }
    
    return (labelView, valueView, rowView)
}

private let iOSBatteryPopupBarRowHeight: CGFloat = 28

private func popupBarRow(_ stack: NSStackView, title: String, width: CGFloat) -> (iOSBatteryPercentBarView, ValueField, NSView) {
    let rowH: CGFloat = iOSBatteryPopupBarRowHeight
    let rowView = NSView()
    rowView.translatesAutoresizingMaskIntoConstraints = false
    
    let labelWidth = title.widthOfString(usingFont: .systemFont(ofSize: 12, weight: .regular)) + 4
    let labelView = LabelField(frame: .zero, title)
    labelView.translatesAutoresizingMaskIntoConstraints = false
    
    let percentWidth: CGFloat = 44
    let valueView = ValueField(frame: .zero, "—")
    valueView.translatesAutoresizingMaskIntoConstraints = false
    valueView.alignment = .right
    
    let barView = iOSBatteryPercentBarView()
    barView.translatesAutoresizingMaskIntoConstraints = false
    
    rowView.addSubview(labelView)
    rowView.addSubview(barView)
    rowView.addSubview(valueView)
    
    NSLayoutConstraint.activate([
        rowView.heightAnchor.constraint(equalToConstant: rowH),
        labelView.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
        labelView.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        labelView.widthAnchor.constraint(equalToConstant: labelWidth),
        valueView.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
        valueView.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        valueView.widthAnchor.constraint(equalToConstant: percentWidth),
        barView.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 4),
        barView.trailingAnchor.constraint(equalTo: valueView.leadingAnchor, constant: -6),
        barView.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        barView.heightAnchor.constraint(equalToConstant: 10)
    ])
    
    stack.addArrangedSubview(rowView)
    return (barView, valueView, rowView)
}
