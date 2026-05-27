//
//  iOSBatteryReader.swift
//  Stats
//

import Foundation
import Kit
import Network

internal final class iOSBatteryReader: Reader<iOSBattery_Usage> {
    private static let cacheLock = NSLock()
    private static var snapshotCache: [String: iOSBattery_DeviceSnapshot] = [:]

    public override func setup() {
        defaultInterval = 60
        popup = true
        LocalNetwork.prime()
    }

    public init(_ module: ModuleType, callback: @escaping (iOSBattery_Usage?) -> Void = { _ in }) {
        super.init(module, popup: true, history: false, callback: callback)
    }

    public override func read() {
        LocalNetwork.prime()
        callback(iOSBattery_Usage(devices: Self.mergeWithCache(IOBatteryPy.readDevices())))
    }

    /// Always show in Settings when the app ships the bridge script; pymobiledevice3 is optional at runtime.
    static func isAvailable() -> Bool { IOBatteryPy.hasScript }
    static func startDeviceNotifications() {}
    static func stopDeviceNotifications() {}

    private static func mergeWithCache(_ fresh: [iOSBattery_DeviceSnapshot]) -> [iOSBattery_DeviceSnapshot] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if fresh.isEmpty {
            guard !snapshotCache.isEmpty else { return [] }
            return snapshotCache.values.map { var s = $0; s.isStale = true; return s }
        }

        var statusRows: [iOSBattery_DeviceSnapshot] = []
        var out: [String: iOSBattery_DeviceSnapshot] = [:]
        for var snap in fresh {
            guard let udid = snap.udid, !udid.isEmpty, udid != iOSBatteryStatusUDID else {
                if snap.lastError != nil || snap.isIdentified {
                    statusRows.append(snap)
                }
                continue
            }
            var merged = snapshotCache[udid] ?? snap
            merged.mergeFrom(snap)
            merged.isStale = false
            if snap.isIdentified || snap.currentCapacityPercent != nil || snap.cycleCount != nil || snap.healthPercent != nil {
                snapshotCache[udid] = merged
            }
            out[udid] = merged
        }
        snapshotCache = snapshotCache.filter { $0.key == iOSBatteryStatusUDID || out.keys.contains($0.key) }
        if !out.isEmpty {
            return Array(out.values)
        }
        return statusRows
    }
}

// MARK: - pymobiledevice3

private enum IOBatteryPy {
    private static let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    private static var cachedPython: String?

    static let installHint = "Install pymobiledevice3: pip install pymobiledevice3 (and allow Local Network for Wi‑Fi devices)."

    static var hasScript: Bool { script != nil }
    static var isInstalled: Bool { resolvedPython() != nil && hasScript }

    static func readDevices() -> [iOSBattery_DeviceSnapshot] {
        guard hasScript else {
            return [statusSnapshot("iOS battery script missing from Stats.app bundle.")]
        }

        guard let payload = runJSON(["--json"]) else {
            if let py = resolvedPython() {
                return [statusSnapshot("Could not read iOS devices (Python bridge failed). Using \(py).")]
            }
            return [statusSnapshot(installHint)]
        }

        if let err = payload["error"] as? String, !err.isEmpty, (payload["devices"] as? [Any])?.isEmpty != false {
            if err.contains("pymobiledevice3 not installed"), let py = resolvedPython() {
                return [statusSnapshot("pymobiledevice3 import failed for \(py). Reinstall in that environment or set iOSBatteryPythonPath in defaults.")]
            }
            return [statusSnapshot(err)]
        }

        let rows = (payload["devices"] as? [[String: Any]])?.compactMap(snapshot(from:)) ?? []
        if rows.isEmpty, isInstalled {
            return [statusSnapshot("No iOS devices found. Connect via USB or Wi‑Fi sync and trust this Mac.")]
        }
        return rows
    }

    private static func statusSnapshot(_ message: String) -> iOSBattery_DeviceSnapshot {
        var s = iOSBattery_DeviceSnapshot()
        s.udid = iOSBatteryStatusUDID
        s.deviceName = "iOS Battery"
        s.lastError = message
        return s
    }

    private static func resolvedPython() -> String? {
        if let cached = cachedPython, canImportPymobiledevice3(cached) { return cached }
        cachedPython = nil
        for path in discoverPythonPaths() where canImportPymobiledevice3(path) {
            cachedPython = path
            return path
        }
        return nil
    }

