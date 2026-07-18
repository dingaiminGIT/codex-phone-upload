import AppKit
import Foundation

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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "点击生成一次性二维码"
    @Published private(set) var uploadURL: URL?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var expiresAt: Date?

    private var server: LocalUploadServer?
    private let bridge = CodexClipboardBridge()

    func ensureSession() {
        if phase == .idle || phase == .expired {
            newSession()
        }
    }

    func newSession() {
        stopSession()
        guard CodexClipboardBridge.accessibilityGranted(prompt: true) else {
            phase = .failure
            status = "请允许辅助功能权限，然后点“换一个”"
            return
        }
        phase = .starting
        status = "正在启动同一 Wi-Fi 上传服务…"
        uploadURL = nil
        qrImage = nil
        expiresAt = nil

        let server = LocalUploadServer(
            onReady: { [weak self] session in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.uploadURL = session.url
                    self.expiresAt = session.expiresAt
                    self.qrImage = QRCodeGenerator.image(for: session.url.absoluteString)
                    self.phase = .ready
                    self.status = "等待手机上传"
                }
            },
            onState: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.status = message
                    if message.contains("过期") {
                        self.phase = .expired
                    } else if message.hasPrefix("已放入") {
                        self.phase = .success
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard self?.phase == .success else { return }
                            self?.quit()
                        }
                    } else if message.hasPrefix("正在把") {
                        self.phase = .uploading
                    } else if message.contains("失败") || message.contains("找不到") || message.contains("请先") || message.contains("没有出现在") {
                        self.phase = .failure
                    }
                }
            },
            onUpload: { [weak self] images, completion in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(.failure(CoordinatorError.unavailable))
                        return
                    }
                    self.phase = .uploading
                    self.status = "正在把 \(images.count) 张图片放入 Codex…"
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
            status = error.localizedDescription
            self.server = nil
        }
    }

    func copyUploadURL() {
        guard let uploadURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uploadURL.absoluteString, forType: .string)
        status = "上传地址已复制"
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
            "菜单栏工具暂时不可用"
        }
    }
}
