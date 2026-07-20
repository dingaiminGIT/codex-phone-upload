import AppKit
import ApplicationServices
import Foundation
import CodexPhoneUploadCore

@MainActor
final class CodexClipboardBridge {
    private var targetRoot: AXUIElement?
    private var targetComposer: AXUIElement?

    static func accessibilityGranted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func prepareTarget() throws -> String? {
        guard Self.accessibilityGranted(prompt: true) else {
            throw BridgeError.accessibilityNotGranted
        }
        guard let codex = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else {
            throw BridgeError.codexNotRunning
        }

        // Recent Codex builds expose only a shallow Chromium accessibility tree
        // while the app is in the background. Activate it before resolving the
        // composer, then bring this QR window back once the target is locked.
        codex.activate(options: [])
        defer { NSApplication.shared.activate(ignoringOtherApps: true) }

        let root = AXUIElementCreateApplication(codex.processIdentifier)
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(8)
        var nudgedComposer = false
        repeat {
            if let windowValue = attribute(root, kAXFocusedWindowAttribute),
               CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                let window = windowValue as! AXUIElement
                if let composer = focusedComposer(in: root) ?? findComposer(in: window) {
                    targetRoot = root
                    targetComposer = composer
                    return text(window, kAXTitleAttribute)
                }
                if !nudgedComposer, Date().timeIntervalSince(startedAt) >= 1.5 {
                    nudgeComposer(in: window)
                    nudgedComposer = true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline

        throw BridgeError.composerNotFound
    }

    func paste(_ images: [UploadedImage]) throws -> Int {
        guard !images.isEmpty else { return 0 }
        guard Self.accessibilityGranted(prompt: true) else {
            throw BridgeError.accessibilityNotGranted
        }
        guard let codex = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else {
            throw BridgeError.codexNotRunning
        }
        if targetRoot == nil || targetComposer == nil {
            _ = try prepareTarget()
        }
        guard let root = targetRoot, let composer = targetComposer else {
            throw BridgeError.targetUnavailable
        }

        codex.activate(options: [])
        Thread.sleep(forTimeInterval: 0.5)

        for (index, image) in images.enumerated() {
            do {
                let countBefore = attachmentCount(in: root, composer: composer)
                try writeImageToClipboard(image.data)
                try focusTargetComposer(in: root, composer: composer)
                try postPasteEvent()

                let deadline = Date().addingTimeInterval(3)
                var confirmed = false
                repeat {
                    Thread.sleep(forTimeInterval: 0.15)
                    if attachmentCount(in: root, composer: composer) > countBefore {
                        confirmed = true
                        break
                    }
                } while Date() < deadline
                guard confirmed else {
                    throw BridgeError.attachmentNotConfirmed
                }
            } catch {
                throw PartialPasteError(attached: index, total: images.count, underlying: error)
            }
        }
        return images.count
    }

    private func writeImageToClipboard(_ data: Data) throws {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BridgeError.imageDecodeFailed
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            throw BridgeError.clipboardWriteFailed
        }
        pasteboard.setData(tiff, forType: .tiff)
    }

    private func postPasteEvent() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw BridgeError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func focusTargetComposer(in root: AXUIElement, composer: AXUIElement) throws {
        guard point(composer, kAXPositionAttribute) != nil,
              size(composer, kAXSizeAttribute) != nil else {
            throw BridgeError.targetUnavailable
        }
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.15)
        if focusedRole(in: root) == "AXTextArea" {
            return
        }

        if let position = point(composer, kAXPositionAttribute),
           let size = size(composer, kAXSizeAttribute),
           let source = CGEventSource(stateID: .combinedSessionState) {
            let clickPoint = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + min(size.height / 2, 24)
            )
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: clickPoint,
                mouseButton: .left
            )
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: clickPoint,
                mouseButton: .left
            )
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard focusedRole(in: root) == "AXTextArea" else {
            throw BridgeError.composerFocusFailed
        }
    }

    private func findComposer(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var candidates: [(AXUIElement, CGPoint, CGSize)] = []
        var visited = 0
        while !queue.isEmpty && visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if isComposer(element),
               let position = point(element, kAXPositionAttribute),
               let elementSize = size(element, kAXSizeAttribute) {
                candidates.append((element, position, elementSize))
            }
            queue.append(contentsOf: children(element))
        }
        return candidates.max {
            ($0.1.y * 10 + $0.2.width) < ($1.1.y * 10 + $1.2.width)
        }?.0
    }

    private func focusedComposer(in root: AXUIElement) -> AXUIElement? {
        guard let focused = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        return isComposer(element) ? element : nil
    }

    private func isComposer(_ element: AXUIElement) -> Bool {
        guard text(element, kAXRoleAttribute) == "AXTextArea",
              let elementSize = size(element, kAXSizeAttribute) else { return false }
        return elementSize.width >= 280 && elementSize.height >= 24 && elementSize.height <= 400
    }

    private func nudgeComposer(in window: AXUIElement) {
        guard let windowPosition = point(window, kAXPositionAttribute),
              let windowSize = size(window, kAXSizeAttribute),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let clickPoint = CGPoint(
            x: windowPosition.x + windowSize.width / 2,
            y: windowPosition.y + max(24, windowSize.height - 78)
        )
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func attachmentCount(in root: AXUIElement, composer: AXUIElement) -> Int {
        guard let composerPosition = point(composer, kAXPositionAttribute),
              let composerSize = size(composer, kAXSizeAttribute) else { return 0 }
        let minX = composerPosition.x - 24
        let maxX = composerPosition.x + composerSize.width + 24
        let minY = composerPosition.y - 320
        let maxY = composerPosition.y + composerSize.height + 24
        var queue = [root]
        var count = 0
        var visited = 0
        while !queue.isEmpty && visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if text(element, kAXRoleAttribute) == "AXButton" {
                let description = text(element, kAXDescriptionAttribute)
                if (description.hasPrefix("Remove ") || description.contains("移除")),
                   let position = point(element, kAXPositionAttribute),
                   position.x >= minX, position.x <= maxX,
                   position.y >= minY, position.y <= maxY {
                    count += 1
                }
            }
            queue.append(contentsOf: children(element))
        }
        return count
    }

    private func focusedRole(in root: AXUIElement) -> String {
        guard let focused = attribute(root, kAXFocusedUIElementAttribute) else { return "" }
        return text(focused as! AXUIElement, kAXRoleAttribute)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func text(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
    }

    private func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as AnyObject?
    }

    struct PartialPasteError: LocalizedError {
        let attached: Int
        let total: Int
        let underlying: Error

        var errorDescription: String? {
            if attached > 0 {
                return "Attached \(attached) of \(total): \(underlying.localizedDescription)"
            }
            return underlying.localizedDescription
        }
    }

    enum BridgeError: LocalizedError {
        case accessibilityNotGranted
        case codexNotRunning
        case composerNotFound
        case composerFocusFailed
        case targetUnavailable
        case imageDecodeFailed
        case clipboardWriteFailed
        case eventCreationFailed
        case attachmentNotConfirmed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "请先在系统设置 > 隐私与安全性 > 辅助功能中允许“Codex 手机传图”"
            case .codexNotRunning:
                return "Codex 桌面应用未运行"
            case .composerNotFound:
                return "找不到当前 Codex 对话的输入框，请先打开目标任务"
            case .composerFocusFailed:
                return "无法聚焦当前 Codex 对话的输入框"
            case .targetUnavailable:
                return "目标 Codex 输入框已经关闭或改变，请重新生成二维码"
            case .imageDecodeFailed:
                return "无法读取上传的图片"
            case .clipboardWriteFailed:
                return "无法把图片写入系统剪贴板"
            case .eventCreationFailed:
                return "无法创建粘贴事件"
            case .attachmentNotConfirmed:
                return "图片没有出现在 Codex 输入框，请保持目标任务打开后重试"
            }
        }
    }
}
