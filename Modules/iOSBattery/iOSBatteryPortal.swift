//
//  iOSBatteryPortal.swift
//  Stats
//

import Cocoa
import Kit

internal final class iOSBatteryPortal: NSStackView, Portal_p {
    var name: String

    private let levelField: NSTextField = ValueField(frame: NSRect.zero, "")
    private let chargingField: NSTextField = ValueField(frame: NSRect.zero, "")

    public init(_ module: ModuleType) {
        self.name = module.stringValue
        super.init(frame: NSRect.zero)

        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 3

        self.orientation = .vertical
        self.distribution = .fillEqually
        self.spacing = Constants.Popup.spacing * 2
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.spacing * 2,
            left: Constants.Popup.spacing * 2,
            bottom: Constants.Popup.spacing * 2,
            right: Constants.Popup.spacing * 2
        )

        self.addArrangedSubview(PortalHeader(name))
        self.addArrangedSubview(NSView())

        let box = NSStackView()
        box.orientation = .horizontal
        box.distribution = .fillEqually
        box.spacing = 0
        box.edgeInsets = NSEdgeInsets(top: 0, left: Constants.Popup.spacing * 2, bottom: 0, right: Constants.Popup.spacing * 2)

        self.levelField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.levelField.alignment = .left
        self.chargingField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.chargingField.alignment = .right

        let leftStack = NSStackView(views: [self.levelField])
        leftStack.orientation = .horizontal
        leftStack.alignment = .leading

        let rightStack = NSStackView(views: [self.chargingField])
        rightStack.orientation = .horizontal
        rightStack.alignment = .trailing

        box.addArrangedSubview(leftStack)
        box.addArrangedSubview(NSView())
        box.addArrangedSubview(rightStack)

        self.addArrangedSubview(box)
        self.heightAnchor.constraint(equalToConstant: Constants.Popup.portalHeight).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func usageCallback(_ value: iOSBattery_Usage) {
        let level: String
        let charging: String
        if let d = value.primaryDevice {
            level = d.currentCapacityPercent.map { "\($0)%" } ?? "—"
            charging = d.isCharging == true ? localizedString("Charging") : ""
        } else {
            level = "—"
            charging = ""
        }
        if Thread.isMainThread {
            self.levelField.stringValue = level
            self.chargingField.stringValue = charging
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.levelField.stringValue = level
                self.chargingField.stringValue = charging
            }
        }
    }
}
