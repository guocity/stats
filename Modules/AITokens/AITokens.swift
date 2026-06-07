//
//  AITokens.swift
//  Stats
//
//  Reads AI coding-assistant rate-limit usage history written by codexbar
//  (~/Library/Application Support/com.steipete.codexbar/history/*.json) and
//  surfaces, for each provider (Codex, Claude, …) and each rate-limit window
//  (e.g. "weekly", "session", "5h"):
//    • current usage percent ("now"),
//    • the upcoming reset date with a live countdown,
//    • the full usage-over-time history (drawn as a line chart in the preview).
//

import Cocoa
import Kit

/// One captured usage point of a single rate-limit window.
struct AITokens_Entry: Codable {
    let capturedAt: Date
    let resetsAt: Date
    let usedPercent: Double
}

/// A single rate-limit window for a provider (e.g. "weekly" / "session" / "5h").
struct AITokens_Window: Codable {
    let name: String
    let windowMinutes: Int
    var entries: [AITokens_Entry]
    /// True when the provider has stopped reporting this window (e.g. a free Codex account that no
    /// longer has a weekly limit). Its history still shows, but no upcoming reset is projected.
    var isStale: Bool = false

    /// Most recent reading (entries are stored in chronological order).
    var latest: AITokens_Entry? { entries.last }