    private static func discoverPythonPaths() -> [String] {
        var paths: [String] = []
        if let override = UserDefaults.standard.string(forKey: "iOSBatteryPythonPath"), !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: pythons)
        if let data = shell("which -a python3 2>/dev/null", requireOutput: false),
           let text = String(data: data, encoding: .utf8) {
            paths.append(contentsOf: text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        let home = NSHomeDirectory()
        for name in [".venv", ".venv-3.13", "venv", ".local/pipx/venvs/pymobiledevice3/bin/python3"] {
            paths.append((home as NSString).appendingPathComponent(name.hasSuffix("python3") ? name : "\(name)/bin/python3"))
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for entry in entries where entry.hasPrefix(".venv") {
                paths.append((home as NSString).appendingPathComponent("\(entry)/bin/python3"))
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func canImportPymobiledevice3(_ python: String) -> Bool {
        shell("\(q(python)) -c 'import pymobiledevice3'", requireOutput: false) != nil
    }

    private static var script: String? {
        if let p = Bundle.main.path(forResource: "ios_battery_pymobiledevice3", ofType: "py", inDirectory: "Scripts") { return p }
        if let p = Bundle.main.path(forResource: "ios_battery_pymobiledevice3", ofType: "py") { return p }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/ios_battery_pymobiledevice3.py").path
        if FileManager.default.isReadableFile(atPath: dev) { return dev }
        return nil
    }

    private static func runJSON(_ args: [String]) -> [String: Any]? {
        guard let sc = script else { return nil }
        let cmd: String
        if let py = resolvedPython() {
            cmd = "\(q(py)) \(q(sc)) \(args.map(q).joined(separator: " "))"
        } else {
            cmd = "\(q(sc)) \(args.map(q).joined(separator: " "))"
        }
        guard let data = shell(cmd),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func snapshot(from row: [String: Any]) -> iOSBattery_DeviceSnapshot? {
        guard let udid = row["udid"] as? String, !udid.isEmpty else { return nil }
        var s = iOSBattery_DeviceSnapshot()
        s.udid = udid
        s.deviceName = row["deviceName"] as? String
        s.productType = row["productType"] as? String
        s.productVersion = row["iosVersion"] as? String
        s.connection = row["connection"] as? String
        if let err = row["error"] as? String, !err.isEmpty { s.lastError = err }
        if let m = row["batteryMetrics"] as? [String: Any] { apply(m, to: &s) }
        return s
    }

    private static func apply(_ m: [String: Any], to s: inout iOSBattery_DeviceSnapshot) {
        s.currentCapacityPercent = int(m["CurrentCapacity"])
        s.isCharging = bool(m["IsCharging"])
        s.cycleCount = int(m["CycleCount"])
        s.voltageMV = int(m["Voltage"])
        if let t = double(m["Temperature"]) { s.temperatureC = t / 100 }
        if let t = double(m["VirtualTemperature"]) { s.virtualTemperatureC = t / 100 }
        if let caps = m["capacityFields"] as? [String: Any] {
            var fields: [String: String] = [:]
            for (key, value) in caps {
                if let text = stringValue(value) { fields[key] = text }
            }
            s.capacityFields = fields
        }
        s.designCapacityMAh = int(m["DesignCapacity"]) ?? intFromCapacityFields(s.capacityFields, "DesignCapacity")
        s.appleRawMaxCapacityMAh = int(m["AppleRawMaxCapacity"]) ?? intFromCapacityFields(s.capacityFields, "AppleRawMaxCapacity")
        s.nominalChargeCapacityMAh = int(m["NominalChargeCapacity"]) ?? intFromCapacityFields(s.capacityFields, "NominalChargeCapacity")
        if let h = double(m["BatteryHealthPercent"]) {
            s.batteryHealthPercent = h
            let r = Int(h.rounded())
            if (1...100).contains(r) { s.fullChargeCapacityPercent = r }
        }
        s.serial = m["Serial"] as? String
        s.manufacturer = m["Manufacturer"] as? String
        if let md = m["ManufactureDate"] { s.manufactureDateRaw = stringValue(md) }
        s.manufactureDateDecoded = m["ManufactureDateDecoded"] as? String
        if let v = m["DateOfFirstUse"] { s.dateOfFirstUseRaw = stringValue(v) }
        s.dateOfFirstUseDecoded = m["DateOfFirstUseDecoded"] as? String
        s.updateTime = double(m["UpdateTime"])
    }
    
    private static func stringValue(_ v: Any?) -> String? {
        if v == nil || v is NSNull { return nil }
        switch v {
        case let s as String: return s
        case let i as Int: return String(i)
        case let n as NSNumber: return n.stringValue
        case let d as Double: return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return String(describing: v)
        }
    }
    
    private static func intFromCapacityFields(_ fields: [String: String], _ key: String) -> Int? {
        guard let text = fields[key] else { return nil }
        return Int(text.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private static func int(_ v: Any?) -> Int? {
        if v == nil || v is NSNull { return nil }
        switch v {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func double(_ v: Any?) -> Double? {
        if v == nil || v is NSNull { return nil }
        switch v {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func bool(_ v: Any?) -> Bool? {
        if v == nil || v is NSNull { return nil }
        switch v {
        case let b as Bool: return b
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue
        case let i as Int: return i != 0
        case let s as String:
            switch s.lowercased() { case "true", "yes", "1": return true; case "false", "no", "0": return false; default: return nil }
        default: return nil
        }
    }

    private static func shell(_ cmd: String, requireOutput: Bool = true) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        let brew = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
        let home = NSHomeDirectory()
        let venvBin = (home as NSString).appendingPathComponent(".venv-3.13/bin")
        let pathEnv = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [venvBin, brew, pathEnv].joined(separator: ":")
        env["HOME"] = (env["HOME"]?.isEmpty == false) ? env["HOME"] : home
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if requireOutput, data.isEmpty { return nil }
        return data
    }

    private static func q(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
}

// MARK: - Local Network (Wi‑Fi device discovery from GUI apps)

private enum LocalNetwork {
    private static let queue = DispatchQueue(label: "eu.exelban.iosbattery.localnetwork")
    private static var browser: NWBrowser?
    private static var didPrime = false

    static func prime() {
        queue.async {
            guard !didPrime, browser == nil else { return }
            didPrime = true
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let b = NWBrowser(for: .bonjour(type: "_apple-mobdev2._tcp", domain: nil), using: params)
            browser = b
            var finished = false
            let finish: () -> Void = {
                guard !finished else { return }
                finished = true
                b.cancel()
                browser = nil
            }
            b.stateUpdateHandler = { state in
                if case .ready = state { queue.asyncAfter(deadline: .now() + 1, execute: finish) }
                if case .failed = state { queue.async(execute: finish) }
            }
            b.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8, execute: finish)
        }
    }
}
