//
//  AITokensPreview.swift
//  Stats
//
//  Module preview: per-provider summary (current usage, upcoming reset, last update)
//  plus a shared usage-over-time line chart with one colored line per provider+window.
//
//  The chart is ONE continuous timeline. Its only state is an absolute visible window
//  [viewStart, viewEnd] in unix seconds. Zoom and pan move that window directly; the
//  range toggle (5H…1Y) is just a shortcut that jumps the window to a preset span. Zoom
//  is free between a 1-hour floor and the full span of all recorded data.
//

import Cocoa
import Kit

internal final class AITokensPreview: PreviewWrapper {
    private let usageChart = AITokensMultiLineChart(fixedYMax: 100) { "\(Int($0.rounded()))%" }
    private var signature: String = ""
    private var lastUsage = AITokens_Usage()
    private var selectedSeriesKey: (providerId: String, windowName: String)? = nil

    private let rangeControl: NSSegmentedControl = {
        let c = NSSegmentedControl(
            labels: AITokensRange.allCases.map { $0.title },
            trackingMode: .selectOne, target: nil, action: nil
        )
        c.segmentStyle = .rounded
        c.controlSize = .small
        c.translatesAutoresizingMaskIntoConstraints = false
        return c
    }()
    private var selectedRange: AITokensRange = .month

    public init(_ module: ModuleType) {
        super.init(type: module)
        let saved = Store.shared.int(key: "AITokens_rangeIndex", defaultValue: AITokensRange.month.rawValue)
        self.selectedRange = AITokensRange(rawValue: saved) ?? .month
        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.rangeChanged(_:))
        self.rangeControl.selectedSegment = self.selectedRange.rawValue

        // Continuous zoom/pan only moves the highlight to the closest preset — it never changes
        // the persisted range or recomputes the viewport. The chart owns the viewport.
        self.usageChart.onZoomOrPan = { [weak self] range in
            self?.rangeControl.selectedSegment = range.rawValue
        }

        self.rebuild(AITokens_Usage())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func usageCallback(_ value: AITokens_Usage) {
        DispatchQueue.main.async {
            // Rebuild the static sections only when the set of provider/window rows changes.
            let signature = value.providers.filter { $0.enabled }.map { p in
                "\(p.id):" + p.windows.filter { !$0.isStale }.map { $0.name }.joined(separator: ",")
            }.joined(separator: "|") + (value.hasData ? "" : "·empty")
            if signature != self.signature {
                self.rebuild(value)
            } else {
                self.refresh(value)
            }
        }
    }

    private var summaryPanels: [String: AITokensSummaryPanel] = [:]

