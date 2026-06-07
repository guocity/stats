//
//  AITokensPopup.swift
//  Stats
//

import Cocoa
import Kit

internal final class AITokensPopup: PopupWrapper {
    private let cache = PopupCache<AITokens_Usage>()
    private let contentWidth = Constants.Popup.width

    private let stack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = Constants.Popup.spacing
        s.alignment = .leading
        return s
    }()

    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        self.spacing = 0
        self.orientation = .vertical
        self.addArrangedSubview(self.stack)
        self.recalculateHeight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var timer: Timer? = nil

    public override func appear() {
        self.replay(self.cache, render: self.render)
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.replay(self.cache, render: self.render)
        }
    }

    public override func disappear() {
        self.timer?.invalidate()
        self.timer = nil
    }

    func usageCallback(_ value: AITokens_Usage) {
        self.apply(value, to: self.cache, render: self.render)
    }

    private func render(_ value: AITokens_Usage) {
        self.stack.arrangedSubviews.forEach {
            self.stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let providers = value.providers.filter { provider in
            provider.enabled && provider.windows.contains(where: { !$0.isStale })
        }
        guard !providers.isEmpty else {
            let message = value.statusMessage ?? localizedString("No usage history found")
            self.stack.addArrangedSubview(self.emptyState(message))
            self.scheduleHeightUpdate()
            return
        }

        let now = Date()
        let compact = Store.shared.bool(key: "AITokens_compactPopup", defaultValue: true)

        for provider in providers {
            self.stack.addArrangedSubview(self.providerHeader(provider.name, width: self.contentWidth))
            for (index, window) in provider.windows.enumerated() where !window.isStale {
                guard let latest = window.latest else { continue }
                let remainingFraction: Double
                let countdownColor: NSColor
                let resetsText: String
                let resetAbsoluteText: String
                if let upcoming = aiTokensUpcomingReset(window, from: now) {
                    // Fraction of the window's time still remaining (full just after a reset, empty at reset).
                    let windowSec = Double(window.windowMinutes * 60)
                    let remainingSec = upcoming.timeIntervalSince(now)
                    remainingFraction = windowSec > 0 ? max(0, min(1, remainingSec / windowSec)) : 0
                    
                    if remainingSec < 3600 {
                        countdownColor = .systemRed
                    } else if remainingSec > 86400 {
                        let colorKey = Store.shared.string(key: "AITokens_moreThanDayColor", defaultValue: "custom:#007AFFFF")
                        countdownColor = SColor.fromString(colorKey).additional as? NSColor ?? NSColor.systemIndigo
                    } else {
                        let colorKey = Store.shared.string(key: "AITokens_lessThanDayColor", defaultValue: "custom:#4FA5FCFF")
                        countdownColor = SColor.fromString(colorKey).additional as? NSColor ?? NSColor.systemBlue
                    }
                    
                    resetsText = aiTokensCountdown(to: upcoming, from: now)
                    resetAbsoluteText = "\(localizedString("resets")) \(aiTokensAbsoluteDate(upcoming))"
                } else {
                    // Inactive window (provider stopped reporting it) — show last-known usage, no countdown.
                    remainingFraction = 0
                    countdownColor = .tertiaryLabelColor
                    resetsText = "\(localizedString("inactive")) · \(localizedString("last seen")) \(aiTokensRelativeAge(latest.capturedAt, from: now))"
                    resetAbsoluteText = resetsText
                }
                self.stack.addArrangedSubview(AITokensWindowRow(
                    width: self.contentWidth,
                    title: window.displayName,
                    usedPercent: latest.usedPercent,
                    color: provider.color(forWindowIndex: index),
                    remainingFraction: remainingFraction,
                    countdownColor: countdownColor,
                    resetAbsoluteText: resetAbsoluteText,
                    resets: resetsText,
                    updated: "\(localizedString("updated")) \(aiTokensRelativeAge(latest.capturedAt, from: now))",
                    compact: compact
                ))
            }
        }
        self.scheduleHeightUpdate()
    }

    /// Section header for a provider: its white brand glyph followed by the name,
    /// flanked by separator lines (matches `separatorView` styling). Falls back to a
    /// plain separator for providers we don't ship an icon for.
    private func providerHeader(_ name: String, width: CGFloat) -> NSView {
        guard let icon = aiTokensProviderIcon(name) else {
            return separatorView(name, width: width)
        }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        view.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let labelView = NSTextField(labelWithString: "")
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.alignment = .center
        labelView.isBezeled = false
        labelView.isEditable = false
        labelView.drawsBackground = false
        labelView.attributedStringValue = NSAttributedString(string: name.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.0
        ])
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leftLine = NSView()
        leftLine.translatesAutoresizingMaskIntoConstraints = false
        leftLine.wantsLayer = true
        leftLine.layer?.backgroundColor = NSColor.separatorColor.cgColor

        let rightLine = NSView()
        rightLine.translatesAutoresizingMaskIntoConstraints = false
        rightLine.wantsLayer = true
        rightLine.layer?.backgroundColor = NSColor.separatorColor.cgColor

        view.addSubview(leftLine)
        view.addSubview(imageView)
        view.addSubview(labelView)
        view.addSubview(rightLine)

        let gap: CGFloat = 8
        let iconSize: CGFloat = 13
        NSLayoutConstraint.activate([
            labelView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            labelView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            imageView.trailingAnchor.constraint(equalTo: labelView.leadingAnchor, constant: -4),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            leftLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftLine.trailingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: -gap),
            leftLine.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            rightLine.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: gap),
            rightLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightLine.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 1)
        ])

        return view
    }

    private func emptyState(_ message: String) -> NSView {
        let label = ValueField(frame: NSRect(x: 0, y: 0, width: self.contentWidth - Constants.Popup.margins * 2, height: 60), message)
        label.alignment = .center
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: self.contentWidth - Constants.Popup.margins * 2).isActive = true
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        return label
    }

    private func scheduleHeightUpdate() {
        if Thread.isMainThread {
            self.recalculateHeight()
        } else {
            DispatchQueue.main.async { [weak self] in self?.recalculateHeight() }
        }
    }

    private func recalculateHeight() {
        var h: CGFloat = 0
        let views = self.stack.arrangedSubviews
        for (index, v) in views.enumerated() {
            h += max(v.fittingSize.height, 1)
            if index < views.count - 1 { h += self.stack.spacing }
        }
        guard h > 0, abs(self.frame.size.height - h) > 0.5 else { return }
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback?(self.frame.size)
    }
}

