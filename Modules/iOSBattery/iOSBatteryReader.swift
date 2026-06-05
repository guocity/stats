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

internal enum IOBatteryPy {
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
        let which = run("/usr/bin/which", ["-a", "python3"], timeout: 10)
        if which.status == 0 {
            paths.append(contentsOf: which.output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) })
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
        run(python, ["-c", "import pymobiledevice3"], timeout: 20).status == 0
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
        let result: (status: Int32, output: String)
        if let py = resolvedPython() {
            result = run(py, [sc] + args, timeout: 90)
        } else {
            // No interpreter has pymobiledevice3 — run any python3 so the script's own
            // ImportError handler can report "not installed" as JSON (it exits 0).
            result = run("/usr/bin/env", ["python3", sc] + args, timeout: 90)
        }
        guard result.status == 0,
              let data = result.output.data(using: .utf8), !data.isEmpty,
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
            switch s.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default: return nil
        }
    }

    // MARK: - Process runner (direct exec, drained concurrently, timed out)

    /// Launches `exe` directly (no shell), draining output as it arrives so the pipe
    /// buffer can't fill, and terminating the process if it exceeds `timeout`.
    @discardableResult
    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 30, mergeStderr: Bool = false, onOutput: ((String) -> Void)? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let brew = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
        env["PATH"] = [brew, env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        if env["HOME"]?.isEmpty ?? true { env["HOME"] = home }
        p.environment = env

        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = mergeStderr ? outPipe : FileHandle.nullDevice

        let collected = NSMutableData()
        let lock = NSLock()
        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); collected.append(chunk); lock.unlock()
            if let onOutput, let s = String(data: chunk, encoding: .utf8) { onOutput(s) }
        }

        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        do {
            try p.run()
        } catch {
            handle.readabilityHandler = nil
            return (-1, "Failed to launch \(exe): \(error.localizedDescription)")
        }

        if sema.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = sema.wait(timeout: .now() + 3)
        }
        handle.readabilityHandler = nil
        let rest = handle.readDataToEndOfFile()
        if !rest.isEmpty {
            lock.lock(); collected.append(rest); lock.unlock()
            if let onOutput, let s = String(data: rest, encoding: .utf8) { onOutput(s) }
        }
        lock.lock(); let data = collected as Data; lock.unlock()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Version probes

    private static func pythonVersion(_ python: String) -> String? {
        let r = run(python, ["-c", "import sys;print('.'.join(map(str, sys.version_info[:3])))"], timeout: 10)
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && !v.isEmpty) ? v : nil
    }

    private static func isPython39OrNewer(_ python: String) -> Bool {
        guard let v = pythonVersion(python) else { return false }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 3 || (parts[0] == 3 && parts[1] >= 9)
    }

    static func moduleVersion(_ python: String) -> String? {
        let r = run(python, ["-c", "import importlib.metadata as m; print(m.version('pymobiledevice3'))"], timeout: 20)
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && !v.isEmpty && !v.lowercased().contains("error") && !v.contains("Traceback")) ? v : nil
    }

    // MARK: - Managed environment (private venv in Application Support)

    static let activePythonKey = "iOSBatteryPythonPath"

    static var managedVenvDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Stats/ios-bridge-venv", isDirectory: true)
    }
    static var managedVenvPython: String { managedVenvDir.appendingPathComponent("bin/python3").path }
    static var hasManagedVenv: Bool { FileManager.default.isExecutableFile(atPath: managedVenvPython) }

    static var activePythonOverride: String? {
        let v = UserDefaults.standard.string(forKey: activePythonKey)
        return (v?.isEmpty == false) ? v : nil
    }
    static func setActivePython(_ path: String) {
        UserDefaults.standard.set(path, forKey: activePythonKey)
        cachedPython = nil
    }
    static func clearActivePython() {
        UserDefaults.standard.removeObject(forKey: activePythonKey)
        cachedPython = nil
    }

    // MARK: - Environment discovery / status

    struct DetectedPython {
        let path: String
        let version: String?
        let hasModule: Bool
        let isManaged: Bool
        let isActive: Bool
    }
    struct EnvironmentStatus {
        let active: DetectedPython?
        let moduleVersion: String?
        let hasManaged: Bool
        let detected: [DetectedPython]
    }

    /// Probes every discovered interpreter (one subprocess each). Call off the main thread.
    static func environmentStatus() -> EnvironmentStatus {
        let activePath = resolvedPython()
        var detected: [DetectedPython] = []
        for path in discoverPythonPaths() {
            detected.append(DetectedPython(
                path: path,
                version: pythonVersion(path),
                hasModule: canImportPymobiledevice3(path),
                isManaged: path == managedVenvPython,
                isActive: path == activePath
            ))
        }
        let active = activePath.map {
            DetectedPython(path: $0, version: pythonVersion($0), hasModule: true, isManaged: $0 == managedVenvPython, isActive: true)
        }
        return EnvironmentStatus(
            active: active,
            moduleVersion: activePath.flatMap { moduleVersion($0) },
            hasManaged: hasManagedVenv,
            detected: detected
        )
    }

    // MARK: - Install / uninstall

    enum InstallTarget {
        case managed
        case interpreter(String)
    }

    /// Callbacks fire on a background queue — hop to the main queue before touching UI.
    static func install(into target: InstallTarget, onProgress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch target {
            case .managed: installManaged(onProgress: onProgress, completion: completion)
            case .interpreter(let path): installInto(path, onProgress: onProgress, completion: completion)
            }
        }
    }

    private static func installManaged(onProgress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        let bases = discoverPythonPaths().filter { $0 != managedVenvPython && isPython39OrNewer($0) }
        guard !bases.isEmpty else {
            completion(false, "No Python 3.9+ was found to build the environment. Install Python 3 (e.g. `brew install python`) and try again.")
            return
        }

        let dir = managedVenvDir
        var built = false
        var lastOut = ""
        for base in bases {
            onProgress("Creating environment with \(base)…\n")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            let venv = run(base, ["-m", "venv", dir.path], timeout: 120, mergeStderr: true, onOutput: onProgress)
            if venv.status == 0 && hasManagedVenv { built = true; break }
            lastOut = venv.output
        }
        guard built else {
            completion(false, "Could not create a virtual environment.\n\(lastOut)")
            return
        }

        let py = managedVenvPython
        onProgress("Upgrading pip…\n")
        _ = run(py, ["-m", "pip", "install", "--upgrade", "pip"], timeout: 240, mergeStderr: true, onOutput: onProgress)
        onProgress("Installing pymobiledevice3 (this can take a minute)…\n")
        let pip = run(py, ["-m", "pip", "install", "pymobiledevice3>=4"], timeout: 600, mergeStderr: true, onOutput: onProgress)
        guard pip.status == 0, canImportPymobiledevice3(py) else {
            completion(false, "pip install failed (exit \(pip.status)). See the log above.")
            return
        }
        setActivePython(py)
        completion(true, "Installed pymobiledevice3 \(moduleVersion(py) ?? "") into the managed environment.")
    }

    private static func installInto(_ python: String, onProgress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        onProgress("Installing into \(python)…\n")
        var r = run(python, ["-m", "pip", "install", "pymobiledevice3>=4"], timeout: 600, mergeStderr: true, onOutput: onProgress)
        if r.status != 0 && r.output.lowercased().contains("externally-managed") {
            onProgress("\nEnvironment is externally managed; retrying with --break-system-packages…\n")
            r = run(python, ["-m", "pip", "install", "--break-system-packages", "pymobiledevice3>=4"], timeout: 600, mergeStderr: true, onOutput: onProgress)
        }
        guard r.status == 0, canImportPymobiledevice3(python) else {
            completion(false, "Install failed (exit \(r.status)). See the log above. (System Python may need sudo or a virtual environment — try the managed install instead.)")
            return
        }
        setActivePython(python)
        completion(true, "Installed pymobiledevice3 \(moduleVersion(python) ?? "") into \(python).")
    }

    static func uninstall(from target: InstallTarget) -> (Bool, String) {
        switch target {
        case .managed:
            return removeManagedInstall()
        case .interpreter(let python):
            _ = run(python, ["-m", "pip", "uninstall", "-y", "pymobiledevice3"], timeout: 240, mergeStderr: true)
            if activePythonOverride == python { clearActivePython() }
            cachedPython = nil
            let stillThere = canImportPymobiledevice3(python)
            return (!stillThere, stillThere ? "Uninstall may have failed for \(python)." : "Removed pymobiledevice3 from \(python).")
        }
    }

    /// Deletes the managed venv (never touches the user's own interpreters).
    private static func removeManagedInstall() -> (Bool, String) {
        let dir = managedVenvDir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return (false, "There is no managed environment to remove.")
        }
        if activePythonOverride == managedVenvPython { clearActivePython() }
        do {
            try FileManager.default.removeItem(at: dir)
            cachedPython = nil
            return (true, "Removed the managed environment.")
        } catch {
            return (false, "Could not remove environment: \(error.localizedDescription)")
        }
    }
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

