import Foundation
import CodexPhoneUploadCore

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case english = "en"

    static let storageKey = "CodexPhoneUpload.language"

    var id: String { rawValue }

    static var preferred: AppLanguage {
        if let stored = UserDefaults.standard.string(forKey: storageKey),
           let language = AppLanguage(rawValue: stored) {
            return language
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .zhHans : .english
    }

    var menuLabel: String {
        switch self {
        case .zhHans: return "中文"
        case .english: return "English"
        }
    }

    var shortLabel: String {
        switch self {
        case .zhHans: return "中"
        case .english: return "EN"
        }
    }
}

struct AppText {
    let language: AppLanguage

    var appTitle: String { value("Codex 手机传图", "Codex Phone Upload") }
    var subtitle: String { value("可信 Wi-Fi · 10 分钟内可连续上传", "Trusted Wi-Fi · upload for 10 minutes") }
    var targetLabel: String { value("目标任务", "Target task") }
    var currentTask: String { value("当前 Codex 任务", "Current Codex task") }
    var idle: String { value("点击生成临时二维码", "Generate a temporary QR code") }
    var permissionRequired: String {
        value("请允许辅助功能权限，然后点“重新生成”", "Allow Accessibility access, then choose “New code”")
    }
    var starting: String { value("正在启动同一 Wi-Fi 上传服务…", "Starting the same-Wi-Fi upload service…") }
    var waiting: String { value("等待手机上传", "Waiting for phone upload") }
    var linkCopied: String { value("上传地址已复制", "Upload link copied") }
    var expired: String { value("二维码已过期，请重新生成", "QR code expired. Generate a new one") }
    var newCode: String { value("重新生成", "New code") }
    var copyLink: String { value("复制链接", "Copy link") }
    var close: String { value("关闭", "Close") }
    var privacySummary: String { value("最多 12 张 · 不发送 · 不分析", "Up to 12 · not sent · not analyzed") }
    var unavailable: String { value("手机传图工具暂时不可用", "Phone Upload is temporarily unavailable") }

    func targetName(_ discovered: String?) -> String {
        guard let discovered,
              !discovered.isEmpty,
              discovered.caseInsensitiveCompare("Codex") != .orderedSame else {
            return currentTask
        }
        return discovered
    }

    func remaining(seconds: Int) -> String {
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return value("\(time) 后失效", "Expires in \(time)")
    }

    func uploading(count: Int) -> String {
        value("正在把 \(count) 张图片放入 Codex…", "Attaching \(count) images to Codex…")
    }

    func success(count: Int) -> String {
        value(
            "已放入 \(count) 张，可继续从手机选择图片",
            "Attached \(count). You can keep choosing images on your phone"
        )
    }

    func partial(attached: Int, total: Int) -> String {
        value(
            "已放入 \(attached)/\(total) 张，请在手机上继续上传剩余图片",
            "Attached \(attached) of \(total). Continue with the remaining images on your phone"
        )
    }

    func serverStartFailed(_ reason: String) -> String {
        value("上传服务启动失败：\(reason)", "Upload service failed to start: \(reason)")
    }

    var noLocalAddress: String {
        value("找不到 Mac 的局域网地址，请确认已经连接 Wi-Fi", "No local Mac address found. Check the Wi-Fi connection")
    }

    func bridgeError(_ error: CodexClipboardBridge.BridgeError) -> String {
        switch error {
        case .accessibilityNotGranted:
            return value(
                "请先在系统设置 > 隐私与安全性 > 辅助功能中允许 CodexPhoneUpload",
                "Allow CodexPhoneUpload in System Settings > Privacy & Security > Accessibility"
            )
        case .codexNotRunning:
            return value("Codex 桌面应用未运行", "The Codex desktop app is not running")
        case .composerNotFound:
            return value("找不到当前 Codex 任务的输入框，请先打开目标任务", "No composer found. Open the target Codex task first")
        case .composerFocusFailed:
            return value("无法聚焦目标 Codex 输入框", "Could not focus the target Codex composer")
        case .targetUnavailable:
            return value("目标 Codex 输入框已经关闭或改变，请重新生成二维码", "The target Codex composer changed or closed. Generate a new QR code")
        case .imageDecodeFailed:
            return value("无法读取上传的图片", "An uploaded image could not be read")
        case .clipboardWriteFailed:
            return value("无法把图片写入系统剪贴板", "Could not write the image to the clipboard")
        case .eventCreationFailed:
            return value("无法创建粘贴事件", "Could not create the paste event")
        case .attachmentNotConfirmed:
            return value("图片没有出现在 Codex 输入框", "The image did not appear in the Codex composer")
        }
    }

    func validationError(_ error: UploadValidationError) -> String {
        switch error {
        case .malformedRequest:
            return value("上传请求格式不正确", "The upload request is malformed")
        case .noImages:
            return value("请选择至少一张图片", "Select at least one image")
        case .tooManyImages:
            return value("一次最多上传 12 张图片", "You can upload up to 12 images")
        case .imageTooLarge:
            return value("单张图片不能超过 25 MB", "Each image must be 25 MB or smaller")
        case .unsupportedImage:
            return value(
                "只支持 PNG、JPEG、GIF、WebP、HEIC 和 HEIF 图片",
                "Only PNG, JPEG, GIF, WebP, HEIC, and HEIF images are supported"
            )
        }
    }

    func value(_ chinese: String, _ english: String) -> String {
        language == .zhHans ? chinese : english
    }
}
