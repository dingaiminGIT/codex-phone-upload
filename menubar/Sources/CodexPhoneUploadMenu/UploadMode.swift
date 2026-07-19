import Foundation

enum UploadMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case remote

    var id: String { rawValue }
}
