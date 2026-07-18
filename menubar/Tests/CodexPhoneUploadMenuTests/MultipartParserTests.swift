import Foundation
import CodexPhoneUploadCore

@main
struct MultipartParserSelfTests {
    static func main() throws {
        try parsesMultipleImagesInOrder()
        try rejectsUnsupportedFile()
        print("MultipartParser self-tests passed")
    }

    private static func parsesMultipleImagesInOrder() throws {
        let boundary = "test-boundary"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
        let body = multipartBody(
            boundary: boundary,
            files: [("one.png", png), ("two.jpg", jpeg)]
        )

        let images = try MultipartParser.parse(body: body, boundary: boundary)

        guard images.map(\.filename) == ["one.png", "two.jpg"],
              images.map(\.data) == [png, jpeg] else {
            throw SelfTestFailure("multiple images were not parsed in order")
        }
    }

    private static func rejectsUnsupportedFile() throws {
        let boundary = "test-boundary"
        let body = multipartBody(
            boundary: boundary,
            files: [("notes.txt", Data("not an image".utf8))]
        )

        do {
            _ = try MultipartParser.parse(body: body, boundary: boundary)
            throw SelfTestFailure("unsupported content was accepted")
        } catch UploadValidationError.unsupportedImage {
            return
        }
    }

    private static func multipartBody(boundary: String, files: [(String, Data)]) -> Data {
        var body = Data()
        for (filename, data) in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"images\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

private struct SelfTestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
