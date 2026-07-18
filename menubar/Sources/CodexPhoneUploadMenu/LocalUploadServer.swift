import Darwin
import Foundation
import Network
import CodexPhoneUploadCore

final class LocalUploadServer: @unchecked Sendable {
    struct ReadySession {
        let url: URL
        let expiresAt: Date
    }

    typealias UploadHandler = ([UploadedImage], @escaping (Result<Int, Error>) -> Void) -> Void

    private let queue = DispatchQueue(label: "local.dingaimin.CodexPhoneUploadMenu.server")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let ttl: TimeInterval
    private let onReady: (ReadySession) -> Void
    private let onState: (String) -> Void
    private let onUpload: UploadHandler
    private var listener: NWListener?
    private var expiryWorkItem: DispatchWorkItem?
    private var completed = false
    private var handlingUpload = false
    private var expiresAt = Date()

    init(
        ttl: TimeInterval = 10 * 60,
        onReady: @escaping (ReadySession) -> Void,
        onState: @escaping (String) -> Void,
        onUpload: @escaping UploadHandler
    ) {
        self.ttl = ttl
        self.onReady = onReady
        self.onState = onState
        self.onUpload = onUpload
    }

    func start() throws {
        guard let address = Self.localIPv4Address() else {
            throw ServerError.noLocalAddress
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
                    self.onState(ServerError.listenerFailed.localizedDescription)
                    return
                }
                self.expiresAt = Date().addingTimeInterval(self.ttl)
                let path = "/upload/\(self.token)"
                guard let url = URL(string: "http://\(address):\(port.rawValue)\(path)") else {
                    self.onState(ServerError.listenerFailed.localizedDescription)
                    return
                }
                self.onReady(ReadySession(url: url, expiresAt: self.expiresAt))
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, !self.completed else { return }
                    self.onState("二维码已过期，请生成新的二维码")
                    self.stop()
                }
                self.expiryWorkItem = workItem
                self.queue.asyncAfter(deadline: .now() + self.ttl, execute: workItem)
            case .failed(let error):
                self.onState("上传服务启动失败：\(error.localizedDescription)")
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
        listener?.cancel()
        listener = nil
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
                self.sendJSON(connection, status: 413, payload: ["error": "上传内容过大"])
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
        guard path == expectedPath, Date() < expiresAt, !completed else {
            send(connection, status: 410, contentType: "text/plain; charset=utf-8", body: Data("上传链接已失效".utf8))
            return
        }
        if method == "GET" {
            let body = Data(Self.uploadPage(expiresAt: expiresAt).utf8)
            send(
                connection,
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: body,
                extraHeaders: [
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
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
            sendJSON(connection, status: 409, payload: ["error": "正在处理上一批图片"])
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
            onState("正在把 \(images.count) 张图片放入 Codex…")
            onUpload(images) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.handlingUpload = false
                    switch result {
                    case .success(let count):
                        self.completed = true
                        self.sendJSON(connection, status: 200, payload: ["count": count])
                        self.onState("已放入 Codex 输入框：\(count) 张")
                        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                            self?.stop()
                        }
                    case .failure(let error):
                        self.sendJSON(connection, status: 500, payload: ["error": error.localizedDescription])
                        self.onState(error.localizedDescription)
                    }
                }
            }
        } catch {
            sendJSON(connection, status: 400, payload: ["error": error.localizedDescription])
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

    private static func uploadPage(expiresAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let expires = formatter.string(from: expiresAt)
        return """
        <!doctype html><html lang="zh-CN"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>上传图片到 Codex 输入框</title>
        <style>
        :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#18212f;background:#f4f7fb}
        body{margin:0}main{max-width:560px;margin:auto;padding:32px 18px}.card{background:#fff;border-radius:20px;padding:24px;box-shadow:0 10px 35px #1a28461a}
        h1{margin:0 0 8px;font-size:25px}p,small{color:#5d6878;line-height:1.6}input{display:block;width:100%;box-sizing:border-box;margin:20px 0;padding:18px;border:2px dashed #8eb1ef;border-radius:14px;background:#f8fbff}
        button{width:100%;border:0;border-radius:14px;padding:15px;color:#fff;background:#1769e0;font-size:17px;font-weight:650}button:disabled{opacity:.55}#status{min-height:48px;margin-top:16px;color:#1769e0;line-height:1.5}
        </style></head><body><main><div class="card"><h1>上传图片</h1>
        <p>选择手机中的图片，上传后会放进 Mac 当前打开的 Codex 输入框，不会自动发送。</p>
        <form id="form" method="post" enctype="multipart/form-data"><input name="images" type="file" accept="image/*,.heic,.heif" multiple required><button id="submit">上传到 Codex</button></form>
        <div id="status"></div><small>一次最多 12 张，每张不超过 25 MB。一次性链接将在 \(expires) 失效。</small>
        </div></main><script>
        const f=document.getElementById('form'),b=document.getElementById('submit'),s=document.getElementById('status');
        f.addEventListener('submit',async e=>{e.preventDefault();b.disabled=true;s.textContent='正在上传并放入 Codex…';try{const r=await fetch(location.pathname,{method:'POST',body:new FormData(f)});const j=await r.json();if(!r.ok)throw new Error(j.error||'上传失败');s.textContent=`上传成功：${j.count} 张图片已放入 Codex 输入框。`;f.style.display='none'}catch(e){s.textContent=e.message||'上传失败，请重试';b.disabled=false}});
        </script></body></html>
        """
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