    private func rebuild(_ value: AITokens_Usage) {
        self.subviews.forEach { $0.removeFromSuperview() }
        self.summaryPanels.removeAll()
        self.signature = value.providers.filter { $0.enabled }.map { p in
            "\(p.id):" + p.windows.filter { !$0.isStale }.map { $0.name }.joined(separator: ",")
        }.joined(separator: "|") + (value.hasData ? "" : "·empty")

        guard value.hasData else {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Status"), component: ValueField(frame: .zero, value.statusMessage ?? localizedString("No usage history found")))
            ]))
            self.addArrangedSubview(NSView())
            return
        }

        // Usage-history chart on top (with the range toggle), above the per-provider model summaries.
        self.addArrangedSubview(PreferencesSection(title: localizedString("Usage history"), [
            self.rangeRow(),
            self.chartContainer(self.usageChart)
        ]))

        for provider in value.providers where provider.enabled && provider.windows.contains(where: { !$0.isStale }) {
            let panel = AITokensSummaryPanel(provider: provider) { [weak self] providerId, windowName in
                self?.rowClicked(providerId: providerId, windowName: windowName)
            }
            self.summaryPanels[provider.id] = panel
            self.addArrangedSubview(panel.section)
        }

        self.addArrangedSubview(NSView())
        self.refresh(value)
        self.updateRowSelectionStates()
    }

    private func refresh(_ value: AITokens_Usage) {
        self.lastUsage = value
        let now = Date()
        var series: [AITokensMultiLineChart.Series] = []
        for provider in value.providers where provider.enabled {
            self.summaryPanels[provider.id]?.update(provider, now: now)
            for (index, window) in provider.windows.enumerated() where !window.isStale {
                let points: [DoubleValue] = window.entries.map {
                    var dv = DoubleValue($0.usedPercent)
                    dv.ts = $0.capturedAt
                    return dv
                }
                guard !points.isEmpty else { continue }
                series.append(.init(
                    name: "\(provider.name) \(window.displayName)",
                    color: provider.color(forWindowIndex: index),
                    points: points,
                    upcomingReset: aiTokensUpcomingReset(window, from: now),
                    windowMinutes: window.windowMinutes,
                    windowName: window.name,
                    providerId: provider.id
                ))
            }
        }

        let historical = aiTokensHistoricalResets(value.providers, before: now)
        self.updateRangeAvailability(value, now: now)
        // The chart keeps its own absolute viewport across refreshes; it only uses `initialPreset`
        // the very first time data arrives, to pick a sensible starting window.
        self.usageChart.setData(
            series: series, now: now,
            historicalResets: historical,
            initialPreset: self.selectedRange
        )
        self.updateRowSelectionStates()
    }

    private func rowClicked(providerId: String, windowName: String) {
        if selectedSeriesKey?.providerId == providerId && selectedSeriesKey?.windowName == windowName {
            selectedSeriesKey = nil
        } else {
            selectedSeriesKey = (providerId, windowName)
        }
        self.usageChart.setHighlightedSeries(providerId: selectedSeriesKey?.providerId, windowName: selectedSeriesKey?.windowName)
        self.updateRowSelectionStates()
    }

    private func updateRowSelectionStates() {
        for panel in self.summaryPanels.values {
            panel.updateSelection(selectedKey: self.selectedSeriesKey)
        }
    }

    /// Enables only the ranges the data actually spans; the rest are greyed out. The shortest
    /// range stays enabled as a floor so there is always a usable option.
    private func updateRangeAvailability(_ value: AITokens_Usage, now: Date) {
        let timestamps = value.providers.flatMap { $0.windows.flatMap { $0.entries.map { $0.capturedAt } } }
        let span = (timestamps.max()?.timeIntervalSince(timestamps.min() ?? now)) ?? 0
        var enabledRanges: [AITokensRange] = []
        for range in AITokensRange.allCases {
            // Enable a range when there is data the next-smaller range can't already show, so all
            // recorded history stays reachable (the shortest range is always available as a floor).
            let enabled: Bool
            if let prev = AITokensRange(rawValue: range.rawValue - 1) {
                enabled = span > prev.lookback
            } else {
                enabled = true
            }
            self.rangeControl.setEnabled(enabled, forSegment: range.rawValue)
            if enabled { enabledRanges.append(range) }
        }
        // If the saved range is no longer available, fall back to the largest enabled one.
        if !enabledRanges.contains(self.selectedRange), let fallback = enabledRanges.last {
            self.selectedRange = fallback
            Store.shared.set(key: "AITokens_rangeIndex", value: fallback.rawValue)
        }
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let range = AITokensRange(rawValue: sender.selectedSegment) else { return }
        self.selectedRange = range
        Store.shared.set(key: "AITokens_rangeIndex", value: range.rawValue)
        // Jump the continuous viewport to this preset span (animated). Data is unchanged.
        self.usageChart.applyPreset(range, animated: true)
    }

    private func rangeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.addArrangedSubview(NSView())          // push the control to the right
        row.addArrangedSubview(self.rangeControl)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    private func chartContainer(_ chart: NSView) -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin * 2
        view.heightAnchor.constraint(equalToConstant: 150).isActive = true
        view.addArrangedSubview(chart)
        return view
    }
}

// MARK: - Per-provider summary (current usage / reset / updated per window)

private final class ClickableRow: NSStackView {
    var onClick: (() -> Void)?
    var isHovered: Bool = false {
        didSet {
            self.needsDisplay = true
        }
    }
    var isSelected: Bool = false {
        didSet {
            self.needsDisplay = true
        }
    }

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.trackingArea { self.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick?()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let color: NSColor
        if isSelected {
            color = NSColor.textColor.withAlphaComponent(0.08)
        } else if isHovered {
            color = NSColor.textColor.withAlphaComponent(0.04)
        } else {
            color = .clear
        }
        self.layer?.backgroundColor = color.cgColor
        self.layer?.cornerRadius = 4
    }
}

private final class AITokensSummaryPanel {
    private(set) var section: NSView
    private let provider: AITokens_Provider
    private var windowFields: [String: (used: NSTextField, reset: NSTextField, updated: NSTextField)] = [:]
    private var windowRows: [String: ClickableRow] = [:]

    init(provider: AITokens_Provider, onWindowClicked: @escaping (String, String) -> Void) {
        self.provider = provider
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin, left: Constants.Settings.margin,
            bottom: Constants.Settings.margin, right: Constants.Settings.margin
        )
        container.translatesAutoresizingMaskIntoConstraints = false