// MARK: - One window row: name, usage bar, percent, reset + updated subtitle.

private final class AITokensWindowRow: NSView {
    private let isCompact: Bool
    private let countdownText: String
    private let hoverText: String
    private var resetField: NSTextField!
    private var hoverTrackingArea: NSTrackingArea?
    /// Bounds of the hover-sensitive zone (countdown bar + reset label), in this view's coordinates.
    private var countdownZone: NSRect = .zero

    init(width: CGFloat, title: String, usedPercent: Double, color: NSColor,
         remainingFraction: Double, countdownColor: NSColor, resetAbsoluteText: String, resets: String, updated: String, compact: Bool) {
        self.isCompact = compact
        self.countdownText = resets
        self.hoverText = resetAbsoluteText
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: width).isActive = true
        
        let rowHeight: CGFloat = compact ? 42 : 60
        self.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let titleSize: CGFloat = compact ? 11 : 12
        let percentSize: CGFloat = compact ? 11 : 12
        let resetsSize: CGFloat = compact ? 9 : 10
        let usageBarHeight: CGFloat = compact ? 4 : 6
        let countdownBarHeight: CGFloat = compact ? 1.5 : 2.5

        let titleField = LabelField(frame: .zero, title)
        titleField.font = NSFont.systemFont(ofSize: titleSize, weight: .medium)
        titleField.textColor = .textColor
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let percentField = ValueField(frame: .zero, "\(Int(usedPercent.rounded()))%")
        percentField.font = NSFont.systemFont(ofSize: percentSize, weight: .semibold)
        percentField.alignment = .right
        percentField.translatesAutoresizingMaskIntoConstraints = false

        // Usage bar shows remaining capacity (like CodexBar): full when fresh, depleting as it's used.
        let remaining = max(0, min(1, (100 - usedPercent) / 100))
        let usageBar = AITokensBarView(fraction: remaining, color: color)
        usageBar.translatesAutoresizingMaskIntoConstraints = false
        usageBar.toolTip = "\(Int(remaining * 100))% \(localizedString("left")) · \(Int(usedPercent.rounded()))% \(localizedString("used"))"

