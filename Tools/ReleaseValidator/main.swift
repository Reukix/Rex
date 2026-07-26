import Foundation

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ValidationFailure(description: "\(url.lastPathComponent) must contain a JSON object")
    }
    return object
}

func capture(_ pattern: String, in text: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let captureRange = Range(match.range(at: 1), in: text) else {
        throw ValidationFailure(description: "Unable to read AppVersion.releaseVersion")
    }
    return String(text[captureRange])
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw ValidationFailure(description: "Expected package root and output directory")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let appVersionURL = root.appendingPathComponent("Sources/RexApp/Application/AppVersion.swift")
    let featuresURL = root.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/features.json")
    let releasesURL = root.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/releases.json")

    let versionSource = try String(contentsOf: appVersionURL, encoding: .utf8)
    let appVersion = try capture(#"releaseVersion\s*=\s*\"([^\"]+)\""#, in: versionSource)
    let features = try readJSON(featuresURL)
    let releases = try readJSON(releasesURL)

    guard features["lastUpdatedVersion"] as? String == appVersion else {
        throw ValidationFailure(description: "features.json version does not match AppVersion \(appVersion)")
    }
    guard let releaseList = releases["releases"] as? [[String: Any]],
          let latest = releaseList.first,
          latest["version"] as? String == appVersion else {
        throw ValidationFailure(description: "Latest releases.json version does not match AppVersion \(appVersion)")
    }

    var featureIDs = Set<String>()
    let allowedStatuses = Set(["completed", "testing", "inProgress", "planned", "paused", "limited", "removed"])
    guard let categories = features["categories"] as? [[String: Any]] else {
        throw ValidationFailure(description: "features.json categories are missing")
    }
    for category in categories {
        guard let records = category["features"] as? [[String: Any]] else { continue }
        for record in records {
            guard let id = record["id"] as? String, !id.isEmpty else {
                throw ValidationFailure(description: "Every feature requires a non-empty id")
            }
            guard featureIDs.insert(id).inserted else {
                throw ValidationFailure(description: "Duplicate feature id: \(id)")
            }
            guard let status = record["status"] as? String, allowedStatuses.contains(status) else {
                throw ValidationFailure(description: "Feature \(id) has an invalid status")
            }
            guard record["testStatus"] is String else {
                throw ValidationFailure(description: "Feature \(id) requires testStatus")
            }
        }
    }

    let releaseDocument = root.appendingPathComponent("Documentation/Releases/v\(appVersion).md")
    guard FileManager.default.fileExists(atPath: releaseDocument.path) else {
        throw ValidationFailure(description: "Missing release document: \(releaseDocument.lastPathComponent)")
    }
    for required in ["CHANGELOG.md", "FEATURES.md", "ROADMAP.md"] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(required).path) else {
            throw ValidationFailure(description: "Missing required release file: \(required)")
        }
    }

    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "validated \(appVersion)\n".write(
        to: output.appendingPathComponent("release-notes-validation.txt"),
        atomically: true,
        encoding: .utf8
    )
    print("Rex release notes validated for v\(appVersion) (\(featureIDs.count) features)")
} catch {
    FileHandle.standardError.write(Data("Release validation failed: \(error)\n".utf8))
    exit(1)
}
