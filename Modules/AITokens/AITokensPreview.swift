//
//  AITokensPreview.swift
//  Stats
//
//  Module preview: per-provider summary (current usage, upcoming reset, last update)
//  plus a shared usage-over-time line chart with one colored line per provider+window.
//

import Cocoa
import Kit

internal final class AITokensPreview: PreviewWrapper {
    private let usageChart = AITokensMultiLineChart(fixedYMax: 100) { "\(Int($0.rounded()))%" }
    private var signature: String = ""
    private var lastUsage = AITokens_Usage()

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
        self.rebuild(AITokens_Usage())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func usageCallback(_ value: AITokens_Usage) {
        DispatchQueue.main.async {
            // Rebuild the static sections only when the set of provider/window rows changes.
            let signature = value.providers.map { p in
                "\(p.id):" + p.windows.map { $0.name }.joined(separator: ",")
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
        self.signature = value.providers.map { p in
            "\(p.id):" + p.windows.map { $0.name }.joined(separator: ",")
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

        for provider in value.providers where !provider.windows.isEmpty {
            let panel = AITokensSummaryPanel(provider: provider)
            self.summaryPanels[provider.id] = panel
            self.addArrangedSubview(panel.section)
        }

        self.addArrangedSubview(NSView())
        self.refresh(value)
    }

    private func refresh(_ value: AITokens_Usage) {
        self.lastUsage = value
        let now = Date()
        var series: [AITokensMultiLineChart.Series] = []
        for provider in value.providers {
            self.summaryPanels[provider.id]?.update(provider, now: now)
            for (index, window) in provider.windows.enumerated() {
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
                    windowMinutes: window.windowMinutes
                ))
            }
        }

        let historical = aiTokensHistoricalResets(value.providers, before: now)
        self.updateRangeAvailability(value, now: now)
        let window = self.visibleWindow(value, now: now)
        self.usageChart.setData(
            series: series, now: now,
            visibleStart: window.start, visibleEnd: window.end,
            historicalResets: historical
        )
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
        self.rangeControl.selectedSegment = self.selectedRange.rawValue
    }

    /// The [start, end] the chart should show for the selected range. `start` is clamped to the
    /// earliest sample so we never render empty space to the left; `end` extends forward so the
    /// upcoming reset is on-screen.
    private func visibleWindow(_ value: AITokens_Usage, now: Date) -> (start: Date, end: Date) {
        let timestamps = value.providers.flatMap { $0.windows.flatMap { $0.entries.map { $0.capturedAt } } }
        let earliest = timestamps.min() ?? now.addingTimeInterval(-self.selectedRange.lookback)
        let start = max(now.addingTimeInterval(-self.selectedRange.lookback), earliest)
        let end = now.addingTimeInterval(self.selectedRange.lookforward)
        return (start, end)
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let range = AITokensRange(rawValue: sender.selectedSegment) else { return }
        self.selectedRange = range
        Store.shared.set(key: "AITokens_rangeIndex", value: range.rawValue)
        self.refresh(self.lastUsage)
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

private final class AITokensSummaryPanel {
    private(set) var section: NSView
    private var windowFields: [String: (used: NSTextField, reset: NSTextField, updated: NSTextField)] = [:]

    init(provider: AITokens_Provider) {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin, left: Constants.Settings.margin,
            bottom: Constants.Settings.margin, right: Constants.Settings.margin
        )
        container.translatesAutoresizingMaskIntoConstraints = false

        for (index, window) in provider.windows.enumerated() {
            let color = provider.color(forWindowIndex: index)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY

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
        }

        self.section = PreferencesSection(title: provider.name, [container])
    }

    func update(_ provider: AITokens_Provider, now: Date) {
        for window in provider.windows {
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
}

// MARK: - Multi-series time chart (one colored line per provider+window)

private final class AITokensMultiLineChart: NSView {
    struct Series {
        let name: String
        let color: NSColor
        let points: [DoubleValue]
        /// The next reset for this window, drawn as a dashed vertical marker (may be in the future).
        let upcomingReset: Date?
        /// Window length — longer windows (weekly/monthly) get more widely-spaced reset dots.
        let windowMinutes: Int
    }

    /// A projected sample, cached each draw so hover can hit-test against on-screen points.
    private struct Projected {
        let point: CGPoint
        let value: Double
        let date: Date
        let name: String
        let color: NSColor
    }

    private var series: [Series] = []
    private var now: Date = Date()
    private var visibleStart: Date?
    private var visibleEnd: Date?
    private var historicalResets: [AITokensHistoricalReset] = []
    private let fixedYMax: Double?
    private let yFormatter: (Double) -> String
    private let axisFormatter = DateFormatter()
    private let markerFormatter = DateFormatter()
    private let tooltipFormatter = DateFormatter()

    /// A reset marker line, cached each draw so hover can show its date.
    private struct ResetMarker {
        let x: CGFloat
        let date: Date
        let label: String
        let color: NSColor
    }

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

    func setData(series: [Series], now: Date, visibleStart: Date?, visibleEnd: Date?, historicalResets: [AITokensHistoricalReset]) {
        self.series = series.filter { !$0.points.isEmpty }
        self.now = now
        self.visibleStart = visibleStart
        self.visibleEnd = visibleEnd
        self.historicalResets = historicalResets
        self.needsDisplay = true
    }

    private var darkMode: Bool {
        self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
            str.draw(at: CGPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2), withAttributes: attrs)
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

        let yMax = max(1, self.fixedYMax ?? (self.series.flatMap { $0.points.map { $0.value } }.max() ?? 1))

        // Time domain. Prefer the explicit visible window (the range toggle); otherwise auto-fit to
        // the data plus the now / upcoming-reset markers.
        let dataTS = self.series.flatMap { $0.points.map { $0.ts.timeIntervalSince1970 } }
        let resetTS = self.series.compactMap { $0.upcomingReset?.timeIntervalSince1970 }
        let nowTS = self.now.timeIntervalSince1970
        let tMin: Double
        let tMax: Double
        if let vs = self.visibleStart?.timeIntervalSince1970, let ve = self.visibleEnd?.timeIntervalSince1970, ve > vs {
            tMin = vs
            tMax = ve
        } else {
            tMin = dataTS.min() ?? nowTS
            tMax = max((dataTS.max() ?? nowTS), nowTS, resetTS.max() ?? nowTS)
        }
        let span = tMax > tMin ? tMax - tMin : 1

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

        // X labels: evenly spaced calendar dates across the axis (clear "d MMM", clamped to stay on-screen).
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

        // Everything below is data inside the plot — clip it so zoomed-out samples / markers
        // can't spill over the axes.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: chartRect).addClip()

        self.resetMarkers.removeAll()

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
            reset.color.withAlphaComponent(0.35).setStroke()
            line.stroke()
            self.resetMarkers.append(ResetMarker(x: x, date: reset.date, label: localizedString("Past reset"), color: reset.color))
        }

        // Upcoming-reset markers: a dotted vertical line per window, in its color. The dots are spaced
        // wider apart for longer windows (weekly / monthly) than for the short session window.
        var drawnResetMinutes = Set<Int>()
        for s in self.series {
            guard let reset = s.upcomingReset else { continue }
            let ts = reset.timeIntervalSince1970
            let minuteKey = Int(ts / 60)
            guard drawnResetMinutes.insert(minuteKey).inserted else { continue }
            let x = min(max(xFor(ts), chartRect.minX), chartRect.maxX)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = max(hairline, 1)
            let dash: [CGFloat] = s.windowMinutes >= 1440 ? [2, 9] : [1, 3]   // ≥1 day → spaced dots; session → many dots
            line.setLineDash(dash, count: 2, phase: 0)
            s.color.withAlphaComponent(0.9).setStroke()
            line.stroke()
            self.drawVerticalLabel(self.markerFormatter.string(from: reset), atX: x, chartRect: chartRect, color: s.color, font: labelFont)
            self.resetMarkers.append(ResetMarker(x: x, date: reset, label: "\(s.name) \(localizedString("resets"))", color: s.color))
        }

        // "Now" marker: a dotted red vertical line (no label).
        let nowX = min(max(xFor(nowTS), chartRect.minX), chartRect.maxX)
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
            s.color.setStroke()
            s.color.setFill()
            for p in pts {
                self.projected.append(Projected(
                    point: CGPoint(x: xFor(p.ts.timeIntervalSince1970), y: yFor(p.value)),
                    value: p.value, date: p.ts, name: s.name, color: s.color
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

        NSGraphicsContext.restoreGraphicsState()   // end plot clip

        // Legend: color swatch + series name, left to right, until we run out of width.
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

    /// Shows a tooltip for whatever is under the cursor: a reset line (its date) or the nearest sample.
    private func drawHoverTooltip(chartRect: NSRect, textColor: NSColor) {
        guard let loc = self.hoverLocation else { return }

        // Nearest sample to the cursor (weighting X so we follow the line the cursor is over).
        var nearestPoint: Projected?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in self.projected {
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