    /// Human label for the window length, derived from `windowMinutes`.
    var lengthLabel: String {
        let minutes = windowMinutes
        if minutes <= 0 { return name.capitalized }
        if minutes % 10080 == 0 { return "\(minutes / 10080)w" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Friendly label based on the window length, so the same raw name means the right thing across
    /// providers (Codex's "session" is a 30-day monthly limit; Claude's is a 5-hour one).
    var displayName: String {
        switch windowMinutes {
        case 1440: return localizedString("Daily")
        case 10080: return localizedString("Weekly")
        case 40320...44640: return localizedString("Monthly")   // 28–31 days
        default:
            if name.isEmpty { return lengthLabel }
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// One account read from a single history file. A file (e.g. codex.json) can hold
/// several accounts; each becomes its own provider entry so its windows / colors stay distinct.
struct AITokens_Provider: Codable {
    /// Stable identifier — file stem, plus a short account suffix when there are multiple.
    let id: String
    /// Display name (e.g. "Codex", or "Codex 2" when an account file has more than one).
    let name: String
    var windows: [AITokens_Window]
    /// Color seed shared by every account in a file (the file stem) so one provider keeps one hue family.
    var colorSeed: String = ""
    /// Index of this account within its file (0 = preferred) — used to vary the hue between accounts.
    var accountIndex: Int = 0
    /// Whether the user has enabled this account in settings.
    var enabled: Bool = true

    /// The window closest to its limit — the one most worth surfacing first.
    var mostUsedWindow: AITokens_Window? {
        windows.max { ($0.latest?.usedPercent ?? -1) < ($1.latest?.usedPercent ?? -1) }
    }

    var maxUsedPercent: Double {
        windows.compactMap { $0.latest?.usedPercent }.max() ?? 0
    }

    /// A stable, distinct color for a given window: hue varies per account, brightness per window.
    func color(forWindowIndex w: Int) -> NSColor {
        let seed = colorSeed.isEmpty ? id : colorSeed
        let base = aiTokensProviderColor(seed).usingColorSpace(.deviceRGB) ?? aiTokensProviderColor(seed)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        h = (h + CGFloat(accountIndex) * 0.10).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let bb = min(1.0, b + CGFloat(w) * 0.12)
        let ss = max(0.35, s - CGFloat(w) * 0.12)
        return NSColor(hue: h, saturation: ss, brightness: bb, alpha: 1)
    }
}

/// Aggregate reader value: every provider discovered in the history directory.
struct AITokens_Usage: Codable {
    var providers: [AITokens_Provider]
    /// Set when the history directory could not be read (missing app / no files).
    var statusMessage: String?

    init(providers: [AITokens_Provider] = [], statusMessage: String? = nil) {
        self.providers = providers
        self.statusMessage = statusMessage
    }

    var hasData: Bool { providers.contains { $0.enabled && $0.windows.contains { !$0.isStale } } }

    /// Provider+window carrying the highest current usage across everything.
    var primaryWindow: (provider: AITokens_Provider, window: AITokens_Window)? {
        var best: (AITokens_Provider, AITokens_Window)?
        var bestPercent = -1.0
        for p in providers where p.enabled {
            for w in p.windows where !w.isStale {
                let pct = w.latest?.usedPercent ?? -1
                if pct > bestPercent { bestPercent = pct; best = (p, w) }
            }
        }
        return best.map { (provider: $0.0, window: $0.1) }
    }
}

// MARK: - Formatting helpers

/// A stable color per provider so its chart lines / swatches don't shift.
func aiTokensProviderColor(_ id: String) -> NSColor {
    switch id.lowercased() {
    case "claude", "anthropic": return .systemOrange
    case "codex", "openai", "chatgpt": return .systemGreen
    case "gemini", "google": return .systemTeal
    case "copilot", "github": return .systemPurple
    default:
        // Deterministic fallback from the id's hash.
        let palette: [NSColor] = [.systemTeal, .systemPink, .systemIndigo, .systemBrown, .systemRed, .systemYellow]
        let h = abs(id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[h % palette.count]
    }
}

/// The provider's brand glyph, tinted white, for use in the popup section header.
/// Returns nil for providers we don't ship an icon for (they just show their name).
func aiTokensProviderIcon(_ id: String) -> NSImage? {
    let asset: String?
    switch id.lowercased() {
    case let s where s.contains("claude") || s.contains("anthropic"): asset = "claude"
    case let s where s.contains("codex") || s.contains("openai") || s.contains("chatgpt"): asset = "codex"
    default: asset = nil
    }
    guard let asset, let base = NSImage(named: asset) else { return nil }
    return aiTokensTinted(base, color: .white)
}

/// Tints a template image to a solid color by painting over its alpha mask.
private func aiTokensTinted(_ image: NSImage, color: NSColor) -> NSImage {
    guard let tinted = image.copy() as? NSImage else { return image }
    tinted.lockFocus()
    color.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.isTemplate = false
    return tinted
}

/// The genuine *upcoming* reset for a window. codexbar stores the current window's
/// `resetsAt`; once that moment has passed (it stopped logging before the reset fired),
/// roll it forward by whole window lengths so we always point at the next reset.
func aiTokensUpcomingReset(_ window: AITokens_Window, from now: Date = Date()) -> Date? {
    guard !window.isStale, let latest = window.latest else { return nil }
    var reset = latest.resetsAt
    let step = TimeInterval(window.windowMinutes * 60)
    guard step > 0 else { return reset }
    if reset <= now {
        let periods = floor(now.timeIntervalSince(reset) / step) + 1
        reset = reset.addingTimeInterval(periods * step)
    }
    return reset
}

/// Visible time-range for the usage-history chart.
enum AITokensRange: Int, CaseIterable {
    case fiveHour, day, week, month, threeMonth, year

    var title: String {
        switch self {
        case .fiveHour: return "5H"
        case .day: return "1D"
        case .week: return "1W"
        case .month: return "1M"
        case .threeMonth: return "3M"
        case .year: return "1Y"
        }
    }

    /// How far back from "now" the window starts.
    var lookback: TimeInterval {
        switch self {
        case .fiveHour: return 18_000      // 5 hours
        case .day: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000      // 30 days
        case .threeMonth: return 7_776_000 // 90 days
        case .year: return 31_536_000      // 365 days
        }
    }

    /// How far past "now" to extend so the upcoming reset is visible. The short views (5h / 1 day)
    /// show just the recent past (no forward extension); longer ranges reach forward to the reset.
    var lookforward: TimeInterval {
        switch self {
        case .fiveHour, .day: return 0
        case .week: return 604_800
        case .month, .threeMonth, .year: return 2_592_000
        }
    }
}

/// A past reset boundary, tinted with its provider/window color so it's distinguishable.
struct AITokensHistoricalReset {
    let date: Date
    let color: NSColor
    let providerId: String
    let windowName: String
}

/// Distinct *fixed* reset boundaries that already happened (drawn as light, provider-tinted lines).
/// While there is no usage, codexbar reports `resetsAt ≈ capturedAt + window` and the date keeps
/// sliding with every capture — those "rolling" samples are not real resets. A reset time is treated
/// as a genuine (non-moving) boundary unless it appeared exactly once *and* only as a rolling sample;
/// any reset that stayed anchored across captures (or differs from capturedAt + window) is kept.
func aiTokensHistoricalResets(_ providers: [AITokens_Provider], before now: Date) -> [AITokensHistoricalReset] {
    var out: [AITokensHistoricalReset] = []
    for provider in providers where provider.enabled {
        for (index, window) in provider.windows.enumerated() where !window.isStale {
            let color = provider.color(forWindowIndex: index)
            let windowSec = TimeInterval(window.windowMinutes * 60)
            // Group past samples by their reset time (rounded to the minute).
            var groups: [Int: (date: Date, count: Int, allRolling: Bool)] = [:]
            for entry in window.entries where entry.resetsAt <= now {
                let key = Int(entry.resetsAt.timeIntervalSince1970 / 60)
                let rolling = windowSec > 0 &&
                    abs(entry.resetsAt.timeIntervalSince(entry.capturedAt) - windowSec) < 900
                if let g = groups[key] {
                    groups[key] = (g.date, g.count + 1, g.allRolling && rolling)
                } else {
                    groups[key] = (entry.resetsAt, 1, rolling)
                }
            }
            for (_, g) in groups where !(g.count == 1 && g.allRolling) {
                out.append(AITokensHistoricalReset(date: g.date, color: color, providerId: provider.id, windowName: window.name))
            }
        }
    }
    return out.sorted { $0.date < $1.date }
}

/// "#d #h #m", "12m 3s", or "now" — a countdown until `date`.
func aiTokensCountdown(to date: Date, from now: Date = Date()) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    if seconds <= 0 { return localizedString("now") }
    
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    
    if seconds < 3600 {
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
    
    if days > 0 {
        if minutes > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    
    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    
    return minutes > 0 ? "\(minutes)m" : "now"
}

/// Absolute date for a reset / capture time, e.g. "31 Mar, 14:36".
func aiTokensAbsoluteDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "dd MMM, HH:mm"
    return f.string(from: date)
}

/// "Updated 3m ago" style relative label for the last capture time.
func aiTokensRelativeAge(_ date: Date, from now: Date = Date()) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return localizedString("just now") }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m " + localizedString("ago") }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h " + localizedString("ago") }
    return "\(hours / 24)d " + localizedString("ago")
}

let aiTokensUpdateIntervals: [KeyValue_t] = ReaderUpdateIntervals + [
    KeyValue_t(key: "3600", value: "1 hr")
]

// MARK: - Settings (module tab)

internal final class AITokensSettings: NSStackView, Settings_v {
    private let module: ModuleType
    private var lastUsage: AITokens_Usage?
    private var updateIntervalValue: Int = 60

    public var setInterval: ((_ value: Int) -> Void) = { _ in }
    public var refreshNow: (() -> Void) = { }
    public var syncFromReader: (() -> AITokens_Usage?)? = nil

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

    func apply(_ usage: AITokens_Usage) {
        self.lastUsage = usage
        self.rebuildOnMain()
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

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: self.intervalAndRefreshRow())
        ]))

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Source"), component: self.valueMultiline(AITokensReader.historyDirectory.path))
        ]))

        guard let usage = self.lastUsage else {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Status"), component: ValueField(frame: .zero, localizedString("Waiting for first read…")))
            ]))
            return
        }

        guard usage.hasData else {
            let text = usage.statusMessage ?? localizedString("No usage history found")
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Status"), component: self.valueMultiline(text))
            ]))
            return
        }

        let now = Date()
        for provider in usage.providers where !provider.windows.isEmpty {
            var rows: [PreferencesRow] = []
            
            let toggle = self.switchView(
                action: #selector(self.toggleProvider(_:)),
                state: provider.enabled
            )
            toggle.identifier = NSUserInterfaceItemIdentifier(provider.id)
            rows.append(PreferencesRow(localizedString("Enabled"), component: toggle))
            
            for window in provider.windows where !window.isStale {
                guard let latest = window.latest else { continue }
                let used = "\(Int(latest.usedPercent.rounded()))%"
                let upcoming = aiTokensUpcomingReset(window, from: now) ?? latest.resetsAt
                let resets = "\(aiTokensCountdown(to: upcoming, from: now)) (\(aiTokensAbsoluteDate(upcoming)))"
                rows.append(PreferencesRow("\(window.displayName) — \(localizedString("used"))", component: ValueField(frame: .zero, used)))
                rows.append(PreferencesRow(
                    "\(window.displayName) — \(localizedString("resets"))",
                    component: ValueField(frame: .zero, resets)
                ))
                let updatedVal = "\(aiTokensAbsoluteDate(latest.capturedAt)) (\(aiTokensRelativeAge(latest.capturedAt, from: now)))"
                rows.append(PreferencesRow(
                    "\(window.displayName) — \(localizedString("updated"))",
                    component: ValueField(frame: .zero, updatedVal)
                ))
            }
            if rows.isEmpty { continue }
            self.addArrangedSubview(PreferencesSection(title: provider.name, rows))
        }

        // Popup section configuration
        let compactState = Store.shared.bool(key: "AITokens_compactPopup", defaultValue: true)
        let moreThanDayColorKey = Store.shared.string(key: "AITokens_moreThanDayColor", defaultValue: "custom:#007AFFFF")
        let lessThanDayColorKey = Store.shared.string(key: "AITokens_lessThanDayColor", defaultValue: "custom:#4FA5FCFF")
        
        let compactSwitch = self.switchView(
            action: #selector(self.toggleCompactPopup(_:)),
            state: compactState
        )
        
        let moreThanDayPicker = self.colorSelectView(
            action: #selector(self.changeMoreThanDayColor(_:)),
            items: SColor.allColors,
            selected: moreThanDayColorKey
        )
        
        let lessThanDayPicker = self.colorSelectView(
            action: #selector(self.changeLessThanDayColor(_:)),
            items: SColor.allColors,
            selected: lessThanDayColorKey
        )
        
        self.addArrangedSubview(PreferencesSection(title: localizedString("Popup"), [
            PreferencesRow(localizedString("Compact layout"), component: compactSwitch),
            PreferencesRow(localizedString("Color (> 1 day)"), component: moreThanDayPicker),
            PreferencesRow(localizedString("Color (< 1 day)"), component: lessThanDayPicker)
        ]))
    }

    private func valueMultiline(_ text: String) -> NSView {
        let v = ValueField(frame: .zero, text)
        v.cell?.usesSingleLineMode = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func intervalAndRefreshRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let select = selectView(
            action: #selector(self.changeUpdateInterval(_:)),
            items: aiTokensUpdateIntervals,
            selected: "\(self.updateIntervalValue)"
        )
        select.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let refresh = buttonView(#selector(self.refreshClicked(_:)), text: localizedString("Refresh"))
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(select)
        row.addArrangedSubview(refresh)
        return row
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

    @objc private func toggleProvider(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let value = controlState(sender)
        Store.shared.set(key: "AITokens_\(id)_enabled", value: value)
        self.refreshNow()
    }

    @objc private func toggleCompactPopup(_ sender: NSSwitch) {
        let value = controlState(sender)
        Store.shared.set(key: "AITokens_compactPopup", value: value)
        self.refreshNow()
    }

    @objc private func changeMoreThanDayColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Store.shared.set(key: "AITokens_moreThanDayColor", value: key)
        self.refreshNow()
    }

    @objc private func changeLessThanDayColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Store.shared.set(key: "AITokens_lessThanDayColor", value: key)
        self.refreshNow()
    }
}

