import CryptoKit
import Foundation

enum SupplyChainArtifactKind: String, CaseIterable, Sendable {
    case chromeExtensionPackage
    case ordinaryDownload
    case securityAssetPackage
    case applicationUpdatePackage
}

enum SupplyChainVerificationAuthority: String, Sendable {
    case chromiumCRXIdentity
    case localTypeRiskAndUserConsent
    case rexSecurityAssetSigningKey
    case rexApplicationUpdateSigningKeyAndAppleDistribution
}

struct SupplyChainBoundaryRecord: Equatable, Sendable {
    let artifact: SupplyChainArtifactKind
    let authority: SupplyChainVerificationAuthority
    let signatureTrustDomain: String?
    let acceptedMeaning: String
    let excludedMeaning: String
}

enum SupplyChainBoundaryAudit {
    static let records: [SupplyChainBoundaryRecord] = [
        SupplyChainBoundaryRecord(
            artifact: .chromeExtensionPackage,
            authority: .chromiumCRXIdentity,
            signatureTrustDomain: "crx2/crx3 embedded publisher identity",
            acceptedMeaning: "CRX signature and derived extension ID match the requested extension",
            excludedMeaning: "It does not approve ordinary files, Rex catalogs, or Rex application updates"
        ),
        SupplyChainBoundaryRecord(
            artifact: .ordinaryDownload,
            authority: .localTypeRiskAndUserConsent,
            signatureTrustDomain: nil,
            acceptedMeaning: "Chromium metadata was mapped and the required local risk prompt was answered",
            excludedMeaning: "It is not malware, reputation, code-signing, or notarization verification"
        ),
        SupplyChainBoundaryRecord(
            artifact: .securityAssetPackage,
            authority: .rexSecurityAssetSigningKey,
            signatureTrustDomain: SecurityAssetManifest.trustDomain,
            acceptedMeaning: "The signed manifest and exact PSL/privacy payload hashes passed policy",
            excludedMeaning: "This key cannot authorize CRX files or application replacement"
        ),
        SupplyChainBoundaryRecord(
            artifact: .applicationUpdatePackage,
            authority: .rexApplicationUpdateSigningKeyAndAppleDistribution,
            signatureTrustDomain: ApplicationUpdateManifest.trustDomain,
            acceptedMeaning: "The update and rollback artifacts match a separately signed update manifest",
            excludedMeaning: "Installation still requires Developer ID, notarization, Gatekeeper, and rollback gates"
        )
    ]
}

struct ApplicationUpdateArtifact: Codable, Equatable, Sendable {
    let filename: String
    let version: String
    let build: Int
    let size: Int64
    let sha256: String
}

struct ApplicationUpdateManifest: Codable, Equatable, Sendable {
    static let trustDomain = "com.rex.browser.application-update"

    let trustDomain: String
    let schemaVersion: Int
    let issuedAt: String
    let expiresAt: String
    let minimumSourceBuild: Int
    let update: ApplicationUpdateArtifact
    let rollback: ApplicationUpdateArtifact
}

struct VerifiedApplicationUpdate: Equatable, Sendable {
    let update: ApplicationUpdateArtifact
    let rollback: ApplicationUpdateArtifact
}

struct ApplicationUpdateVerifier: Sendable {
    static let manifestMaximumBytes = 128 * 1_024
    static let signatureMaximumBytes = 256
    static let artifactMaximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    let publicKey: Data
    let currentBuild: Int

    init(publicKey: Data, currentBuild: Int) throws {
        guard publicKey.count == 32, currentBuild > 0 else {
            throw ApplicationUpdateVerificationError.invalidTrustConfiguration
        }
        self.publicKey = publicKey
        self.currentBuild = currentBuild
    }

    func verify(
        manifestData: Data,
        signatureData: Data,
        updateURL: URL,
        rollbackURL: URL,
        now: Date = Date()
    ) throws -> VerifiedApplicationUpdate {
        guard manifestData.count <= Self.manifestMaximumBytes,
              signatureData.count <= Self.signatureMaximumBytes else {
            throw ApplicationUpdateVerificationError.manifestTooLarge
        }
        let signatureText = String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: manifestData) else {
            throw ApplicationUpdateVerificationError.invalidSignature
        }
        try validateJSONShape(manifestData)
        let manifest: ApplicationUpdateManifest
        do {
            manifest = try JSONDecoder().decode(ApplicationUpdateManifest.self, from: manifestData)
        } catch {
            throw ApplicationUpdateVerificationError.invalidManifest
        }
        guard manifest.trustDomain == ApplicationUpdateManifest.trustDomain,
              manifest.schemaVersion == 1,
              manifest.minimumSourceBuild <= currentBuild,
              manifest.update.build > currentBuild,
              manifest.rollback.build == currentBuild,
              manifest.update.build > manifest.rollback.build,
              let issuedAt = SecurityAssetManager.parseTimestamp(manifest.issuedAt),
              let expiresAt = SecurityAssetManager.parseTimestamp(manifest.expiresAt),
              issuedAt <= now.addingTimeInterval(5 * 60),
              expiresAt > now,
              expiresAt > issuedAt else {
            throw ApplicationUpdateVerificationError.invalidManifest
        }
        try validate(manifest.update, at: updateURL)
        try validate(manifest.rollback, at: rollbackURL)
        return VerifiedApplicationUpdate(update: manifest.update, rollback: manifest.rollback)
    }

    private func validate(_ artifact: ApplicationUpdateArtifact, at url: URL) throws {
        guard artifact.filename == url.lastPathComponent,
              !artifact.filename.isEmpty,
              artifact.filename.hasSuffix(".zip"),
              !artifact.filename.contains("/"),
              artifact.version.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.]+)?$",
                options: .regularExpression
              ) != nil,
              artifact.build > 0,
              (1...Self.artifactMaximumBytes).contains(artifact.size),
              artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ApplicationUpdateVerificationError.invalidManifest
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == artifact.size else {
            throw ApplicationUpdateVerificationError.unsafeArtifact
        }
        guard try Self.sha256Hex(of: url) == artifact.sha256 else {
            throw ApplicationUpdateVerificationError.digestMismatch
        }
    }

    private func validateJSONShape(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                "trustDomain", "schemaVersion", "issuedAt", "expiresAt",
                "minimumSourceBuild", "update", "rollback"
              ]),
              let update = object["update"] as? [String: Any],
              let rollback = object["rollback"] as? [String: Any] else {
            throw ApplicationUpdateVerificationError.invalidManifest
        }
        let artifactKeys = Set(["filename", "version", "build", "size", "sha256"])
        guard Set(update.keys) == artifactKeys, Set(rollback.keys) == artifactKeys else {
            throw ApplicationUpdateVerificationError.invalidManifest
        }
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
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
}

enum ApplicationUpdateVerificationError: Error, Equatable {
    case invalidTrustConfiguration
    case manifestTooLarge
    case invalidSignature
    case invalidManifest
    case unsafeArtifact
    case digestMismatch
}
