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
    let readmeURL = root.appendingPathComponent("README.md")
    let englishReadmeURL = root.appendingPathComponent("README_EN.md")
    let licenseURL = root.appendingPathComponent("LICENSE")

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
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)
    let englishReadme = try String(contentsOf: englishReadmeURL, encoding: .utf8)
    let license = try String(contentsOf: licenseURL, encoding: .utf8)

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

    let releaseIdentity = "v\(appVersion) build \(appBuild)"
    guard readme.contains(releaseIdentity), englishReadme.contains(releaseIdentity) else {
        throw ValidationFailure(description: "Both README files must identify \(releaseIdentity)")
    }
    guard readme.contains("[English](README_EN.md)"),
          englishReadme.contains("[简体中文](README.md)") else {
        throw ValidationFailure(description: "README language links are missing")
    }
    guard license.contains("GNU AFFERO GENERAL PUBLIC LICENSE"),
          license.contains("Version 3, 19 November 2007") else {
        throw ValidationFailure(description: "LICENSE must contain GNU Affero General Public License v3.0")
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

    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "validated \(appVersion) build \(appBuild)\n".write(
        to: output.appendingPathComponent("release-notes-validation.txt"),
        atomically: true,
        encoding: .utf8
    )
    print("Rex public release metadata validated for v\(appVersion) build \(appBuild) (\(featureIDs.count) features)")
} catch {
    FileHandle.standardError.write(Data("Release validation failed: \(error)\n".utf8))
    exit(1)
}
