import Darwin
import Foundation

final class CloudflareTunnel: @unchecked Sendable {
    enum TunnelError: LocalizedError {
        case notInstalled
        case timedOut
        case exited(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "cloudflared is not installed"
            case .timedOut:
                return "Cloudflare tunnel startup timed out"
            case .exited(let detail):
                return detail.isEmpty ? "Cloudflare tunnel stopped unexpectedly" : detail
            }
        }
    }

    typealias ReadyHandler = (URL) -> Void
    typealias FailureHandler = (TunnelError) -> Void

    private let executableURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var pipes: [Pipe] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var onReady: ReadyHandler?
    private var onFailure: FailureHandler?
    private var output = Data()
    private var ready = false
    private var stopping = false

    init(executableURL: URL, timeout: TimeInterval = 15) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let override = environment["CODEX_PHONE_UPLOAD_CLOUDFLARED"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared"
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/cloudflared" })
        }
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate).inserted && fileManager.isExecutableFile(atPath: candidate)
        }.map(URL.init(fileURLWithPath:))
    }

    func start(
        localPort: UInt16,
        onReady: @escaping ReadyHandler,
        onFailure: @escaping FailureHandler
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "tunnel",
            "--no-autoupdate",
            "--url", "http://127.0.0.1:\(localPort)"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        self.process = process
        pipes = [stdout, stderr]
        self.onReady = onReady
        self.onFailure = onFailure
        output = Data()
        ready = false
        stopping = false
        lock.unlock()

        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.processExited(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stop()
            throw error
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.startupTimedOut()
        }
        lock.lock()
        let shouldScheduleTimeout = !ready && !stopping
        if shouldScheduleTimeout {
            self.timeoutWorkItem = timeoutWorkItem
        }
        lock.unlock()
        if shouldScheduleTimeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let process = self.process
        let pipes = self.pipes
        let timeoutWorkItem = self.timeoutWorkItem
        self.process = nil
        self.pipes = []
        self.timeoutWorkItem = nil
        onReady = nil
        onFailure = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        pipes.forEach { $0.fileHandleForReading.readabilityHandler = nil }
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        output.append(data)
        if output.count > 64 * 1024 {
            output.removeFirst(output.count - 64 * 1024)
        }
        let text = String(data: output, encoding: .utf8) ?? ""
        var result: (ReadyHandler, URL)?
        if !ready, let url = Self.publicURL(in: text) {
            ready = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            if let onReady {
                result = (onReady, url)
            }
        }
        lock.unlock()
        if let result {
            result.0(result.1)
        }
    }

    private func startupTimedOut() {
        lock.lock()
        guard !stopping, !ready else {
            lock.unlock()
            return
        }
        let failure = onFailure
        lock.unlock()
        failure?(.timedOut)
        stop()
    }

    private func processExited(status: Int32) {
        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        let detail = String(data: output.suffix(2_000), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failure = onFailure
        lock.unlock()
        failure?(.exited(detail.isEmpty ? "cloudflared exited with status \(status)" : detail))
        stop()
    }

    static func publicURL(in output: String) -> URL? {
        let pattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range, in: output) else {
            return nil
        }
        return URL(string: String(output[range]))
    }
}
