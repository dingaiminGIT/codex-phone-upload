#!/usr/bin/env swift

import AppKit
import ApplicationServices
import CoreImage
import Foundation

enum PasteError: Error, CustomStringConvertible {
    case usage
    case fileMissing(String)
    case imageDecodeFailed(String)
    case codexNotRunning
    case clipboardWriteFailed
    case accessibilityNotGranted
    case composerNotFound
    case composerFocusFailed
    case attachmentNotConfirmed
    case eventCreationFailed
    case qrGenerationFailed

    var description: String {
        switch self {
        case .usage:
            return "用法：paste_files.swift [--check-accessibility | --focus-only | --clipboard-only | --generate-qr <内容> <输出路径>] <图片路径> [...]"
        case .fileMissing(let path):
            return "临时图片不存在：\(path)"
        case .imageDecodeFailed(let path):
            return "无法读取临时图片：\(path)"
        case .codexNotRunning:
            return "Codex 桌面应用未运行"
        case .clipboardWriteFailed:
            return "无法把图片写入系统剪贴板"
        case .accessibilityNotGranted:
            return "Codex 尚未获得 macOS 辅助功能权限，请在系统设置 > 隐私与安全性 > 辅助功能中允许 Codex"
        case .composerNotFound:
            return "找不到当前 Codex 对话的输入框"
        case .composerFocusFailed:
            return "无法聚焦当前 Codex 对话的输入框"
        case .attachmentNotConfirmed:
            return "图片粘贴后未出现在 Codex 输入框中，请保持目标对话处于打开状态后重试"
        case .eventCreationFailed:
            return "无法创建粘贴键盘事件"
        case .qrGenerationFailed:
            return "无法生成上传二维码"
        }
    }
}

struct PartialPasteError: Error, CustomStringConvertible {
    let attached: Int
    let total: Int
    let underlying: Error

    var description: String {
        "PARTIAL_ATTACHED=\(attached);TOTAL=\(total);ERROR=\(underlying)"
    }
}

func generateQRCode(content: String, outputURL: URL) throws {
    guard let message = content.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else {
        throw PasteError.qrGenerationFailed
    }
    filter.setValue(message, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(
        by: CGAffineTransform(scaleX: 9, y: 9)
    ) else {
        throw PasteError.qrGenerationFailed
    }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cgImage = context.createCGImage(image, from: image.extent) else {
        throw PasteError.qrGenerationFailed
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw PasteError.qrGenerationFailed
    }
    do {
        try png.write(to: outputURL, options: .atomic)
    } catch {
        throw PasteError.qrGenerationFailed
    }
}

func clipboardRepresentations(for url: URL) throws -> (png: Data, tiff: Data?) {
    guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw PasteError.imageDecodeFailed(url.path)
    }
    return (png, tiff)
}

func writeImageToClipboard(_ url: URL) throws {
    let representations = try clipboardRepresentations(for: url)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setData(representations.png, forType: .png) else {
        throw PasteError.clipboardWriteFailed
    }
    if let tiff = representations.tiff {
        pasteboard.setData(tiff, forType: .tiff)
    }
}

func postPasteEvent() throws {
    guard
        let source = CGEventSource(stateID: .combinedSessionState),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else {
        throw PasteError.eventCreationFailed
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func axAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as AnyObject?
}

func axText(_ element: AXUIElement, _ name: String) -> String {
    return axAttribute(element, name) as? String ?? ""
}

func axPoint(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = axAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func axSize(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = axAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

func findComposer(in root: AXUIElement) -> AXUIElement? {
    var queue = [root]
    var candidates: [(element: AXUIElement, position: CGPoint, size: CGSize)] = []
    var visited = 0
    while !queue.isEmpty && visited < 5000 {
        let element = queue.removeFirst()
        visited += 1
        if axText(element, kAXRoleAttribute) == "AXTextArea",
           let position = axPoint(element, kAXPositionAttribute),
           let size = axSize(element, kAXSizeAttribute),
           size.width >= 280, size.height >= 24, size.height <= 400 {
            candidates.append((element, position, size))
        }
        if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children)
        }
    }
    return candidates.max {
        let lhsScore = $0.position.y * 10 + $0.size.width
        let rhsScore = $1.position.y * 10 + $1.size.width
        return lhsScore < rhsScore
    }?.element
}

func isComposer(_ element: AXUIElement) -> Bool {
    guard axText(element, kAXRoleAttribute) == "AXTextArea",
          let size = axSize(element, kAXSizeAttribute) else { return false }
    return size.width >= 280 && size.height >= 24 && size.height <= 400
}

func focusedComposer(in root: AXUIElement) -> AXUIElement? {
    guard let focused = axAttribute(root, kAXFocusedUIElementAttribute),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let element = focused as! AXUIElement
    return isComposer(element) ? element : nil
}

func nudgeComposer(in window: AXUIElement) {
    guard let windowPosition = axPoint(window, kAXPositionAttribute),
          let windowSize = axSize(window, kAXSizeAttribute),
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

func composerAttachmentCount(in root: AXUIElement, composer: AXUIElement) -> Int {
    guard let composerPosition = axPoint(composer, kAXPositionAttribute),
          let composerSize = axSize(composer, kAXSizeAttribute) else {
        return 0
    }
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
        if axText(element, kAXRoleAttribute) == "AXButton" {
            let description = axText(element, kAXDescriptionAttribute)
            if (description.hasPrefix("Remove ") || description.contains("移除")),
               let position = axPoint(element, kAXPositionAttribute),
               position.x >= minX, position.x <= maxX,
               position.y >= minY, position.y <= maxY {
                count += 1
            }
        }
        if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children)
        }
    }
    return count
}