// MARK: - Module

public final class AITokens: Module {
    private let popupView: AITokensPopup
    private let portalView: AITokensPortal
    private let settingsContent: AITokensSettings
    private let previewContent: AITokensPreview

    private var usageReader: AITokensReader? = nil

    public init() {
        self.popupView = AITokensPopup(.aiTokens)
        self.portalView = AITokensPortal(.aiTokens)
        self.settingsContent = AITokensSettings(.aiTokens)
        self.previewContent = AITokensPreview(.aiTokens)

        super.init(
            moduleType: .aiTokens,
            popup: self.popupView,
            settings: self.settingsContent,
            portal: self.portalView,
            notifications: nil,
            preview: self.previewContent,
            configName: "AITokens.config",
            configBundle: Bundle.main
        )

        self.settingsContent.setInterval = { [weak self] value in
            self?.usageReader?.setInterval(value)
        }
        self.settingsContent.refreshNow = { [weak self] in
            guard let reader = self?.usageReader else { return }
            DispatchQueue.global(qos: .userInitiated).async { reader.read() }
        }
        self.settingsContent.syncFromReader = { [weak self] in
            self?.usageReader?.value
        }

        self.usageReader = AITokensReader(.aiTokens) { [weak self] value in
            guard let self, let value else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.settingsContent.apply(value)
                self.previewContent.usageCallback(value)
                self.popupView.usageCallback(value)
                self.portalView.usageCallback(value)

                let percent = value.primaryWindow.map { $0.window.latest?.usedPercent ?? 0 } ?? 0
                let remainingPercent = 100.0 - percent
                let fraction = remainingPercent / 100.0
                self.menuBar.widgets.filter { $0.isActive }.forEach { (w: SWidget) in
                    switch w.item {
                    case let widget as Mini:
                        widget.setValue(fraction)
                        widget.setColorZones((0.2, 0.4))
                    case let widget as BarChart:
                        widget.setValue([[ColorValue(fraction)]])
                        widget.setColorZones((0.2, 0.4))
                    case let widget as LineChart:
                        widget.setValue(fraction)
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
