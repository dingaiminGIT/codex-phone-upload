import Foundation

@main
struct CloudflareTunnelSelfTests {
    static func main() throws {
        try parsesQuickTunnelURL()
        try startsAndStopsTunnelProcess()
        try reportsStartupTimeout()
        print("CloudflareTunnel self-tests passed")
    }

    private static func parsesQuickTunnelURL() throws {
        let output = "INF Your quick Tunnel has been created! Visit https://unit-test.trycloudflare.com"
        guard CloudflareTunnel.publicURL(in: output)?.absoluteString == "https://unit-test.trycloudflare.com",
              CloudflareTunnel.publicURL(in: "https://example.com") == nil else {
            throw SelfTestFailure("Quick Tunnel URL parsing failed")
        }
    }

    private static func startsAndStopsTunnelProcess() throws {
        let script = try temporaryScript("""
        #!/bin/sh
        echo 'INF https://unit-test.trycloudflare.com' >&2
        while true; do sleep 1; done
        """)
        let tunnel = CloudflareTunnel(executableURL: script, timeout: 2)
        let ready = DispatchSemaphore(value: 0)
        var receivedURL: URL?
        var receivedError: Error?
        try tunnel.start(
            localPort: 43210,
            onReady: { url in
                receivedURL = url
                ready.signal()
            },
            onFailure: { error in
                receivedError = error
                ready.signal()
            }
        )
        guard ready.wait(timeout: .now() + 3) == .success,
              receivedURL?.absoluteString == "https://unit-test.trycloudflare.com",
              receivedError == nil else {
            tunnel.stop()
            throw SelfTestFailure("Tunnel process did not report its public URL")
        }
        tunnel.stop()
    }

    private static func reportsStartupTimeout() throws {
        let script = try temporaryScript("""
        #!/bin/sh
        while true; do sleep 1; done
        """)
        let tunnel = CloudflareTunnel(executableURL: script, timeout: 0.1)
        let failed = DispatchSemaphore(value: 0)
        var timedOut = false
        try tunnel.start(
            localPort: 43211,
            onReady: { _ in failed.signal() },
            onFailure: { error in
                if case CloudflareTunnel.TunnelError.timedOut = error {
                    timedOut = true
                }
                failed.signal()
            }
        )
        guard failed.wait(timeout: .now() + 2) == .success, timedOut else {
            tunnel.stop()
            throw SelfTestFailure("Tunnel startup timeout was not reported")
        }
        tunnel.stop()
    }

    private static func temporaryScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexPhoneUploadTunnelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-cloudflared")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

private struct SelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