        for (index, window) in provider.windows.enumerated() where !window.isStale {
            let color = provider.color(forWindowIndex: index)
            let row = ClickableRow()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            
            let providerId = provider.id
            let windowName = window.name
            row.onClick = {
                onWindowClicked(providerId, windowName)
            }

            let swatch = ColorView(frame: NSRect(x: 0, y: 0, width: 8, height: 8), color: color, state: true, radius: 4)
            swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true

            let nameField = LabelField(frame: .zero, window.displayName)
            nameField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            nameField.widthAnchor.constraint(equalToConstant: 70).isActive = true

            let usedField = ValueField(frame: .zero, "—")
            usedField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            usedField.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let resetField = ValueField(frame: .zero, "—")
            resetField.font = NSFont.systemFont(ofSize: 11, weight: .regular)

            let updatedField = ValueField(frame: .zero, "—")
            updatedField.font = NSFont.systemFont(ofSize: 10, weight: .light)
            updatedField.textColor = .tertiaryLabelColor
            updatedField.alignment = .right

            row.addArrangedSubview(swatch)
            row.addArrangedSubview(nameField)
            row.addArrangedSubview(usedField)
            row.addArrangedSubview(resetField)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(updatedField)
            container.addArrangedSubview(row)

            self.windowFields[window.name] = (usedField, resetField, updatedField)
            self.windowRows[window.name] = row
        }

        self.section = PreferencesSection(title: provider.name, icon: aiTokensProviderIcon(provider.name), [container])
    }

    func update(_ provider: AITokens_Provider, now: Date) {
        for window in provider.windows where !window.isStale {
            guard let fields = self.windowFields[window.name], let latest = window.latest else { continue }
            fields.used.stringValue = "\(Int(latest.usedPercent.rounded()))%"
            if let upcoming = aiTokensUpcomingReset(window, from: now) {
                fields.reset.stringValue = "\(localizedString("resets")) \(aiTokensCountdown(to: upcoming, from: now)) · \(aiTokensAbsoluteDate(upcoming))"
            } else {
                fields.reset.stringValue = "\(localizedString("inactive")) · \(localizedString("last seen")) \(aiTokensRelativeAge(latest.capturedAt, from: now))"
            }
            fields.updated.stringValue = aiTokensRelativeAge(latest.capturedAt, from: now)
        }
    }

    func updateSelection(selectedKey: (providerId: String, windowName: String)?) {
        for (windowName, row) in windowRows {
            if let key = selectedKey {
                let isThis = key.providerId == provider.id && key.windowName == windowName
                row.isSelected = isThis
                row.alphaValue = isThis ? 1.0 : 0.4
            } else {
                row.isSelected = false
                row.alphaValue = 1.0
            }
        }
    }
}

// MARK: - Multi-series time chart (one colored line per provider+window)
//
// The chart renders every series on ONE shared, absolute time axis. The visible portion of
// that axis is [viewStart, viewEnd] (unix seconds). There is no per-range "base span" — zoom
// and pan mutate [viewStart, viewEnd] directly and it survives data refreshes unchanged, so
// the timeline is continuous and the zoom level is stable.

private final class AITokensMultiLineChart: NSView {
    struct Series {
        let name: String
        let color: NSColor
        let points: [DoubleValue]
        /// The next reset for this window, drawn as a dashed vertical marker (may be in the future).
        let upcomingReset: Date?
        /// Window length — longer windows (weekly/monthly) get more widely-spaced reset dots.
        let windowMinutes: Int
        let windowName: String
        let providerId: String
    }

    /// A projected sample, cached each draw so hover can hit-test against on-screen points.
    private struct Projected {
        let point: CGPoint
        let value: Double
        let date: Date
        let name: String
        let color: NSColor
        let providerId: String
        let windowName: String
    }

    /// A reset marker line, cached each draw so hover can show its date.
    private struct ResetMarker {
        let x: CGFloat
        let date: Date
        let label: String
        let color: NSColor
        let providerId: String
        let windowName: String
    }

    private var series: [Series] = []
    private var now: Date = Date()
    private var historicalResets: [AITokensHistoricalReset] = []
    private let fixedYMax: Double?
    private let yFormatter: (Double) -> String
    private let axisFormatter = DateFormatter()
    private let markerFormatter = DateFormatter()
    private let tooltipFormatter = DateFormatter()

    private var highlightedSeriesKey: (providerId: String, windowName: String)?

    func setHighlightedSeries(providerId: String?, windowName: String?) {
        if let providerId = providerId, let windowName = windowName {
            highlightedSeriesKey = (providerId, windowName)
        } else {
            highlightedSeriesKey = nil
        }
        self.needsDisplay = true
    }

