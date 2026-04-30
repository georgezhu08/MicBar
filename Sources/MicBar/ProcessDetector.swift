import AppKit
import CoreAudio
import Darwin
import Foundation
import SQLite3

/// Detects which processes are currently using the microphone.
/// Primary: Query system log for recent TCC mic access attributions (gives exact PIDs).
/// Fallback: CoreAudio private APIs, then TCC heuristic.
final class ProcessDetector {
    static let shared = ProcessDetector()

    struct AppInfo {
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }

    enum DetectionMethod {
        case logAttribution   // Exact: system log shows which PIDs accessed the mic
        case privateAPI       // Exact: CoreAudio private selectors found the PIDs
        case tccHeuristic     // Approximate: running apps cross-referenced with mic permission
        case micInactive      // Mic not in use, no detection needed
        case noAccess         // Mic active but can't detect apps
    }

    struct DetectionResult {
        let apps: [AppInfo]
        let method: DetectionMethod
    }

    // Cached log-based PIDs, refreshed in background
    private var cachedLogPIDs: [pid_t] = []
    private var refreshTimer: Timer?

    private init() {
        startBackgroundRefresh()
    }

    /// Start periodic background refresh of log-based PID detection.
    private func startBackgroundRefresh() {
        // Initial fetch on background queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pids = self?.queryLogForMicPIDs() ?? []
            DispatchQueue.main.async {
                self?.cachedLogPIDs = pids
            }
        }