// MARK: - History (persisted in the program-level store)

/// One persisted point of a device's battery aging metrics.
struct iOSBatteryHistorySample: Codable {
    let t: Double        // epoch seconds
    let cycles: Int?
    let health: Double?  // percent, 0...100
}

/// Last-known identity and battery state for a device, persisted so the preview can keep
/// showing a device — with its most recent values — even while it is currently disconnected.
struct iOSBatteryDeviceRecord: Codable {
    var udid: String
    var deviceName: String?
    var productType: String?
    var productVersion: String?
    var currentCapacityPercent: Int?
    var isCharging: Bool?
    var cycleCount: Int?
    var healthPercent: Double?  // percent, 0...100
    var lastSeen: Double        // epoch seconds

    /// A (stale) snapshot rebuilt from the stored record, for rendering a disconnected device.
    var snapshot: iOSBattery_DeviceSnapshot {
        var s = iOSBattery_DeviceSnapshot()
        s.udid = udid
        s.deviceName = deviceName
        s.productType = productType
        s.productVersion = productVersion
        s.currentCapacityPercent = currentCapacityPercent
        s.isCharging = isCharging
        s.cycleCount = cycleCount
        s.batteryHealthPercent = healthPercent
        s.updateTime = lastSeen
        s.isStale = true
        return s
    }
}

