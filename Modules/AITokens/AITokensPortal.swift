//
//  AITokensPortal.swift
//  Stats
//

import Cocoa
import Kit

internal final class AITokensPortal: NSStackView, Portal_p {
    var name: String

    private let titleField: NSTextField = ValueField(frame: .zero, "")
    private let usedField: NSTextField = ValueField(frame: .zero, "")
    private let resetField: NSTextField = ValueField(frame: .zero, "")

    public init(_ module: ModuleType) {
        self.name = module.stringValue
        super.init(frame: .zero)

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

        self.titleField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.titleField.alignment = .left
        self.usedField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.usedField.alignment = .right
        self.resetField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        self.resetField.alignment = .right
        self.resetField.textColor = .secondaryLabelColor

        let topRow = NSStackView(views: [self.titleField, NSView(), self.usedField])
        topRow.orientation = .horizontal
        topRow.distribution = .fill

        self.addArrangedSubview(topRow)
        self.addArrangedSubview(self.resetField)
        self.heightAnchor.constraint(equalToConstant: Constants.Popup.portalHeight).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateLayer() {
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func usageCallback(_ value: AITokens_Usage) {
        var title = "—"
        var used = "—"
        var reset = ""
        if let primary = value.primaryWindow, let latest = primary.window.latest {
            title = "\(primary.provider.name) · \(primary.window.displayName)"
            used = "\(Int(latest.usedPercent.rounded()))%"
            let upcoming = aiTokensUpcomingReset(primary.window) ?? latest.resetsAt
            reset = localizedString("resets") + " " + aiTokensCountdown(to: upcoming)
        }
        let apply = { [weak self] in
            guard let self else { return }
            self.titleField.stringValue = title
            self.usedField.stringValue = used
            self.resetField.stringValue = reset
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
}