    // MARK: - Viewport: the single source of truth (unix seconds)

    /// Currently rendered visible window. Animations interpolate this toward the targets.
    private var viewStart: TimeInterval = 0
    private var viewEnd: TimeInterval = 0
    /// Target visible window the animation glides toward (equal to the rendered values for
    /// direct gestures like pinch and 1:1 panning).
    private var targetViewStart: TimeInterval = 0
    private var targetViewEnd: TimeInterval = 0
    /// Set once the first non-empty data arrives and a starting window is chosen.
    private var viewportInitialized = false
    /// The content's right edge at the previous refresh, used to detect "parked at the live edge".
    private var prevContentMax: TimeInterval?

    /// Zoom floor: never show less than one hour (lets the user zoom past the 5h preset).
    private let minSpan: TimeInterval = 3_600
    /// The 5-hour preset span — also the smallest the zoom-out ceiling is ever allowed to be,
    /// so the "5H" button always works even with very little recorded data.
    private let fiveHourSpan: TimeInterval = 18_000

    private var isScrollingHorizontal = false
    var onZoomOrPan: ((AITokensRange) -> Void)?

    /// Display-link timer for smooth animated preset transitions.
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: CFTimeInterval = 0

    private var projected: [Projected] = []
    private var resetMarkers: [ResetMarker] = []
    private var hoverLocation: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(fixedYMax: Double?, yFormatter: @escaping (Double) -> String) {
        self.fixedYMax = fixedYMax
        self.yFormatter = yFormatter
        super.init(frame: .zero)
        self.axisFormatter.dateFormat = "d MMM"
        self.markerFormatter.dateFormat = "d MMM"
        self.tooltipFormatter.dateFormat = "d MMM, HH:mm"
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stopDisplayLink()
    }

    // MARK: - Content bounds & viewport clamping

    /// The full extent of everything that can be shown: from the earliest sample to the latest of
    /// (last sample, now, furthest upcoming reset). This is the outer boundary the viewport pans
    /// within and the limit of how far the user can zoom out ("all data").
    private func contentBounds() -> (min: TimeInterval, max: TimeInterval) {
        let dataTS = self.series.flatMap { $0.points.map { $0.ts.timeIntervalSince1970 } }
        let resetTS = self.series.compactMap { $0.upcomingReset?.timeIntervalSince1970 }
        let nowTS = self.now.timeIntervalSince1970
        let mn = dataTS.min() ?? (nowTS - self.fiveHourSpan)
        var mx = max(dataTS.max() ?? nowTS, nowTS)
        if let r = resetTS.max() { mx = max(mx, r) }
        if mx - mn < self.minSpan { mx = mn + self.minSpan }
        return (mn, mx)
    }

    /// Largest span the user may zoom out to: the whole data extent, floored at the 5h preset.
    private var maxSpan: TimeInterval {
        let (mn, mx) = self.contentBounds()
        return max(mx - mn, self.fiveHourSpan)
    }

    /// Clamp a proposed window so its span is within [minSpan, maxSpan] and it stays anchored to the
    /// content. When the span covers everything, the recent edge is pinned to the right.
    private func clampViewport(_ start: inout TimeInterval, _ end: inout TimeInterval) {
        let (cMin, cMax) = self.contentBounds()
        var span = end - start
        span = min(max(span, self.minSpan), self.maxSpan)
        let maxStart = cMax - span
        if maxStart <= cMin {
            start = cMax - span                     // span ≥ content → show all, recent pinned right
        } else {
            start = min(max(start, cMin), maxStart)
        }
        end = start + span
    }

    // MARK: - Data in

    func setData(series: [Series], now: Date, historicalResets: [AITokensHistoricalReset], initialPreset: AITokensRange) {
        self.series = series.filter { !$0.points.isEmpty }
        self.now = now
        self.historicalResets = historicalResets

        guard !self.series.isEmpty else {
            self.needsDisplay = true
            return
        }

        let (_, cMax) = self.contentBounds()
        if !self.viewportInitialized {
            self.applyPreset(initialPreset, animated: false)
            self.viewportInitialized = true
        } else if let prev = self.prevContentMax, self.targetViewEnd >= prev - 1 {
            // The user was parked at the live edge — keep following "now" as new data arrives.
            let span = self.targetViewEnd - self.targetViewStart
            self.targetViewEnd = cMax
            self.targetViewStart = cMax - span
            self.viewStart = self.targetViewStart
            self.viewEnd = self.targetViewEnd
            self.clampViewport(&self.viewStart, &self.viewEnd)
            self.targetViewStart = self.viewStart
            self.targetViewEnd = self.viewEnd
        } else {
            // Otherwise keep the user's window exactly where it is, only re-clamping to new bounds.
            self.clampViewport(&self.viewStart, &self.viewEnd)
            self.clampViewport(&self.targetViewStart, &self.targetViewEnd)
        }
        self.prevContentMax = cMax
        self.needsDisplay = true
    }

