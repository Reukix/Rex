import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class ProcessMetricsMonitor: ObservableObject {
    static let shared = ProcessMetricsMonitor()

    @Published private(set) var memoryBytes: UInt64 = 0
    @Published private(set) var cpuPercent: Double = 0

    private var timer: Timer?
    private var previousCPUTimeByProcess: [ProcessIdentity: Double] = [:]
    private var previousSampleUptime = ProcessInfo.processInfo.systemUptime
    private var subscriberCount = 0
    private var sampleInFlight = false
    private var samplingGeneration: UInt64 = 0
    private var activationObservers: [NSObjectProtocol] = []

    /// 采样本身要遍历全部 Helper 进程；应用失焦时降低频率以减少自身开销。
    private static let activeSampleInterval: TimeInterval = 1.5
    private static let inactiveSampleInterval: TimeInterval = 6.0

    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    var cpuLabel: String {
        String(format: "%.0f%%", min(max(cpuPercent, 0), 999))
    }

    func start() {
        subscriberCount += 1
        guard subscriberCount == 1 else { return }
        samplingGeneration &+= 1
        requestSample()
        scheduleTimer()
        installActivationObservers()
    }

    func stop() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
        samplingGeneration &+= 1
        sampleInFlight = false
        previousCPUTimeByProcess.removeAll()
        previousSampleUptime = ProcessInfo.processInfo.systemUptime
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = NSApplication.shared.isActive
            ? Self.activeSampleInterval
            : Self.inactiveSampleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installActivationObservers() {
        guard activationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ]
        activationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.subscriberCount > 0 else { return }
                    self.scheduleTimer()
                    if NSApplication.shared.isActive { self.requestSample() }
                }
            }
        }
    }

    private func requestSample() {
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let generation = samplingGeneration
        Task.detached(priority: .utility) { [weak self] in
            let usage = Self.processUsage()
            await MainActor.run {
                guard let self, self.samplingGeneration == generation else { return }
                self.sampleInFlight = false
                guard self.subscriberCount > 0, let usage else { return }
                self.apply(usage)
            }
        }
    }

    private func apply(_ usage: ProcessUsage) {
        // 仅在可见变化时发布，避免每次采样都触发 SwiftUI 工具栏重绘。
        if distance(memoryBytes, usage.physicalFootprint) >= 1_048_576 {
            memoryBytes = usage.physicalFootprint
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousSampleUptime
        if elapsed > 0.05, !previousCPUTimeByProcess.isEmpty {
            let delta = usage.cpuSecondsByProcess.reduce(into: 0.0) { total, entry in
                if let previous = previousCPUTimeByProcess[entry.key] {
                    total += max(0, entry.value - previous)
                } else {
                    // A newly launched helper's lifetime is contained in this sample interval.
                    total += entry.value
                }
            }
            // Process CPU percentage relative to a single core (can exceed 100% on multi-core).
            let nextCPUPercent = (delta / elapsed) * 100.0
            if abs(nextCPUPercent - cpuPercent) >= 0.5 {
                cpuPercent = nextCPUPercent
            }
        }
        previousCPUTimeByProcess = usage.cpuSecondsByProcess
        previousSampleUptime = now
    }

    private func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }

    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startTime: UInt64
        let uuidFingerprint: UInt64
    }

    private struct ProcessUsage: Sendable {
        let physicalFootprint: UInt64
        let cpuSecondsByProcess: [ProcessIdentity: Double]
    }

    private struct ProcessSample: Sendable {
        let identity: ProcessIdentity
        let physicalFootprint: UInt64
        let cpuSeconds: Double
    }

    nonisolated private static func processUsage() -> ProcessUsage? {
        let rootPID = getpid()
        var pending: [(
            pid: pid_t,
            expectedParentPID: pid_t?,
            expectedParentIdentity: ProcessIdentity?
        )] = [(rootPID, nil, nil)]
        var visited = Set<pid_t>()
        var cpuSecondsByProcess: [ProcessIdentity: Double] = [:]
        var totalPhysicalFootprint: UInt64 = 0
        var nextIndex = 0

        while nextIndex < pending.count {
            let candidate = pending[nextIndex]
            nextIndex += 1
            guard visited.insert(candidate.pid).inserted else { continue }
            if let parentPID = candidate.expectedParentPID,
               let parentIdentity = candidate.expectedParentIdentity,
               processIdentity(for: parentPID) != parentIdentity {
                continue
            }
            guard let sample = processSample(
                for: candidate.pid,
                expectedParentPID: candidate.expectedParentPID
            ) else { continue }
            if let parentPID = candidate.expectedParentPID,
               let parentIdentity = candidate.expectedParentIdentity,
               processIdentity(for: parentPID) != parentIdentity {
                continue
            }

            let (sum, overflow) = totalPhysicalFootprint.addingReportingOverflow(sample.physicalFootprint)
            totalPhysicalFootprint = overflow ? .max : sum
            cpuSecondsByProcess[sample.identity] = sample.cpuSeconds

            for childPID in childPIDs(of: candidate.pid) where !visited.contains(childPID) {
                pending.append((childPID, candidate.pid, sample.identity))
            }
        }

        guard !cpuSecondsByProcess.isEmpty else { return nil }
        return ProcessUsage(
            physicalFootprint: totalPhysicalFootprint,
            cpuSecondsByProcess: cpuSecondsByProcess
        )
    }

    nonisolated private static func processSample(
        for pid: pid_t,
        expectedParentPID: pid_t?
    ) -> ProcessSample? {
        guard let before = bsdInfo(for: pid) else { return nil }
        if let expectedParentPID, before.pbi_ppid != UInt32(expectedParentPID) {
            return nil
        }

        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
        }
        guard result == 0, info.ri_proc_exit_abstime == 0,
              let after = bsdInfo(for: pid),
              before.pbi_pid == after.pbi_pid,
              before.pbi_ppid == after.pbi_ppid,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }

        let nanoseconds = info.ri_user_time &+ info.ri_system_time
        let uuidFingerprint = withUnsafeBytes(of: info.ri_uuid) { bytes in
            bytes.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        return ProcessSample(
            identity: ProcessIdentity(
                pid: pid,
                startTime: info.ri_proc_start_abstime,
                uuidFingerprint: uuidFingerprint
            ),
            physicalFootprint: info.ri_phys_footprint,
            cpuSeconds: Double(nanoseconds) / 1_000_000_000
        )
    }

    nonisolated private static func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        processSample(for: pid, expectedParentPID: nil)?.identity
    }

    nonisolated private static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        return result == expectedSize ? info : nil
    }

    nonisolated private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let reportedCount = proc_listchildpids(parentPID, nil, 0)
        guard reportedCount > 0 else { return [] }

        var capacity = max(Int(reportedCount) + 8, 16)
        while capacity <= 4_096 {
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return [] }
            if count < capacity {
                return Array(children.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }
}
