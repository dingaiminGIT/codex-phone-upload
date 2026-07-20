import AppKit
import Foundation
import CodexPhoneUploadCore

@MainActor
final class UploadCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case uploading
        case success
        case failure
        case expired
    }

    private enum StatusState {
        case idle
        case permissionRequired
        case starting
        case ready
        case copied
        case uploading(Int)
        case success(Int)
        case partial(Int, Int)
        case expired
        case failure(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private var statusState: StatusState = .idle
    @Published private(set) var language = AppLanguage.preferred
    @Published private(set) var mode: UploadMode = .local
    @Published private(set) var uploadURL: URL?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var targetName: String?
    @Published private(set) var diagnosticReport: String?
    @Published private(set) var diagnosticCopied = false

    private var server: LocalUploadServer?
    private let bridge = CodexClipboardBridge()
    private var sessionGeneration = UUID()

    var text: AppText { AppText(language: language) }

    var status: String {
        switch statusState {
        case .idle: return text.idle
        case .permissionRequired: return text.permissionRequired
        case .starting: return text.starting(mode: mode)
        case .ready: return text.waiting
        case .copied: return text.linkCopied
        case .uploading(let count): return text.uploading(count: count)
        case .success(let count): return text.success(count: count)
        case .partial(let attached, let total): return text.partial(attached: attached, total: total)
        case .expired: return text.expired
        case .failure(let message): return message
        }
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey)
        if case .failure = statusState {
            statusState = .failure(text.unavailable)
        }
    }

    func setMode(_ mode: UploadMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        newSession()
    }

    func ensureSession() {
        if phase == .idle || phase == .expired {
            newSession()
        }
    }

    func newSession() {
        sessionGeneration = UUID()
        let generation = sessionGeneration
        stopSession()
        phase = .starting
        statusState = .starting
        uploadURL = nil
        qrImage = nil
        expiresAt = nil
        diagnosticReport = nil
        diagnosticCopied = false
        guard CodexClipboardBridge.accessibilityGranted(prompt: true) else {
            phase = .failure
            statusState = .permissionRequired
            captureDiagnostic(stage: "permissions", errorCode: "accessibility_not_granted")
            return
        }
        do {
            targetName = try bridge.prepareTarget()
        } catch let error as CodexClipboardBridge.BridgeError {
            phase = .failure
            statusState = .failure(text.bridgeError(error))
            captureDiagnostic(stage: "prepare_target", errorCode: error.diagnosticCode)
            return
        } catch {
            phase = .failure
            statusState = .failure(error.localizedDescription)
            captureDiagnostic(stage: "prepare_target", errorCode: "unexpected_error")
            return
        }
        guard sessionGeneration == generation else { return }
        let server = LocalUploadServer(
            mode: mode,
            targetName: text.targetName(targetName),
            onReady: { [weak self] session in
                DispatchQueue.main.async {
                    guard let self, self.sessionGeneration == generation else { return }
                    self.uploadURL = session.url
                    self.expiresAt = session.expiresAt
                    self.qrImage = QRCodeGenerator.image(for: session.url.absoluteString)
                    self.phase = .ready
                    self.statusState = .ready
                }
            },
            onState: { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.sessionGeneration == generation else { return }
                    switch state {
                    case .expired:
                        self.phase = .expired
                        self.statusState = .expired
                    case .uploading(let count):
                        self.phase = .uploading
                        self.statusState = .uploading(count)
                    case .success(let count):
                        self.phase = .ready
                        self.statusState = .success(count)
                    case .partialFailure(let attached, let total, let error):
                        self.phase = .failure
                        self.statusState = .partial(attached, total)
                        self.captureDiagnostic(stage: "attach_images", errorCode: self.diagnosticCode(for: error))
                    case .startupFailed(let reason):
                        self.phase = .failure
                        self.statusState = .failure(self.text.serverStartFailed(reason))
                        self.captureDiagnostic(stage: "start_server", errorCode: "server_startup_failed")
                    case .failure(let error):
                        self.phase = .failure
                        self.statusState = .failure(self.localized(error))
                        self.captureDiagnostic(stage: "attach_images", errorCode: self.diagnosticCode(for: error))
                    }
                }
            },
            onUpload: { [weak self] images, completion in
                DispatchQueue.main.async {
                    guard let self, self.sessionGeneration == generation else {
                        completion(.failure(CoordinatorError.unavailable))
                        return
                    }
                    self.phase = .uploading
                    self.statusState = .uploading(images.count)
                    do {
                        let count = try self.bridge.paste(images)
                        completion(.success(count))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        )
        self.server = server
        do {
            try server.start()
        } catch {
            phase = .failure
            captureDiagnostic(stage: "start_server", errorCode: diagnosticCode(for: error))
            if let serverError = error as? LocalUploadServer.ServerError {
                switch serverError {
                case .noLocalAddress:
                    statusState = .failure(text.noLocalAddress)
                case .listenerFailed:
                    statusState = .failure(text.serverStartFailed(""))
                }
            } else if let tunnelError = error as? CloudflareTunnel.TunnelError {
                statusState = .failure(text.tunnelError(tunnelError))
            } else {
                statusState = .failure(error.localizedDescription)
            }
            self.server = nil
        }
    }

    func copyUploadURL() {
        guard let uploadURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uploadURL.absoluteString, forType: .string)
        statusState = .copied
    }

    func copyDiagnostics() {
        guard let diagnosticReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
        diagnosticCopied = true
    }

    func stopSession() {
        server?.stop()
        server = nil
    }

    func quit() {
        stopSession()
        NSApplication.shared.terminate(nil)
    }

    enum CoordinatorError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            AppText(language: AppLanguage.preferred).unavailable
        }
    }

    private func localized(_ error: Error) -> String {
        if let partial = error as? CodexClipboardBridge.PartialPasteError {
            return text.partial(attached: partial.attached, total: partial.total)
        }
        if let bridge = error as? CodexClipboardBridge.BridgeError {
            return text.bridgeError(bridge)
        }
        if let validation = error as? UploadValidationError {
            return text.validationError(validation)
        }
        if let tunnel = error as? CloudflareTunnel.TunnelError {
            return text.tunnelError(tunnel)
        }
        return error.localizedDescription
    }

    private func captureDiagnostic(stage: String, errorCode: String) {
        let toolVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let toolBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let codex = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        let codexBundle = codex?.bundleURL.flatMap(Bundle.init(url:))
        let codexVersion = codexBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let codexBuild = codexBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let report = CompatibilityDiagnostic(
            toolVersion: toolVersion,
            toolBuild: toolBuild,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            codexVersion: codexVersion,
            codexBuild: codexBuild,
            mode: mode == .local ? "same_wifi" : "public_https",
            accessibilityGranted: CodexClipboardBridge.accessibilityGranted(prompt: false),
            stage: stage,
            errorCode: errorCode,
            accessibility: bridge.diagnosticSnapshot
        )
        diagnosticReport = report.rendered()
        diagnosticCopied = false
    }

    private func diagnosticCode(for error: Error) -> String {
        if let partial = error as? CodexClipboardBridge.PartialPasteError {
            return diagnosticCode(for: partial.underlying)
        }
        if let bridge = error as? CodexClipboardBridge.BridgeError {
            return bridge.diagnosticCode
        }
        if let validation = error as? UploadValidationError {
            switch validation {
            case .malformedRequest: return "malformed_request"
            case .noImages: return "no_images"
            case .tooManyImages: return "too_many_images"
            case .imageTooLarge: return "image_too_large"
            case .unsupportedImage: return "unsupported_image"
            }
        }
        if let server = error as? LocalUploadServer.ServerError {
            switch server {
            case .noLocalAddress: return "no_local_address"
            case .listenerFailed: return "listener_failed"
            }
        }
        if let tunnel = error as? CloudflareTunnel.TunnelError {
            switch tunnel {
            case .notInstalled: return "cloudflared_not_installed"
            case .timedOut: return "cloudflare_tunnel_timed_out"
            case .exited: return "cloudflare_tunnel_exited"
            }
        }
        return "unexpected_error"
    }
}
