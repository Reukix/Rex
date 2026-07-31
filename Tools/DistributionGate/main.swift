import CryptoKit
import Foundation

private struct Artifact: Decodable {
    let filename: String
    let version: String
    let build: Int
    let size: Int64
    let sha256: String
}

private struct Manifest: Decodable {
    let trustDomain: String
    let schemaVersion: Int
    let issuedAt: String
    let expiresAt: String
    let minimumSourceBuild: Int
    let update: Artifact
    let rollback: Artifact
}

private enum GateError: Error, CustomStringConvertible {
    case usage
    case invalid(String)

    var description: String {
        switch self {
        case .usage:
            "usage: RexDistributionGate <manifest.json> <manifest.sig> <update.zip> <rollback.zip> <current-build> <staged-build> <ed25519-public-key-base64>"
        case let .invalid(message):
            message
        }
    }
}

private func timestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
        if data.isEmpty { break }
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func validate(_ artifact: Artifact, url: URL, expectedBuild: Int?) throws {
    let values = try url.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey
    ])
    guard artifact.filename == url.lastPathComponent,
          artifact.filename.hasSuffix(".zip"),
          !artifact.filename.contains("/"),
          artifact.version.range(
            of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.]+)?$",
            options: .regularExpression
          ) != nil,
          artifact.size > 0,
          artifact.size <= 2 * 1_024 * 1_024 * 1_024,
          artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          Int64(values.fileSize ?? -1) == artifact.size,
          expectedBuild.map({ artifact.build == $0 }) ?? true,
          try sha256Hex(of: url) == artifact.sha256 else {
        throw GateError.invalid("Update artifact verification failed: \(url.path)")
    }
}

private func validateManifestShape(_ data: Data) throws {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == Set([
            "trustDomain", "schemaVersion", "issuedAt", "expiresAt",
            "minimumSourceBuild", "update", "rollback"
          ]),
          let update = object["update"] as? [String: Any],
          let rollback = object["rollback"] as? [String: Any] else {
        throw GateError.invalid("Application update manifest shape is invalid.")
    }
    let artifactKeys = Set(["filename", "version", "build", "size", "sha256"])
    guard Set(update.keys) == artifactKeys, Set(rollback.keys) == artifactKeys else {
        throw GateError.invalid("Application update artifact shape is invalid.")
    }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 7,
          let currentBuild = Int(arguments[4]),
          let stagedBuild = Int(arguments[5]),
          currentBuild > 0,
          stagedBuild > currentBuild,
          let publicKeyData = Data(base64Encoded: arguments[6]),
          publicKeyData.count == 32 else {
        throw GateError.usage
    }
    let manifestURL = URL(fileURLWithPath: arguments[0])
    let signatureURL = URL(fileURLWithPath: arguments[1])
    let updateURL = URL(fileURLWithPath: arguments[2])
    let rollbackURL = URL(fileURLWithPath: arguments[3])
    let manifestData = try Data(contentsOf: manifestURL)
    let signatureText = try String(contentsOf: signatureURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard manifestData.count <= 128 * 1_024,
          (try? signatureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 256 }) == true,
          let signature = Data(base64Encoded: signatureText),
          signature.count == 64,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
          publicKey.isValidSignature(signature, for: manifestData) else {
        throw GateError.invalid("Application update manifest signature is invalid.")
    }
    try validateManifestShape(manifestData)
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    let now = Date()
    guard manifest.trustDomain == "com.rex.browser.application-update",
          manifest.schemaVersion == 1,
          manifest.minimumSourceBuild <= currentBuild,
          manifest.update.build == stagedBuild,
          manifest.rollback.build == currentBuild,
          manifest.update.build > manifest.rollback.build,
          let issuedAt = timestamp(manifest.issuedAt),
          let expiresAt = timestamp(manifest.expiresAt),
          issuedAt <= now.addingTimeInterval(5 * 60),
          expiresAt > now,
          expiresAt > issuedAt else {
        throw GateError.invalid("Application update manifest policy is invalid or expired.")
    }
    try validate(manifest.update, url: updateURL, expectedBuild: nil)
    try validate(manifest.rollback, url: rollbackURL, expectedBuild: currentBuild)
    print(
        "Application update manifest verified: build \(currentBuild) -> \(stagedBuild); rollback build \(manifest.rollback.build)"
    )
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(error is GateError ? 2 : 1)
}