        // Countdown bar (how much of the window's time is left until reset) — depletes toward the reset.
        let countdownBar = AITokensBarView(fraction: remainingFraction, color: countdownColor, severity: false)
        countdownBar.translatesAutoresizingMaskIntoConstraints = false

        let rf = ValueField(frame: .zero, resets)
        rf.font = NSFont.systemFont(ofSize: resetsSize, weight: .regular)
        rf.textColor = .secondaryLabelColor
        rf.translatesAutoresizingMaskIntoConstraints = false
        self.resetField = rf

        let updatedField = ValueField(frame: .zero, updated)
        updatedField.font = NSFont.systemFont(ofSize: resetsSize, weight: .regular)
        updatedField.textColor = .tertiaryLabelColor
        updatedField.alignment = .right
        updatedField.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(titleField)
        self.addSubview(percentField)
        self.addSubview(usageBar)
        self.addSubview(countdownBar)
        self.addSubview(rf)
        self.addSubview(updatedField)

        let m = Constants.Popup.margins
        let topPadding: CGFloat = compact ? 2 : 4
        let usageTopSpacing: CGFloat = compact ? 2 : 4
        let countdownTopSpacing: CGFloat = compact ? 1.5 : 3
        let resetTopSpacing: CGFloat = compact ? 1.5 : 3

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            titleField.topAnchor.constraint(equalTo: self.topAnchor, constant: topPadding),
            percentField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            percentField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            percentField.widthAnchor.constraint(equalToConstant: 44),

            usageBar.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            usageBar.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            usageBar.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: usageTopSpacing),
            usageBar.heightAnchor.constraint(equalToConstant: usageBarHeight),

            countdownBar.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            countdownBar.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            countdownBar.topAnchor.constraint(equalTo: usageBar.bottomAnchor, constant: countdownTopSpacing),
            countdownBar.heightAnchor.constraint(equalToConstant: countdownBarHeight),

            rf.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            rf.topAnchor.constraint(equalTo: countdownBar.bottomAnchor, constant: resetTopSpacing),
            updatedField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            updatedField.centerYAnchor.constraint(equalTo: rf.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize { NSSize(width: bounds.width, height: self.isCompact ? 42 : 60) }

    // MARK: - Mouse hover to swap countdown ↔ absolute reset time

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = self.hoverTrackingArea { self.removeTrackingArea(ta) }
        // The hover zone covers the full row (simple and reliable).
        let ta = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(ta)
        self.hoverTrackingArea = ta

        // Check if the mouse is already inside when this view is (re)created.
        // This prevents a flash of countdown text when the row is rebuilt every second
        // while the user is hovering.
        if let window = self.window {
            let loc = window.mouseLocationOutsideOfEventStream
            let localLoc = self.convert(loc, from: nil)
            if self.bounds.contains(localLoc) {
                self.resetField.stringValue = self.hoverText
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        self.resetField.stringValue = self.hoverText
    }

    override func mouseExited(with event: NSEvent) {
        self.resetField.stringValue = self.countdownText
    }
}

// MARK: - Usage bar (color zones: green → orange → red as usage climbs).

private final class AITokensBarView: NSView {
    private let fraction: Double
    private let color: NSColor
    /// When true, tints by usage severity (green → orange → red); when false, fills with `color`.
    private let severity: Bool

    init(fraction: Double, color: NSColor, severity: Bool = true) {
        self.fraction = fraction
        self.color = color
        self.severity = severity
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        track.fill()

        let fillW = max(0, min(bounds.width, bounds.width * CGFloat(self.fraction)))
        guard fillW > 0.5 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: fillW, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        self.fillColor.setFill()
        fill.fill()
    }

    private var fillColor: NSColor {
        guard self.severity else { return self.color }
        // `fraction` is the remaining amount: provider color while there's plenty left,
        // then orange, then red as it runs low.
        if self.fraction <= 0.10 { return .systemRed }
        if self.fraction <= 0.25 { return .systemOrange }
        return self.color
    }
}
