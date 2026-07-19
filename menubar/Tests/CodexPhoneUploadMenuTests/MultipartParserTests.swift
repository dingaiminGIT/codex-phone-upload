import Foundation
import CodexPhoneUploadCore

@main
struct MultipartParserSelfTests {
    static func main() throws {
        try parsesMultipleImagesInOrder()
        try acceptsEverySupportedImageSignature()
        try stripsPathsFromFilenames()
        try rejectsUnsupportedFile()
        try rejectsEmptyBoundary()
        try rejectsMissingImages()
        try rejectsTooManyImages()
        try rejectsOversizedImage()
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

    private static func acceptsEverySupportedImageSignature() throws {
        let boundary = "supported-images"
        let files: [(String, Data)] = [
            ("image.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ("image.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0])),
            ("image.gif", Data("GIF89a".utf8)),
            ("image.webp", Data("RIFF0000WEBP".utf8)),
            ("image.heic", Data([0, 0, 0, 0]) + Data("ftypheic".utf8)),
            ("image.heif", Data([0, 0, 0, 0]) + Data("ftypmif1".utf8)),
        ]

        let images = try MultipartParser.parse(
            body: multipartBody(boundary: boundary, files: files),
            boundary: boundary
        )
        guard images.map(\.filename) == files.map(\.0) else {
            throw SelfTestFailure("a supported image signature was rejected")
        }
    }

    private static func stripsPathsFromFilenames() throws {
        let boundary = "safe-filename"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let images = try MultipartParser.parse(
            body: multipartBody(boundary: boundary, files: [("../../private/image.png", png)]),
            boundary: boundary
        )
        guard images.first?.filename == "image.png" else {
            throw SelfTestFailure("uploaded filename paths were not stripped")
        }
    }

    private static func rejectsEmptyBoundary() throws {
        try expect(.malformedRequest, message: "an empty boundary was accepted") {
            _ = try MultipartParser.parse(body: Data(), boundary: "")
        }
    }

    private static func rejectsMissingImages() throws {
        try expect(.noImages, message: "a request without images was accepted") {
            _ = try MultipartParser.parse(body: Data("not multipart".utf8), boundary: "boundary")
        }
    }

    private static func rejectsTooManyImages() throws {
        let boundary = "too-many"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let files = (1...(MultipartParser.maxFiles + 1)).map { ("\($0).png", png) }
        try expect(.tooManyImages, message: "more than 12 images were accepted") {
            _ = try MultipartParser.parse(
                body: multipartBody(boundary: boundary, files: files),
                boundary: boundary
            )
        }
    }

    private static func rejectsOversizedImage() throws {
        let boundary = "too-large"
        var oversized = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        oversized.append(Data(count: MultipartParser.maxFileBytes + 1 - oversized.count))
        try expect(.imageTooLarge, message: "an image larger than 25 MB was accepted") {
            _ = try MultipartParser.parse(
                body: multipartBody(boundary: boundary, files: [("large.png", oversized)]),
                boundary: boundary
            )
        }
    }

    private static func expect(
        _ expected: UploadValidationError,
        message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw SelfTestFailure(message)
        } catch let error as UploadValidationError where error == expected {
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