    /// Jump the viewport to a preset span anchored at "now" (plus the preset's forward extension so
    /// upcoming resets stay visible). Free zoom/pan afterwards is unaffected.
    func applyPreset(_ range: AITokensRange, animated: Bool) {
        guard !self.series.isEmpty else { return }
        let nowTS = self.now.timeIntervalSince1970
        var start = nowTS - range.lookback
        var end = nowTS + range.lookforward
        self.clampViewport(&start, &end)
        self.targetViewStart = start
        self.targetViewEnd = end
        if animated {
            self.ensureAnimating()
        } else {
            self.viewStart = start
            self.viewEnd = end
        }
        self.needsDisplay = true
    }

    // MARK: - CVDisplayLink animation engine (preset transitions only)

    private func startDisplayLink() {
        guard self.displayLink == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        self.lastFrameTime = CACurrentMediaTime()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let chart = Unmanaged<AITokensMultiLineChart>.fromOpaque(userInfo).takeUnretainedValue()
            chart.animationTick()
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(dl)
        self.displayLink = dl
    }

    private func stopDisplayLink() {
        guard let dl = self.displayLink else { return }
        CVDisplayLinkStop(dl)
        self.displayLink = nil
    }

    private func ensureAnimating() {
        self.startDisplayLink()
    }

    /// Called ~60 fps by the display link; glides the rendered window toward the target.
    private func animationTick() {
        let t = CACurrentMediaTime()
        let dt = min(t - self.lastFrameTime, 1.0 / 30.0)
        self.lastFrameTime = t

        let lerp = 1.0 - pow(0.0009, dt)   // snappy, frame-rate independent
        let dStart = self.targetViewStart - self.viewStart
        let dEnd = self.targetViewEnd - self.viewEnd
        let thresh = max(1.0, (self.targetViewEnd - self.targetViewStart) * 1e-5)

        var changed = false
        if abs(dStart) > thresh || abs(dEnd) > thresh {
            self.viewStart += dStart * lerp
            self.viewEnd += dEnd * lerp
            changed = true
        } else if dStart != 0 || dEnd != 0 {
            self.viewStart = self.targetViewStart
            self.viewEnd = self.targetViewEnd
            changed = true
        }

        if changed {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        } else {
            DispatchQueue.main.async { [weak self] in self?.stopDisplayLink() }
        }
    }

    // MARK: - Hover tracking

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

    // MARK: - Pan (scroll)

    /// Seconds of time per horizontal pixel for the current viewport.
    private func currentTimePerPixel() -> TimeInterval {
        let yAxisWidth: CGFloat = 34
        let chartWidth = max(1, self.bounds.width - yAxisWidth - 4)
        let span = max(self.viewEnd - self.viewStart, 1)
        return span / Double(chartWidth)
    }

    /// Shift the whole viewport by a horizontal gesture delta (in points). Direct 1:1 — no animation.
    private func panBy(_ dxPoints: CGFloat) {
        let delta = TimeInterval(dxPoints) * self.currentTimePerPixel()
        // Drag the content with the fingers: swiping right reveals earlier time.
        self.viewStart -= delta
        self.viewEnd -= delta
        self.clampViewport(&self.viewStart, &self.viewEnd)
        self.targetViewStart = self.viewStart
        self.targetViewEnd = self.viewEnd
        self.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard self.viewportInitialized else { super.scrollWheel(with: event); return }
        let hasPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty

        if hasPhase {
            // --- Trackpad (precise scrolling with gesture phases) ---
            if event.phase == .began {
                self.isScrollingHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            if self.isScrollingHorizontal {
                if event.scrollingDeltaX != 0 {
                    // Apply scroll acceleration for fast swipes, but keep slow swipes 1:1.
                    let dx = event.scrollingDeltaX
                    let absDx = abs(dx)
                    let threshold: CGFloat = 2.0
                    var multiplier: CGFloat = 1.0
                    if absDx > threshold {
                        multiplier = min(10.0, 1.0 + (absDx - threshold) * 0.25)
                    }
                    self.panBy(dx * multiplier)
                }
                if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                    self.isScrollingHorizontal = false
                    self.notifyZoomOrPan()
                }
                return
            }
        } else {
            // --- Mouse scroll wheel (discrete, non-precise) ---
            let dx = event.scrollingDeltaX
            if dx != 0 {
                self.panBy(dx * 10.0)   // mouse wheels report small deltas; scale up for usable panning
                self.notifyZoomOrPan()
                return
            }
        }

        super.scrollWheel(with: event)
    }

