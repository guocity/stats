//
//  AITokensReader.swift
//  Stats
//
//  Reads the per-provider rate-limit history JSON files written by codexbar.
//

import Foundation
import Kit

internal final class AITokensReader: Reader<AITokens_Usage> {
    /// Shown when codexbar isn't installed / hasn't written any history yet.
    static let downloadHint = localizedString("Please download CodexBar to see Codex and Claude usage.")

    /// Directory codexbar writes its per-provider usage history into.
    static let historyDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.steipete.codexbar/history", isDirectory: true)
    }()

    /// Optional override (defaults key) for the history directory — for testing / relocation.
    private static var resolvedDirectory: URL {
        if let override = UserDefaults.standard.string(forKey: "AITokensHistoryPath"), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return historyDirectory
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// codexbar timestamps are whole-second UTC; this fallback also accepts fractional seconds.
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public override func setup() {
        defaultInterval = 60
        popup = true
    }

    public init(_ module: ModuleType, callback: @escaping (AITokens_Usage?) -> Void = { _ in }) {
        super.init(module, popup: true, history: false, callback: callback)
    }

    public override func read() {
        self.callback(Self.readUsage())
    }

    // MARK: - Parsing

    static func readUsage() -> AITokens_Usage {
        let dir = resolvedDirectory
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else {
            return AITokens_Usage(statusMessage: Self.downloadHint)
        }

        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return AITokens_Usage(statusMessage: "\(localizedString("Could not read")): \(error.localizedDescription)")
        }

        guard !files.isEmpty else {
            return AITokens_Usage(statusMessage: Self.downloadHint)
        }

        var providers: [AITokens_Provider] = []
        for file in files {
            providers.append(contentsOf: parseProviders(file))
        }

        if providers.allSatisfy({ $0.windows.isEmpty }) {
            return AITokens_Usage(providers: providers, statusMessage: localizedString("No usage history found"))
        }
        return AITokens_Usage(providers: providers)
    }

    /// One file can describe several accounts (e.g. two Codex logins). Each becomes its own
    /// provider entry, the preferred account first, so its windows and chart colors stay distinct.
    private static func parseProviders(_ file: URL) -> [AITokens_Provider] {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        let fileID = file.deletingPathExtension().lastPathComponent
        let base = displayName(for: fileID)
        let accounts = (root["accounts"] as? [String: Any]) ?? [:]
        let preferredKey = root["preferredAccountKey"] as? String

        // The set of "accounts" to surface: each scoped account (preferred first), plus the file's
        // `unscoped` windows. Providers like Claude key everything under `unscoped` with an empty
        // `accounts`, so we must read both.
        var units: [(key: String, windows: [[String: Any]])] = []
        let orderedKeys = accounts.keys.sorted { lhs, rhs in
            if lhs == preferredKey { return true }
            if rhs == preferredKey { return false }
            return lhs < rhs
        }
        for key in orderedKeys {
            if let w = accounts[key] as? [[String: Any]], !w.isEmpty { units.append((key, w)) }
        }
        if let unscoped = root["unscoped"] as? [[String: Any]], !unscoped.isEmpty {
            units.append(("unscoped", unscoped))
        }

        var providers: [AITokens_Provider] = []
        let multiple = units.count > 1
        for (key, rawWindows) in units {
            var windows = rawWindows.compactMap(parseWindow)
            // Shortest windows first (e.g. 5h / session before weekly) so charts read consistently.
            windows.sort { $0.windowMinutes < $1.windowMinutes }

            // Flag windows the provider has stopped reporting. codexbar captures every active window
            // together (same timestamp), so a window whose most recent sample lags the freshest window
            // by more than 2 days is inactive — e.g. a free Codex account that no longer has a weekly
            // limit. We keep its history (so older usage still shows) but won't project a fake reset.
            // Relative, so an offline stretch that ages every window together flags nothing.
            if let freshest = windows.compactMap({ $0.latest?.capturedAt }).max() {
                let staleCutoff: TimeInterval = 2 * 86_400
                windows = windows.map { w in
                    guard let last = w.latest?.capturedAt else { return w }
                    var updated = w
                    updated.isStale = freshest.timeIntervalSince(last) > staleCutoff
                    return updated
                }
            }
            guard !windows.isEmpty else { continue }

            let index = providers.count
            let name = multiple ? "\(base) \(index + 1)" : base
            let id = multiple ? "\(fileID)#\(accountShortID(key))" : fileID
            providers.append(AITokens_Provider(
                id: id, name: name, windows: windows, colorSeed: fileID, accountIndex: index
            ))
        }
        return providers
    }

    /// Last path component of an account key (after the final ":"), trimmed, for a stable short id.
    private static func accountShortID(_ key: String) -> String {
        let tail = key.split(separator: ":").last.map(String.init) ?? key
        return String(tail.prefix(8))
    }

    private static func parseWindow(_ dict: [String: Any]) -> AITokens_Window? {
        let name = (dict["name"] as? String) ?? ""
        let windowMinutes = intValue(dict["windowMinutes"]) ?? 0
        guard let rawEntries = dict["entries"] as? [[String: Any]] else { return nil }

        let entries: [AITokens_Entry] = rawEntries.compactMap { e in
            guard let capturedAt = date(e["capturedAt"]),
                  let resetsAt = date(e["resetsAt"]),
                  let used = doubleValue(e["usedPercent"]) else { return nil }
            return AITokens_Entry(capturedAt: capturedAt, resetsAt: resetsAt, usedPercent: used)
        }.sorted { $0.capturedAt < $1.capturedAt }

        guard !entries.isEmpty else { return nil }
        return AITokens_Window(name: name, windowMinutes: windowMinutes, entries: entries)
    }

    private static func displayName(for id: String) -> String {
        switch id.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        case "copilot": return "Copilot"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    // MARK: - Value coercion

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return isoFormatter.date(from: s) ?? isoFractionalFormatter.date(from: s)
    }

    private static func intValue(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func doubleValue(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