        // Refresh every 5 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let pids = self?.queryLogForMicPIDs() ?? []
                DispatchQueue.main.async {
                    self?.cachedLogPIDs = pids
                }
            }
        }
    }

    // MARK: - Public API

    /// Returns apps currently using the microphone, along with the detection method used.
    func detectAppsUsingMicrophone() -> DetectionResult {
        // Check if ANY input device is running
        let activeDevices = AudioDeviceManager.shared.activeInputDevices()
        guard !activeDevices.isEmpty else {
            return DetectionResult(apps: [], method: .micInactive)
        }

        // Method 1: Use cached log-based PIDs (refreshed in background)
        if !cachedLogPIDs.isEmpty {
            // Filter to only PIDs still alive
            let alivePIDs = cachedLogPIDs.filter { kill($0, 0) == 0 }
            let apps = appsFromPIDs(alivePIDs)
            if !apps.isEmpty {
                return DetectionResult(apps: apps, method: .logAttribution)
            }
        }

        // Method 2: CoreAudio private APIs
        let caPIDs = pidsWithActiveAudioInput(activeDeviceIDs: activeDevices.map { $0.0 })
        if !caPIDs.isEmpty {
            return DetectionResult(apps: appsFromPIDs(caPIDs), method: .privateAPI)
        }

        // Method 3: TCC heuristic (last resort)
        let (apps, tccReadable) = appsByTCCHeuristic()
        if tccReadable && !apps.isEmpty {
            return DetectionResult(apps: apps, method: .tccHeuristic)
        }

        return DetectionResult(apps: [], method: .noAccess)
    }

    // MARK: - Primary: System Log Attribution

    /// Queries the system log for recent kTCCServiceMicrophone access requests.
    /// Returns PIDs of processes that are still running and accessed the mic recently.
    private func queryLogForMicPIDs() -> [pid_t] {
        // Use `log show` to find recent mic access attributions
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--last", "5m",
            "--predicate", "subsystem == \"com.apple.TCC\" AND eventMessage CONTAINS \"kTCCServiceMicrophone\" AND eventMessage CONTAINS \"target_token\"",
            "--info",
            "--style", "compact",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        // Extract PIDs from "target_token={pid:XXXXX," patterns
        var pids = Set<pid_t>()
        let pattern = try! NSRegularExpression(pattern: "target_token=\\{pid:(\\d+),")
        let matches = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output))

        for match in matches {
            if let range = Range(match.range(at: 1), in: output),
               let pid = pid_t(output[range]) {
                pids.insert(pid)
            }
        }

        // Filter: only keep PIDs that are still running, exclude system processes
        let myPID = ProcessInfo.processInfo.processIdentifier
        pids.remove(myPID)

        let runningPIDs = pids.filter { pid in
            pid > 100 && kill(pid, 0) == 0  // Process still exists
        }

        // Further filter: exclude systemsoundserverd and other system daemons
        let systemNames: Set<String> = ["systemsoundserverd", "coreaudiod", "audioclipd"]
        return runningPIDs.filter { pid in
            guard let name = processName(for: pid) else { return false }
            return !systemNames.contains(name)
        }
    }

    // MARK: - CoreAudio PID detection

    private func pidsWithActiveAudioInput(activeDeviceIDs: [AudioDeviceID]) -> [pid_t] {
        var pids = Set<pid_t>()

        for deviceID in activeDeviceIDs {
            if let hogPID = hogModePID(for: deviceID), hogPID > 0 {
                pids.insert(hogPID)
            }
            let tapPIDs = pidsFromAudioTaps(deviceID: deviceID)
            pids.formUnion(tapPIDs)
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        pids.remove(myPID)
        pids = pids.filter { $0 > 1 }

        return Array(pids)
    }

    private func hogModePID(for deviceID: AudioDeviceID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &pid)
        guard status == noErr, pid >= 0 else { return nil }
        return pid
    }

    private func pidsFromAudioTaps(deviceID: AudioDeviceID) -> [pid_t] {
        let kAudioDevicePropertyTapList: AudioObjectPropertySelector = 0x74617023
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return [] }

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var tapIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &tapIDs)
        guard status == noErr else { return [] }

        let kAudioTapPropertyCreatorPID: AudioObjectPropertySelector = 0x70696463
        var pids: [pid_t] = []
        for tapID in tapIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyCreatorPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(tapID, &pidAddress) else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(tapID, &pidAddress, 0, nil, &pidSize, &pid)
            if pidStatus == noErr, pid > 0 {
                pids.append(pid)
            }
        }
        return pids
    }

    // MARK: - TCC Heuristic (last resort)

    private func appsByTCCHeuristic() -> (apps: [AppInfo], tccReadable: Bool) {
        let (permittedBundleIDs, readable) = bundleIDsWithMicPermission()
        guard readable else { return ([], false) }

        let runningApps = NSWorkspace.shared.runningApplications
        var results: [AppInfo] = []
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  permittedBundleIDs.contains(bundleID),
                  app.activationPolicy == .regular || isKnownAudioApp(bundleID) else {
                continue
            }
            results.append(AppInfo(
                name: app.localizedName ?? bundleID,
                bundleIdentifier: bundleID,
                icon: app.icon
            ))
        }
        return (results, true)
    }

    private func bundleIDsWithMicPermission() -> (Set<String>, Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tccPath = home
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
            .path

        var db: OpaquePointer?
        guard sqlite3_open_v2(tccPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return ([], false)
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT client FROM access
            WHERE service = 'kTCCServiceMicrophone'
            AND auth_value = 2
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return ([], false)
        }
        defer { sqlite3_finalize(stmt) }

        var bundleIDs = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                bundleIDs.insert(String(cString: cString))
            }
        }
        return (bundleIDs, true)
    }

    private func isKnownAudioApp(_ bundleID: String) -> Bool {
        let audioApps: Set<String> = [
            "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
            "com.slack.Slack", "com.google.Chrome", "org.mozilla.firefox",
            "com.apple.Safari", "com.apple.FaceTime", "com.discord.Discord",
            "com.obsproject.obs-studio", "com.rogueamoeba.audiohijack",
            "com.skype.skype", "com.webex.meetingmanager",
        ]
        return audioApps.contains(bundleID)
    }

    // MARK: - Helpers

    private func appsFromPIDs(_ pids: [pid_t]) -> [AppInfo] {
        let runningApps = NSWorkspace.shared.runningApplications
        var results: [AppInfo] = []
        var seen = Set<pid_t>()

        for pid in pids {
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)

            if let app = runningApps.first(where: { $0.processIdentifier == pid }) {
                results.append(AppInfo(
                    name: app.localizedName ?? "PID \(pid)",
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon
                ))
            } else {
                // Helper process — try to find parent app
                let name = processName(for: pid) ?? "Unknown (\(pid))"
                // Chrome helpers: resolve to Chrome
                if name.contains("Chrome Helper") || name.contains("Google Chrome") {
                    if let chrome = runningApps.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
                        if !results.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
                            results.append(AppInfo(
                                name: chrome.localizedName ?? "Google Chrome",
                                bundleIdentifier: "com.google.Chrome",
                                icon: chrome.icon
                            ))
                        }
                        continue
                    }
                }
                // Firefox helpers
                if name.contains("firefox") || name.contains("Firefox") {
                    if let ff = runningApps.first(where: { $0.bundleIdentifier == "org.mozilla.firefox" }) {
                        if !results.contains(where: { $0.bundleIdentifier == "org.mozilla.firefox" }) {
                            results.append(AppInfo(
                                name: ff.localizedName ?? "Firefox",
                                bundleIdentifier: "org.mozilla.firefox",
                                icon: ff.icon
                            ))
                        }
                        continue
                    }
                }
                results.append(AppInfo(name: name, bundleIdentifier: nil, icon: nil))
            }
        }

        return results
    }

    private func processName(for pid: pid_t) -> String? {
        let pathBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let result = Darwin.proc_pidpath(Int32(pid), pathBuffer, UInt32(MAXPATHLEN))
        guard result > 0 else { return nil }
        let path = String(cString: pathBuffer)
        return (path as NSString).lastPathComponent
    }
}
