import Darwin
import Foundation
import Network
import CodexPhoneUploadCore

final class LocalUploadServer: @unchecked Sendable {
    struct ReadySession {
        let url: URL
        let expiresAt: Date
    }

    enum State {
        case expired
        case startupFailed(String)
        case uploading(Int)
        case success(Int)
        case partialFailure(attached: Int, total: Int, reason: String)
        case failure(Error)
    }

    typealias UploadHandler = ([UploadedImage], @escaping (Result<Int, Error>) -> Void) -> Void

    private let queue = DispatchQueue(label: "local.dingaimin.CodexPhoneUploadMenu.server")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let ttl: TimeInterval
    private let mode: UploadMode
    private let targetName: String
    private let onReady: (ReadySession) -> Void
    private let onState: (State) -> Void
    private let onUpload: UploadHandler
    private var listener: NWListener?
    private var tunnel: CloudflareTunnel?
    private var expiryWorkItem: DispatchWorkItem?
    private var handlingUpload = false
    private var expiresAt = Date()
    private var published = false

    init(
        ttl: TimeInterval = 10 * 60,
        mode: UploadMode,
        targetName: String,
        onReady: @escaping (ReadySession) -> Void,
        onState: @escaping (State) -> Void,
        onUpload: @escaping UploadHandler
    ) {
        self.ttl = ttl
        self.mode = mode
        self.targetName = targetName
        self.onReady = onReady
        self.onState = onState
        self.onUpload = onUpload
    }

