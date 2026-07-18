import Foundation

public struct UploadedImage: Equatable {
    public let filename: String
    public let data: Data

    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}

public enum UploadValidationError: LocalizedError, Equatable {
    case malformedRequest
    case noImages
    case tooManyImages
    case imageTooLarge
    case unsupportedImage

    public var errorDescription: String? {
        switch self {
        case .malformedRequest:
            return "上传请求格式不正确"
        case .noImages:
            return "请选择至少一张图片"
        case .tooManyImages:
            return "一次最多上传 12 张图片"
        case .imageTooLarge:
            return "单张图片不能超过 25 MB"
        case .unsupportedImage:
            return "只支持 PNG、JPEG、GIF、WebP、HEIC 和 HEIF 图片"
        }
    }
}

public enum MultipartParser {
    public static let maxFiles = 12
    public static let maxFileBytes = 25 * 1024 * 1024
    public static let maxRequestBytes = 100 * 1024 * 1024

    public static func parse(body: Data, boundary: String) throws -> [UploadedImage] {
        guard !boundary.isEmpty else {
            throw UploadValidationError.malformedRequest
        }
        let separator = Data("--\(boundary)".utf8)
        let headerSeparator = Data("\r\n\r\n".utf8)
        let parts = body.split(separator: separator)
        var images: [UploadedImage] = []

        for rawPart in parts {
            var part = rawPart
            part.trimPrefix(Data("\r\n".utf8))
            if part.starts(with: Data("--".utf8)) || part.isEmpty {
                continue
            }
            part.trimSuffix(Data("\r\n".utf8))
            guard let headerRange = part.range(of: headerSeparator) else {
                continue
            }
            let headerData = part[..<headerRange.lowerBound]
            guard let headers = String(data: headerData, encoding: .utf8),
                  headers.lowercased().contains("name=\"images\"") else {
                continue
            }
            let filename = extractFilename(from: headers) ?? "image"
            var fileData = Data(part[headerRange.upperBound...])
            fileData.trimSuffix(Data("\r\n".utf8))

            guard !fileData.isEmpty else {
                throw UploadValidationError.noImages
            }
            guard fileData.count <= maxFileBytes else {
                throw UploadValidationError.imageTooLarge
            }
            guard isSupportedImage(fileData) else {
                throw UploadValidationError.unsupportedImage
            }
            images.append(UploadedImage(filename: filename, data: fileData))
            guard images.count <= maxFiles else {
                throw UploadValidationError.tooManyImages
            }
        }

        guard !images.isEmpty else {
            throw UploadValidationError.noImages
        }
        return images
    }

    private static func extractFilename(from headers: String) -> String? {
        let pattern = #"filename="([^"]*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: headers,
                range: NSRange(headers.startIndex..., in: headers)
              ),
              let range = Range(match.range(at: 1), in: headers) else {
            return nil
        }
        return URL(fileURLWithPath: String(headers[range])).lastPathComponent
    }

    private static func isSupportedImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return true
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return true
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return true
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return true
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand)
        }
        return false
    }
}

private extension Data {
    func split(separator: Data) -> [Data] {
        guard !separator.isEmpty else { return [self] }
        var result: [Data] = []
        var cursor = startIndex
        while let range = range(of: separator, in: cursor..<endIndex) {
            result.append(Data(self[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        result.append(Data(self[cursor..<endIndex]))
        return result
    }

    mutating func trimPrefix(_ prefix: Data) {
        if starts(with: prefix) {
            removeFirst(prefix.count)
        }
    }

    mutating func trimSuffix(_ suffix: Data) {
        if count >= suffix.count && self.suffix(suffix.count).elementsEqual(suffix) {
            removeLast(suffix.count)
        }
    }
}