/// Per-device cycle-count / health history, stored as JSON in `Store` (survives relaunches).
/// Also keeps a lightweight identity record + index of every device ever seen, so the preview
/// can list devices regardless of whether they are currently connected.
enum iOSBatteryHistory {
    private static let maxSamples = 1000
    private static let indexKey = "iOSBattery_history_index"
    private static func key(_ udid: String) -> String { "iOSBattery_history_\(udid)" }
    private static func recordKey(_ udid: String) -> String { "iOSBattery_device_\(udid)" }

    static func samples(for udid: String) -> [iOSBatteryHistorySample] {
        guard let data = Store.shared.data(key: key(udid)) else { return [] }
        return (try? JSONDecoder().decode([iOSBatteryHistorySample].self, from: data)) ?? []
    }

    /// UDIDs of every device ever recorded, connected or not.
    static func knownUDIDs() -> [String] {
        guard let data = Store.shared.data(key: indexKey) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func deviceRecord(for udid: String) -> iOSBatteryDeviceRecord? {
        guard let data = Store.shared.data(key: recordKey(udid)) else { return nil }
        return try? JSONDecoder().decode(iOSBatteryDeviceRecord.self, from: data)
    }

    private static func addToIndex(_ udid: String) {
        var ids = knownUDIDs()
        guard !ids.contains(udid) else { return }
        ids.append(udid)
        if let data = try? JSONEncoder().encode(ids) {
            Store.shared.set(key: indexKey, value: data)
        }
    }

    /// For every connected device: refresh its identity record (so it stays visible while
    /// disconnected, with up-to-date "last seen" and last-known charge) and append a history
    /// point — but only when cycles or health changed (these age slowly, so the series stays
    /// small and meaningful).
    static func record(_ usage: iOSBattery_Usage) {
        let now = Date().timeIntervalSince1970
        for d in usage.connectedDevices {
            guard let udid = d.udid, !udid.isEmpty else { continue }
            let cycles = d.cycleCount
            let health = d.healthPercent.map { ($0 * 100).rounded() / 100 }

            // Persist identity for any device carrying an identifier or battery data.
            if d.isIdentified || d.currentCapacityPercent != nil || cycles != nil || health != nil {
                let rec = iOSBatteryDeviceRecord(
                    udid: udid,
                    deviceName: d.deviceName,
                    productType: d.productType,
                    productVersion: d.productVersion,
                    currentCapacityPercent: d.currentCapacityPercent,
                    isCharging: d.isCharging,
                    cycleCount: cycles,
                    healthPercent: health,
                    lastSeen: now
                )
                if let data = try? JSONEncoder().encode(rec) {
                    Store.shared.set(key: recordKey(udid), value: data)
                }
                addToIndex(udid)
            }

            guard cycles != nil || health != nil else { continue }
            var arr = samples(for: udid)
            if let last = arr.last, last.cycles == cycles, last.health == health { continue }
            arr.append(iOSBatteryHistorySample(t: now, cycles: cycles, health: health))
            if arr.count > maxSamples { arr = Array(arr.suffix(maxSamples)) }
            if let data = try? JSONEncoder().encode(arr) {
                Store.shared.set(key: key(udid), value: data)
            }
        }
    }
}
