import Foundation

public struct AccessibilityDiagnosticSample: Equatable, Sendable {
    public let elapsedMilliseconds: Int
    public let nodeCount: Int
    public let composerCandidateCount: Int
    public let focusedRole: String
    public let roleCounts: [String: Int]

    public init(
        elapsedMilliseconds: Int,
        nodeCount: Int,
        composerCandidateCount: Int,
        focusedRole: String,
        roleCounts: [String: Int]
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.nodeCount = nodeCount
        self.composerCandidateCount = composerCandidateCount
        self.focusedRole = focusedRole
        self.roleCounts = roleCounts
    }
}

public struct AccessibilityDiagnosticSnapshot: Equatable, Sendable {
    public let elapsedMilliseconds: Int
    public let focusedWindowObserved: Bool
    public let nudgeAttempted: Bool
    public let samples: [AccessibilityDiagnosticSample]

    public init(
        elapsedMilliseconds: Int,
        focusedWindowObserved: Bool,
        nudgeAttempted: Bool,
        samples: [AccessibilityDiagnosticSample]
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.focusedWindowObserved = focusedWindowObserved
        self.nudgeAttempted = nudgeAttempted
        self.samples = samples
    }
}

public struct CompatibilityDiagnostic: Equatable, Sendable {
    public let toolVersion: String
    public let toolBuild: String
    public let macOSVersion: String
    public let codexVersion: String
    public let codexBuild: String
    public let mode: String
    public let accessibilityGranted: Bool
    public let stage: String
    public let errorCode: String
    public let accessibility: AccessibilityDiagnosticSnapshot?

    public init(
        toolVersion: String,
        toolBuild: String,
        macOSVersion: String,
        codexVersion: String,
        codexBuild: String,
        mode: String,
        accessibilityGranted: Bool,
        stage: String,
        errorCode: String,
        accessibility: AccessibilityDiagnosticSnapshot?
    ) {
        self.toolVersion = toolVersion
        self.toolBuild = toolBuild
        self.macOSVersion = macOSVersion
        self.codexVersion = codexVersion
        self.codexBuild = codexBuild
        self.mode = mode
        self.accessibilityGranted = accessibilityGranted
        self.stage = stage
        self.errorCode = errorCode
        self.accessibility = accessibility
    }

    public func rendered() -> String {
        var lines = [
            "Codex Phone Upload diagnostics",
            "Privacy: no conversation text, images, filenames, upload URLs, or tokens are included.",
            "Tool version: \(singleLine(toolVersion)) (\(singleLine(toolBuild)))",
            "macOS: \(singleLine(macOSVersion))",
            "Codex: \(singleLine(codexVersion)) (\(singleLine(codexBuild)))",
            "Mode: \(singleLine(mode))",
            "Accessibility granted: \(accessibilityGranted)",
            "Failure stage: \(singleLine(stage))",
            "Error code: \(singleLine(errorCode))",
        ]

        if let accessibility {
            lines.append("AX elapsed: \(accessibility.elapsedMilliseconds) ms")
            lines.append("Focused window observed: \(accessibility.focusedWindowObserved)")
            lines.append("Composer nudge attempted: \(accessibility.nudgeAttempted)")
            lines.append("AX samples:")
            for sample in accessibility.samples {
                let roles = sample.roleCounts
                    .map { (safeRole($0.key), $0.value) }
                    .sorted {
                        if $0.1 == $1.1 { return $0.0 < $1.0 }
                        return $0.1 > $1.1
                    }
                    .prefix(8)
                    .map { "\($0.0):\($0.1)" }
                    .joined(separator: ",")
                lines.append(
                    "- \(sample.elapsedMilliseconds) ms: nodes=\(sample.nodeCount), "
                        + "composer_candidates=\(sample.composerCandidateCount), "
                        + "focused_role=\(safeRole(sample.focusedRole)), roles=\(roles.isEmpty ? "none" : roles)"
                )
            }
        } else {
            lines.append("AX samples: unavailable")
        }
        return lines.joined(separator: "\n")
    }

    private func singleLine(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(160))
    }

    private func safeRole(_ role: String) -> String {
        guard role.hasPrefix("AX"), role.count <= 40,
              role.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else {
            return role.isEmpty ? "none" : "unknown"
        }
        return role
    }
}