func resolveTarget(for app: NSRunningApplication) throws -> (root: AXUIElement, composer: AXUIElement) {
    // Chromium may expose only a shallow accessibility tree while Codex is in
    // the background. Activate it first and allow the full tree to hydrate.
    app.activate(options: [])
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(8)
    var nudgedComposer = false
    repeat {
        if let windowValue = axAttribute(root, kAXFocusedWindowAttribute),
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            let window = windowValue as! AXUIElement
            if let composer = focusedComposer(in: root) ?? findComposer(in: window) {
                return (root, composer)
            }
            if !nudgedComposer, Date().timeIntervalSince(startedAt) >= 1.5 {
                nudgeComposer(in: window)
                nudgedComposer = true
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
    } while Date() < deadline
    throw PasteError.composerNotFound
}

func focusComposer(in root: AXUIElement, composer: AXUIElement) throws -> AXUIElement {
    guard axPoint(composer, kAXPositionAttribute) != nil,
          axSize(composer, kAXSizeAttribute) != nil else {
        throw PasteError.composerNotFound
    }
    AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.15)
    if let focused = axAttribute(root, kAXFocusedUIElementAttribute) {
        let role = axText(focused as! AXUIElement, kAXRoleAttribute)
        if role == "AXTextArea" {
            return composer
        }
    }

    if let position = axPoint(composer, kAXPositionAttribute),
       let size = axSize(composer, kAXSizeAttribute),
       let source = CGEventSource(stateID: .combinedSessionState),
       let mouseDown = CGEvent(
           mouseEventSource: source,
           mouseType: .leftMouseDown,
           mouseCursorPosition: CGPoint(x: position.x + size.width / 2, y: position.y + min(size.height / 2, 24)),
           mouseButton: .left
       ),
       let mouseUp = CGEvent(
           mouseEventSource: source,
           mouseType: .leftMouseUp,
           mouseCursorPosition: CGPoint(x: position.x + size.width / 2, y: position.y + min(size.height / 2, 24)),
           mouseButton: .left
       ) {
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
    }
    if let focused = axAttribute(root, kAXFocusedUIElementAttribute),
       axText(focused as! AXUIElement, kAXRoleAttribute) == "AXTextArea" {
        return composer
    }
    throw PasteError.composerFocusFailed
}

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let generateQR = arguments.first == "--generate-qr"
    if generateQR {
        guard arguments.count == 3 else {
            throw PasteError.usage
        }
        try generateQRCode(
            content: arguments[1],
            outputURL: URL(fileURLWithPath: arguments[2]).standardizedFileURL
        )
        print("QR_PATH=\(arguments[2])")
        return
    }
    let checkAccessibility = arguments.first == "--check-accessibility"
    if checkAccessibility {
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw PasteError.usage
        }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first != nil else {
            throw PasteError.codexNotRunning
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw PasteError.accessibilityNotGranted
        }
        print("ACCESSIBILITY=granted")
        return
    }
    let focusOnly = arguments.first == "--focus-only"
    if focusOnly {
        arguments.removeFirst()
        guard arguments.isEmpty,
              let codex = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
            throw PasteError.usage
        }
        let target = try resolveTarget(for: codex)
        codex.activate(options: [])
        Thread.sleep(forTimeInterval: 0.35)
        _ = try focusComposer(in: target.root, composer: target.composer)
        print("COMPOSER_FOCUSED=true")
        return
    }
    let clipboardOnly = arguments.first == "--clipboard-only"
    if clipboardOnly {
        arguments.removeFirst()
    }
    guard !arguments.isEmpty else {
        throw PasteError.usage
    }

    let fileURLs = try arguments.map { path -> URL in
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PasteError.fileMissing(url.path)
        }
        return url
    }

    if clipboardOnly {
        try writeImageToClipboard(fileURLs[0])
        print("CLIPBOARD_FILES=\(fileURLs.count)")
        return
    }

    guard let codex = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.openai.codex"
    ).first else {
        throw PasteError.codexNotRunning
    }

    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw PasteError.accessibilityNotGranted
    }

    let target = try resolveTarget(for: codex)
    codex.activate(options: [])
    Thread.sleep(forTimeInterval: 0.65)
    let root = target.root
    let composer = try focusComposer(in: root, composer: target.composer)

    for (index, url) in fileURLs.enumerated() {
        do {
            let countBefore = composerAttachmentCount(in: root, composer: composer)
            try writeImageToClipboard(url)
            _ = try focusComposer(in: root, composer: composer)
            try postPasteEvent()
            let deadline = Date().addingTimeInterval(3)
            var confirmed = false
            repeat {
                Thread.sleep(forTimeInterval: 0.15)
                if composerAttachmentCount(in: root, composer: composer) > countBefore {
                    confirmed = true
                    break
                }
            } while Date() < deadline
            guard confirmed else {
                throw PasteError.attachmentNotConfirmed
            }
        } catch {
            throw PartialPasteError(attached: index, total: fileURLs.count, underlying: error)
        }
    }
    print("PASTED_FILES=\(fileURLs.count)")
}

do {
    try run()
} catch {
    fputs("ERROR=\(error)\n", stderr)
    exit(1)
}