    func start() throws {
        let localAddress = Self.localIPv4Address()
        if mode == .local, localAddress == nil {
            throw ServerError.noLocalAddress
        }
        let cloudflared = mode == .remote ? CloudflareTunnel.locateExecutable() : nil
        if mode == .remote, cloudflared == nil {
            throw CloudflareTunnel.TunnelError.notInstalled
        }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.onState(.startupFailed(ServerError.listenerFailed.localizedDescription))
                    return
                }
                let path = "/upload/\(self.token)"
                if self.mode == .local {
                    guard let localAddress,
                          let url = URL(string: "http://\(localAddress):\(port.rawValue)\(path)") else {
                        self.onState(.startupFailed(ServerError.listenerFailed.localizedDescription))
                        return
                    }
                    self.publish(url: url)
                } else if let cloudflared {
                    self.startTunnel(executableURL: cloudflared, port: port.rawValue, path: path)
                }
            case .failed(let error):
                self.onState(.startupFailed(error.localizedDescription))
                self.stop()
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        tunnel?.stop()
        tunnel = nil
        listener?.cancel()
        listener = nil
        published = false
    }

    private func startTunnel(executableURL: URL, port: UInt16, path: String) {
        let tunnel = CloudflareTunnel(executableURL: executableURL)
        self.tunnel = tunnel
        do {
            try tunnel.start(
                localPort: port,
                onReady: { [weak self, weak tunnel] baseURL in
                    guard let self, let tunnel else { return }
                    self.queue.async {
                        guard self.tunnel === tunnel,
                              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return }
                        self.publish(url: url)
                    }
                },
                onFailure: { [weak self, weak tunnel] error in
                    guard let self, let tunnel else { return }
                    self.queue.async {
                        guard self.tunnel === tunnel else { return }
                        if self.published {
                            self.onState(.failure(error))
                        } else {
                            self.onState(.startupFailed(error.localizedDescription))
                        }
                        self.stop()
                    }
                }
            )
        } catch {
            onState(.startupFailed(error.localizedDescription))
            stop()
        }
    }

    private func publish(url: URL) {
        guard !published else { return }
        published = true
        expiresAt = Date().addingTimeInterval(ttl)
        onReady(ReadySession(url: url, expiresAt: expiresAt))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onState(.expired)
            self.stop()
        }
        expiryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + ttl, execute: workItem)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), expectedLength: nil)
    }

    private func receive(_ connection: NWConnection, buffer: Data, expectedLength: Int?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if nextBuffer.count > MultipartParser.maxRequestBytes + 64 * 1024 {
                self.sendJSON(connection, status: 413, payload: ["code": "totalTooLarge", "error": "Upload is too large"])
                return
            }

            var nextExpectedLength = expectedLength
            if nextExpectedLength == nil,
               let headerRange = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = nextBuffer[..<headerRange.lowerBound]
                let headers = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.headerValue("Content-Length", in: headers).flatMap(Int.init) ?? 0
                nextExpectedLength = headerRange.upperBound + contentLength
            }

            if let expected = nextExpectedLength, nextBuffer.count >= expected {
                self.processRequest(connection, request: Data(nextBuffer.prefix(expected)))
                return
            }
            if let error {
                self.sendJSON(connection, status: 400, payload: ["error": error.localizedDescription])
                return
            }
            if isComplete {
                self.processRequest(connection, request: nextBuffer)
                return
            }
            self.receive(connection, buffer: nextBuffer, expectedLength: nextExpectedLength)
        }
    }

    private func processRequest(_ connection: NWConnection, request: Data) {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = request.range(of: delimiter),
              let headerText = String(data: request[..<headerRange.lowerBound], encoding: .utf8) else {
            sendJSON(connection, status: 400, payload: ["error": "请求格式不正确"])
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendJSON(connection, status: 400, payload: ["error": "请求格式不正确"])
            return
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            sendJSON(connection, status: 400, payload: ["error": "请求格式不正确"])
            return
        }
        let method = String(requestParts[0])
        let path = String(requestParts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let expectedPath = "/upload/\(token)"

        if path == "/favicon.ico" {
            send(connection, status: 204, contentType: "text/plain", body: Data())
            return
        }
        guard path == expectedPath, Date() < expiresAt else {
            send(connection, status: 410, contentType: "text/plain; charset=utf-8", body: Data("上传链接已失效".utf8))
            return
        }
        if method == "GET" {
            let body = Data(MobileUploadPage.html(expiresAt: expiresAt, targetName: targetName, mode: mode).utf8)
            send(
                connection,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: body,
                extraHeaders: [
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' blob: data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
                    "X-Content-Type-Options": "nosniff"
                ]
            )
            return
        }
        guard method == "POST" else {
            sendJSON(connection, status: 405, payload: ["error": "请求方法不支持"])
            return
        }
        guard !handlingUpload else {
            sendJSON(connection, status: 409, payload: ["code": "failure", "error": "An upload is already being processed"])
            return
        }
        let contentType = Self.headerValue("Content-Type", in: headerText) ?? ""
        guard let boundary = Self.boundary(from: contentType) else {
            sendJSON(connection, status: 400, payload: ["error": "上传格式不正确"])
            return
        }
        let body = Data(request[headerRange.upperBound...])
        do {
            let images = try MultipartParser.parse(body: body, boundary: boundary)
            handlingUpload = true
            onState(.uploading(images.count))
            onUpload(images) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.handlingUpload = false
                    switch result {
                    case .success(let count):
                        self.sendJSON(connection, status: 200, payload: ["count": count])
                        self.onState(.success(count))
                    case .failure(let error):
                        if let partial = error as? CodexClipboardBridge.PartialPasteError,
                           partial.attached > 0 {
                            self.sendJSON(
                                connection,
                                status: 500,
                                payload: [
                                    "code": "partial",
                                    "error": partial.underlying.localizedDescription,
                                    "attached": partial.attached,
                                    "total": partial.total
                                ]
                            )
                            self.onState(
                                .partialFailure(
                                    attached: partial.attached,
                                    total: partial.total,
                                    reason: partial.underlying.localizedDescription
                                )
                            )
                        } else if let partial = error as? CodexClipboardBridge.PartialPasteError {
                            self.sendJSON(connection, status: 500, payload: Self.errorPayload(partial.underlying))
                            self.onState(.failure(partial.underlying))
                        } else {
                            self.sendJSON(connection, status: 500, payload: Self.errorPayload(error))
                            self.onState(.failure(error))
                        }
                    }
                }
            }
        } catch {
            sendJSON(connection, status: 400, payload: Self.errorPayload(error))
        }
    }

    private func sendJSON(_ connection: NWConnection, status: Int, payload: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        send(connection, status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private func send(
        _ connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 410: reason = "Gone"
        case 413: reason = "Payload Too Large"
        default: reason = "Internal Server Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        headers.append(contentsOf: extraHeaders.map { "\($0.key): \($0.value)" })
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func headerValue(_ name: String, in headerText: String) -> String? {
        let prefix = name.lowercased() + ":"
        return headerText.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private static func boundary(from contentType: String) -> String? {
        guard contentType.lowercased().contains("multipart/form-data") else { return nil }
        return contentType.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("boundary=") }
            .map { String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var candidates: [(priority: Int, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let item = interface.pointee
            defer { cursor = item.ifa_next }
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: item.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: hostname)
            guard !value.hasPrefix("169.254.") else { continue }
            let priority = name == "en0" ? 0 : (name == "en1" ? 1 : 2)
            candidates.append((priority, value))
        }
        return candidates.sorted { $0.priority < $1.priority }.first?.address
    }

    private static func errorPayload(_ error: Error) -> [String: Any] {
        guard let validation = error as? UploadValidationError else {
            return ["code": "failure", "error": error.localizedDescription]
        }
        switch validation {
        case .noImages:
            return ["code": "noImages", "error": validation.localizedDescription]
        case .tooManyImages:
            return ["code": "tooMany", "error": validation.localizedDescription]
        case .imageTooLarge:
            return ["code": "tooLarge", "error": validation.localizedDescription]
        case .unsupportedImage:
            return ["code": "unsupported", "error": validation.localizedDescription]
        case .malformedRequest:
            return ["code": "failure", "error": validation.localizedDescription]
        }
    }

    enum ServerError: LocalizedError {
        case noLocalAddress
        case listenerFailed

        var errorDescription: String? {
            switch self {
            case .noLocalAddress:
                return "找不到 Mac 的局域网地址，请确认已经连接 Wi-Fi"
            case .listenerFailed:
                return "无法启动局域网上传服务"
            }
        }
    }
}