    // MARK: - Zoom (pinch)

    override func magnify(with event: NSEvent) {
        guard self.viewportInitialized else { return }
        let loc = self.convert(event.locationInWindow, from: nil)
        let yAxisWidth: CGFloat = 34
        let chartMinX = yAxisWidth
        let chartWidth = max(1, self.bounds.width - yAxisWidth - 4)
        let pct = min(max(Double((loc.x - chartMinX) / chartWidth), 0.0), 1.0)

        // Keep the time under the cursor fixed while the span changes around it.
        let curSpan = max(self.viewEnd - self.viewStart, self.minSpan)
        let tMouse = self.viewStart + pct * curSpan

        let k = 1.0 / (1.0 + Double(event.magnification))
        var newSpan = curSpan * k
        newSpan = min(max(newSpan, self.minSpan), self.maxSpan)

        var newStart = tMouse - pct * newSpan
        var newEnd = newStart + newSpan
        self.clampViewport(&newStart, &newEnd)

        // Pinch is 1:1 (no animation lag): set rendered and target together.
        self.viewStart = newStart
        self.viewEnd = newEnd
        self.targetViewStart = newStart
        self.targetViewEnd = newEnd
        self.needsDisplay = true

        if event.phase == .ended || event.phase == .cancelled {
            self.notifyZoomOrPan()
        }
    }

    /// Map the current span to the closest preset, so the segmented control can highlight it.
    private func notifyZoomOrPan() {
        let currentSpan = self.viewEnd - self.viewStart
        var closest = AITokensRange.day
        var minDiff = Double.greatestFiniteMagnitude
        for r in AITokensRange.allCases {
            let rSpan = r.lookback + r.lookforward
            let diff = abs(currentSpan - rSpan)
            if diff < minDiff { minDiff = diff; closest = r }
        }
        self.onZoomOrPan?(closest)
    }

