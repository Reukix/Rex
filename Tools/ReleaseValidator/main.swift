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

func capture(_ pattern: String, in text: String, field: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let captureRange = Range(match.range(at: 1), in: text) else {
        throw ValidationFailure(description: "Unable to read \(field)")
    }
    return String(text[captureRange])
}

func firstReleaseHeading(in changelog: String) throws -> (version: String, build: Int) {
    let regex = try NSRegularExpression(
        pattern: #"^##\s+v?([^\s]+)\s+\(build\s+([0-9]+)\)"#,
        options: [.anchorsMatchLines]
    )
    let range = NSRange(changelog.startIndex..., in: changelog)
    guard let match = regex.firstMatch(in: changelog, range: range),
          let versionRange = Range(match.range(at: 1), in: changelog),
          let buildRange = Range(match.range(at: 2), in: changelog),
          let build = Int(changelog[buildRange]) else {
        throw ValidationFailure(description: "CHANGELOG.md has no version/build release heading")
    }
    return (String(changelog[versionRange]), build)
}

do {
    guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 5 else {
        throw ValidationFailure(
            description: "Expected package root and output directory, optionally followed by expected version and build"
        )
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let appVersionURL = root.appendingPathComponent("Sources/RexApp/Application/AppVersion.swift")
    let featuresURL = root.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/features.json")
    let releasesURL = root.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/releases.json")
    let changelogURL = root.appendingPathComponent("CHANGELOG.md")

    let versionSource = try String(contentsOf: appVersionURL, encoding: .utf8)
    let appVersion = try capture(
        #"releaseVersion\s*=\s*\"([^\"]+)\""#,
        in: versionSource,
        field: "AppVersion.releaseVersion"
    )
    let buildSource = try capture(
        #"buildNumber\s*=\s*([0-9]+)"#,
        in: versionSource,
        field: "AppVersion.buildNumber"
    )
    guard let appBuild = Int(buildSource) else {
        throw ValidationFailure(description: "AppVersion.buildNumber must be an integer")
    }
    if CommandLine.arguments.count == 5 {
        let expectedVersion = CommandLine.arguments[3]
        guard let expectedBuild = Int(CommandLine.arguments[4]) else {
            throw ValidationFailure(description: "Expected build must be an integer")
        }
        guard appVersion == expectedVersion, appBuild == expectedBuild else {
            throw ValidationFailure(
                description: "Package request \(expectedVersion) build \(expectedBuild) does not match "
                    + "AppVersion \(appVersion) build \(appBuild)"
            )
        }
    }
    let features = try readJSON(featuresURL)
    let releases = try readJSON(releasesURL)
    let changelog = try String(contentsOf: changelogURL, encoding: .utf8)

    guard features["lastUpdatedVersion"] as? String == appVersion else {
        throw ValidationFailure(description: "features.json version does not match AppVersion \(appVersion)")
    }
    guard let releaseList = releases["releases"] as? [[String: Any]],
          let latest = releaseList.first,
          latest["version"] as? String == appVersion,
          (latest["build"] as? NSNumber)?.intValue == appBuild else {
        throw ValidationFailure(
            description: "Latest releases.json identity does not match AppVersion \(appVersion) build \(appBuild)"
        )
    }
    var releaseIdentities = Set<String>()
    for release in releaseList {
        guard let version = release["version"] as? String,
              let build = (release["build"] as? NSNumber)?.intValue else {
            throw ValidationFailure(description: "Every release requires a version and integer build")
        }
        let identity = "\(version)-build-\(build)"
        guard releaseIdentities.insert(identity).inserted else {
            throw ValidationFailure(description: "Duplicate release identity: \(identity)")
        }
    }

    let changelogRelease = try firstReleaseHeading(in: changelog)
    guard changelogRelease.version == appVersion, changelogRelease.build == appBuild else {
        throw ValidationFailure(
            description: "First CHANGELOG.md release is \(changelogRelease.version) build \(changelogRelease.build); "
                + "expected \(appVersion) build \(appBuild)"
        )
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
    try "validated \(appVersion) build \(appBuild)\n".write(
        to: output.appendingPathComponent("release-notes-validation.txt"),
        atomically: true,
        encoding: .utf8
    )
    print("Rex release notes validated for v\(appVersion) build \(appBuild) (\(featureIDs.count) features)")
} catch {
    FileHandle.standardError.write(Data("Release validation failed: \(error)\n".utf8))
    exit(1)
}
