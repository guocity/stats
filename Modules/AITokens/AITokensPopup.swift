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

    public override func appear() {
        self.replay(self.cache, render: self.render)
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
        for provider in providers {
            self.stack.addArrangedSubview(separatorView(provider.name, width: self.contentWidth))
            for (index, window) in provider.windows.enumerated() where !window.isStale {
                guard let latest = window.latest else { continue }
                let remainingFraction: Double
                let countdownColor: NSColor
                let resetsText: String
                let resetTooltip: String
                if let upcoming = aiTokensUpcomingReset(window, from: now) {
                    // Fraction of the window's time still remaining (full just after a reset, empty at reset).
                    let windowSec = Double(window.windowMinutes * 60)
                    let remainingSec = upcoming.timeIntervalSince(now)
                    remainingFraction = windowSec > 0 ? max(0, min(1, remainingSec / windowSec)) : 0
                    // Vibrant violet normally (blue-leaning so it doesn't read as pink); red under an hour.
                    let vibrantPurple = NSColor(srgbRed: 0.52, green: 0.32, blue: 0.90, alpha: 1)
                    countdownColor = remainingSec < 3600 ? .systemRed : vibrantPurple
                    resetsText = "\(localizedString("resets")) \(aiTokensCountdown(to: upcoming, from: now)) · \(aiTokensAbsoluteDate(upcoming))"
                    resetTooltip = "\(window.lengthLabel) \(localizedString("window")) · \(localizedString("resets")) \(aiTokensCountdown(to: upcoming, from: now))"
                } else {
                    // Inactive window (provider stopped reporting it) — show last-known usage, no countdown.
                    remainingFraction = 0
                    countdownColor = .tertiaryLabelColor
                    resetsText = "\(localizedString("inactive")) · \(localizedString("last seen")) \(aiTokensRelativeAge(latest.capturedAt, from: now))"
                    resetTooltip = resetsText
                }
                self.stack.addArrangedSubview(AITokensWindowRow(
                    width: self.contentWidth,
                    title: window.displayName,
                    usedPercent: latest.usedPercent,
                    color: provider.color(forWindowIndex: index),
                    remainingFraction: remainingFraction,
                    countdownColor: countdownColor,
                    resetTooltip: resetTooltip,
                    resets: resetsText,
                    updated: "\(localizedString("updated")) \(aiTokensRelativeAge(latest.capturedAt, from: now))"
                ))
            }
        }
        self.scheduleHeightUpdate()
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
    private static let height: CGFloat = 60

    init(width: CGFloat, title: String, usedPercent: Double, color: NSColor,
         remainingFraction: Double, countdownColor: NSColor, resetTooltip: String, resets: String, updated: String) {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: width).isActive = true
        self.heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        let titleField = LabelField(frame: .zero, title)
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .textColor
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let percentField = ValueField(frame: .zero, "\(Int(usedPercent.rounded()))%")
        percentField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
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
        countdownBar.toolTip = resetTooltip

        let resetField = ValueField(frame: .zero, resets)
        resetField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        resetField.textColor = .secondaryLabelColor
        resetField.translatesAutoresizingMaskIntoConstraints = false

        let updatedField = ValueField(frame: .zero, updated)
        updatedField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        updatedField.textColor = .tertiaryLabelColor
        updatedField.alignment = .right
        updatedField.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(titleField)
        self.addSubview(percentField)
        self.addSubview(usageBar)
        self.addSubview(countdownBar)
        self.addSubview(resetField)
        self.addSubview(updatedField)

        let m = Constants.Popup.margins
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            titleField.topAnchor.constraint(equalTo: self.topAnchor, constant: 4),
            percentField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            percentField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            percentField.widthAnchor.constraint(equalToConstant: 44),

            usageBar.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            usageBar.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            usageBar.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            usageBar.heightAnchor.constraint(equalToConstant: 6),

            countdownBar.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            countdownBar.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            countdownBar.topAnchor.constraint(equalTo: usageBar.bottomAnchor, constant: 3),
            countdownBar.heightAnchor.constraint(equalToConstant: 2.5),

            resetField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: m),
            resetField.topAnchor.constraint(equalTo: countdownBar.bottomAnchor, constant: 3),
            updatedField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -m),
            updatedField.centerYAnchor.constraint(equalTo: resetField.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize { NSSize(width: bounds.width, height: Self.height) }
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