    private var darkMode: Bool {
        self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Draw

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
            str.draw(at: CGPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2), withAttributes: attrs)
            return
        }

        let yAxisWidth: CGFloat = 34
        let xAxisHeight: CGFloat = 13
        let topMargin: CGFloat = 4
        let chartRect = NSRect(
            x: yAxisWidth,
            y: xAxisHeight,
            width: max(1, self.bounds.width - yAxisWidth - 4),
            height: max(1, self.bounds.height - xAxisHeight - topMargin - 2)
        )

        let yMax = max(1, self.fixedYMax ?? (self.series.flatMap { $0.points.map { $0.value } }.max() ?? 1))

        // The visible time domain is simply the current viewport.
        let nowTS = self.now.timeIntervalSince1970
        let tMin = self.viewStart
        let tMax = self.viewEnd
        let span = max(tMax - tMin, 1)

        // Short spans (≤ ~2 days) read as times; longer spans as calendar dates.
        if span <= 2 * 86_400 {
            self.axisFormatter.dateFormat = "HH:mm"
            self.markerFormatter.dateFormat = "HH:mm"
        } else {
            self.axisFormatter.dateFormat = "d MMM"
            self.markerFormatter.dateFormat = "d MMM"
        }

        func xFor(_ ts: Double) -> CGFloat { chartRect.minX + CGFloat((ts - tMin) / span) * chartRect.width }
        func yFor(_ v: Double) -> CGFloat { chartRect.minY + CGFloat(min(max(v, 0), yMax) / yMax) * chartRect.height }

        let hairline = 1 / (NSScreen.main?.backingScaleFactor ?? 1)

        // Horizontal grid + y labels.
        let gridColor = (self.darkMode ? NSColor.white : NSColor.black).withAlphaComponent(0.06)
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

        // X labels: evenly spaced dates across the axis (clamped to stay on-screen).
        let tickCount = 4
        var lastLabelMaxX: CGFloat = -.greatestFiniteMagnitude
        for i in 0..<tickCount {
            let t = tMin + span * Double(i) / Double(tickCount - 1)
            let str = self.axisFormatter.string(from: Date(timeIntervalSince1970: t)) as NSString
            let size = str.size(withAttributes: labelAttrs)
            var lx = xFor(t) - size.width / 2
            lx = max(chartRect.minX, min(lx, self.bounds.width - size.width))
            guard lx > lastLabelMaxX + 6 else { continue }  // skip if it would overlap the previous label
            str.draw(at: CGPoint(x: lx, y: 0), withAttributes: labelAttrs)
            lastLabelMaxX = lx + size.width
        }

        // Everything below is data inside the plot — clip it so off-screen samples / markers
        // can't spill over the axes.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: chartRect).addClip()

        self.resetMarkers.removeAll()

        let nowX = min(max(xFor(nowTS), chartRect.minX), chartRect.maxX)

        // Historical (already-happened) fixed resets: thin vertical lines in a light tint of the
        // provider's color, so it's clear which provider each past reset belongs to.
        for reset in self.historicalResets {
            let ts = reset.date.timeIntervalSince1970
            guard ts >= tMin, ts <= tMax else { continue }
            let x = xFor(ts)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = hairline
            
            let isHighlighted = self.highlightedSeriesKey == nil || (self.highlightedSeriesKey?.providerId == reset.providerId && self.highlightedSeriesKey?.windowName == reset.windowName)
            let opacity: CGFloat = isHighlighted ? 0.35 : 0.05
            reset.color.withAlphaComponent(opacity).setStroke()
            line.stroke()
            self.resetMarkers.append(ResetMarker(x: x, date: reset.date, label: localizedString("Past reset"), color: reset.color, providerId: reset.providerId, windowName: reset.windowName))
        }

        // Upcoming-reset markers: a dotted vertical line per window, in its color. The dots are spaced
        // wider apart for longer windows (weekly / monthly) than for the short session window.
        var drawnResetMinutes = Set<Int>()
        for s in self.series {
            guard let reset = s.upcomingReset else { continue }
            let ts = reset.timeIntervalSince1970
            guard ts >= tMin, ts <= tMax else { continue }
            let minuteKey = Int(ts / 60)
            guard drawnResetMinutes.insert(minuteKey).inserted else { continue }
            let x = xFor(ts)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = max(hairline, 1)
            let dash: [CGFloat] = s.windowMinutes >= 1440 ? [2, 9] : [1, 3]   // ≥1 day → spaced dots; session → many dots
            line.setLineDash(dash, count: 2, phase: 0)
            
            let isHighlighted = self.highlightedSeriesKey == nil || (self.highlightedSeriesKey?.providerId == s.providerId && self.highlightedSeriesKey?.windowName == s.windowName)
            let opacity: CGFloat = isHighlighted ? 0.9 : 0.1
            s.color.withAlphaComponent(opacity).setStroke()
            line.stroke()
            
            if abs(x - nowX) >= 10 {
                self.drawVerticalLabel(self.markerFormatter.string(from: reset), atX: x, chartRect: chartRect, color: s.color.withAlphaComponent(opacity), font: labelFont)
            }
            self.resetMarkers.append(ResetMarker(x: x, date: reset, label: "\(s.name) \(localizedString("resets"))", color: s.color, providerId: s.providerId, windowName: s.windowName))
        }

        // "Now" marker: a dotted red vertical line (no label).
        let nowLine = NSBezierPath()
        nowLine.move(to: CGPoint(x: nowX, y: chartRect.minY))
        nowLine.line(to: CGPoint(x: nowX, y: chartRect.maxY))
        nowLine.lineWidth = hairline
        nowLine.setLineDash([1, 2], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        nowLine.stroke()

        // One line per series (drawn on top of the markers); cache projected points for hover.
        self.projected.removeAll()
        for s in self.series {
            let pts = s.points.sorted { $0.ts < $1.ts }
            
            let isHighlighted = self.highlightedSeriesKey == nil || (self.highlightedSeriesKey?.providerId == s.providerId && self.highlightedSeriesKey?.windowName == s.windowName)
            let opacity: CGFloat = isHighlighted ? 1.0 : 0.15
            
            let strokeColor = s.color.withAlphaComponent(opacity)
            strokeColor.setStroke()
            strokeColor.setFill()
            for p in pts {
                self.projected.append(Projected(
                    point: CGPoint(x: xFor(p.ts.timeIntervalSince1970), y: yFor(p.value)),
                    value: p.value, date: p.ts, name: s.name, color: s.color,
                    providerId: s.providerId, windowName: s.windowName
                ))
            }
            if pts.count == 1 {
                let p = CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value))
                NSBezierPath(ovalIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            // Reset boundaries for this series (the same vertical lines drawn above). Used to break
            // the line across a gap that spans a reset: usage held flat up to the reset, then dropped
            // to zero at the reset and climbing to the next sample — never a slope down through it.
            var resetTimes = self.historicalResets
                .filter { $0.providerId == s.providerId && $0.windowName == s.windowName }
                .map { $0.date.timeIntervalSince1970 }
            if let up = s.upcomingReset { resetTimes.append(up.timeIntervalSince1970) }
            resetTimes.sort()
            let yZero = yFor(0)

            let path = NSBezierPath()
            path.move(to: CGPoint(x: xFor(pts[0].ts.timeIntervalSince1970), y: yFor(pts[0].value)))
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let aTS = a.ts.timeIntervalSince1970, bTS = b.ts.timeIntervalSince1970
                if let reset = resetTimes.first(where: { $0 > aTS && $0 < bTS }) {
                    let rx = xFor(reset)
                    path.line(to: CGPoint(x: rx, y: yFor(a.value)))   // hold flat until the reset
                    path.line(to: CGPoint(x: rx, y: yZero))           // drop to zero at the reset
                    path.line(to: CGPoint(x: xFor(bTS), y: yFor(b.value)))  // climb to the next sample
                } else {
                    path.line(to: CGPoint(x: xFor(bTS), y: yFor(b.value)))
                }
            }
            let isSession = s.windowName.lowercased().contains("session") || s.windowMinutes < 1440
            path.lineWidth = isSession ? hairline : max(hairline, 1)
            path.lineJoinStyle = .round
            path.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()   // end plot clip

        self.drawHoverTooltip(chartRect: chartRect, textColor: textColor)
    }

    /// Shows a tooltip for whatever is under the cursor: a reset line (its date) or the nearest sample.
    private func drawHoverTooltip(chartRect: NSRect, textColor: NSColor) {
        guard let loc = self.hoverLocation else { return }

        // Nearest sample to the cursor (weighting X so we follow the line the cursor is over).
        var nearestPoint: Projected?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in self.projected {
            if let highlighted = self.highlightedSeriesKey {
                if p.providerId != highlighted.providerId || p.windowName != highlighted.windowName {
                    continue
                }
            }
            let dx = p.point.x - loc.x
            let dy = p.point.y - loc.y
            let dist = dx * dx * 2 + dy * dy
            if dist < bestDist { bestDist = dist; nearestPoint = p }
        }
        let pointDX = nearestPoint.map { abs($0.point.x - loc.x) } ?? .greatestFiniteMagnitude

        // Nearest reset line (thin, so it needs a close cursor).
        var nearestMarker: ResetMarker?
        var markerDX = CGFloat.greatestFiniteMagnitude
        for m in self.resetMarkers {
            if let highlighted = self.highlightedSeriesKey {
                if m.providerId != highlighted.providerId || m.windowName != highlighted.windowName {
                    continue
                }
            }
            let dx = abs(m.x - loc.x)
            if dx < markerDX { markerDX = dx; nearestMarker = m }
        }

        // Prefer the reset line when the cursor is right on it (and closer than any sample).
        if let m = nearestMarker, markerDX <= 4, markerDX < pointDX {
            // Highlight the hovered line: solid, brighter and thicker.
            let highlight = NSBezierPath()
            highlight.move(to: CGPoint(x: m.x, y: chartRect.minY))
            highlight.line(to: CGPoint(x: m.x, y: chartRect.maxY))
            highlight.lineWidth = 1
            m.color.setStroke()
            highlight.stroke()

            let text = "\(m.label) · \(self.tooltipFormatter.string(from: m.date))"
            self.drawTooltipBox(text, anchorX: m.x, anchorY: loc.y, textColor: textColor)
            return
        }

        guard let hit = nearestPoint, pointDX < 40 else { return }

        // Emphasise the hovered point.
        hit.color.setFill()
        NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5)).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: hit.point.x - 2.5, y: hit.point.y - 2.5, width: 5, height: 5))
        ring.lineWidth = 1
        ring.stroke()

        let text = "\(hit.name) · \(Int(hit.value.rounded()))% · \(self.tooltipFormatter.string(from: hit.date))"
        self.drawTooltipBox(text, anchorX: hit.point.x, anchorY: hit.point.y, textColor: textColor)
    }

    /// Draws a rounded tooltip box containing `text`, placed near (anchorX, anchorY) and flipped
    /// to stay within the view bounds.
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

    /// Draws `text` rotated 90° upward, just right of a vertical marker line.
    private func drawVerticalLabel(_ text: String, atX x: CGFloat, chartRect: NSRect, color: NSColor, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // If the line is near the right edge, place the label on its left so it stays on-screen.
        let nearRight = x > self.bounds.width - 14
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: x + (nearRight ? -3 : 4), yBy: chartRect.minY + 2)
        t.rotate(byDegrees: 90)
        t.concat()
        (text as NSString).draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
