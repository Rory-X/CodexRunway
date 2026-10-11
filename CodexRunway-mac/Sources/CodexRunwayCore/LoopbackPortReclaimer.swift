import Darwin
import Foundation

/// Frees a localhost TCP port by stopping whatever is listening on it.
enum LoopbackPortReclaimer {
    static func reclaim(port: UInt16) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let listeners = pidsToStop(listeners: listeningPIDs(port: port), ownPID: ownPID)
        guard !listeners.isEmpty else { return }
        signal(listeners, SIGTERM)
        if waitUntilFree(port: port, ownPID: ownPID, timeout: 0.6) { return }
        let remaining = pidsToStop(listeners: listeningPIDs(port: port), ownPID: ownPID)
        signal(remaining, SIGKILL)
        _ = waitUntilFree(port: port, ownPID: ownPID, timeout: 0.6)
    }

    static func pidsToStop(listeners: [Int32], ownPID: Int32) -> [Int32] {
        var seen = Set<Int32>()
        return listeners.filter { pid in
            pid > 1 && pid != ownPID && seen.insert(pid).inserted
        }
    }

    static func parsePIDs(_ text: String) -> [Int32] {
        text.split { $0.isWhitespace || $0 == "," }.compactMap { Int32($0) }
    }

    private static func listeningPIDs(port: UInt16) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return parsePIDs(String(decoding: data, as: UTF8.self))
    }

    private static func signal(_ pids: [Int32], _ signal: Int32) {
        for pid in pids {
            _ = kill(pid, signal)
        }
    }

    private static func waitUntilFree(port: UInt16, ownPID: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pidsToStop(listeners: listeningPIDs(port: port), ownPID: ownPID).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return pidsToStop(listeners: listeningPIDs(port: port), ownPID: ownPID).isEmpty
    }
}
