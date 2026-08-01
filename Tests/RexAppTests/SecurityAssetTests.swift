import CryptoKit
import Foundation
import Testing
@testable import RexApp

private struct SecurityAssetFixture {
    let root: URL
    let bundledPSL: URL
    let bundledCatalog: URL
    let packages: URL
    let signingKey: Curve25519.Signing.PrivateKey
    let endpoint: URL

    @MainActor
    func manager() throws -> SecurityAssetManager {
        SecurityAssetManager(
            rootURL: root.appending(path: "installed", directoryHint: .isDirectory),
            bundledPublicSuffixListURL: bundledPSL,
            bundledPrivacyCatalogURL: bundledCatalog,
            appBuild: 981,
            configuration: try SecurityAssetUpdateConfiguration(
                endpoint: endpoint,
                publicKey: signingKey.publicKey.rawRepresentation
            ),
            minimumPublicSuffixRuleCount: 1
        )
    }
}

private struct FixtureSecurityAssetFetcher: SecurityAssetFetching {
    let payloads: [URL: Data]

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard let data = payloads[url], data.count <= maximumBytes else {
            throw SecurityAssetError.invalidNetworkResponse
        }
        return data
    }
}

private func securityAssetTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func testPublicSuffixData(version: String = "test-psl") -> Data {
    Data("// VERSION: \(version)\ncom\nco.uk\n*.ck\n!www.ck\n".utf8)
}

private func testPrivacyCatalogData(version: String = "test-catalog") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "catalogVersion": version,
        "advertising": ["ads.example"],
        "tracking": ["tracker.example/pixel"],
        "fingerprinting": ["fingerprint.example"],
        "social": ["social.example/widget"]
    ], options: [.prettyPrinted, .sortedKeys])
}

private func makeSecurityAssetFixture() throws -> SecurityAssetFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rex-security-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
    let baseline = root.appending(path: "baseline", directoryHint: .isDirectory)
    let packages = root.appending(path: "fixtures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    let bundledPSL = baseline.appending(path: SecurityAssetKind.publicSuffixList.filename)
    let bundledCatalog = baseline.appending(path: SecurityAssetKind.privacyCatalog.filename)
    try testPublicSuffixData(version: "bundled").write(to: bundledPSL)
    try testPrivacyCatalogData(version: "bundled").write(to: bundledCatalog)
    return SecurityAssetFixture(
        root: root,
        bundledPSL: bundledPSL,
        bundledCatalog: bundledCatalog,
        packages: packages,
        signingKey: Curve25519.Signing.PrivateKey(),
        endpoint: try #require(URL(string: "https://updates.rex.test/security-assets"))
    )
}

@discardableResult
private func writeSecurityAssetPackage(
    fixture: SecurityAssetFixture,
    sequence: Int,
    now: Date,
    controls: SecurityAssetControls? = nil,
    expiresAt: Date? = nil,
    minimumBuild: Int = 981,
    signingKey: Curve25519.Signing.PrivateKey? = nil,
    privacyData: Data? = nil,
    publicSuffixData: Data? = nil,
    declaredPrivacySize: Int? = nil
) throws -> URL {
    let directory = fixture.packages.appending(
        path: "package-\(sequence)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let privacy = try privacyData ?? testPrivacyCatalogData(version: "catalog-\(sequence)")
    let publicSuffix = publicSuffixData ?? testPublicSuffixData(version: "psl-\(sequence)")
    let manifest = SecurityAssetManifest(
        trustDomain: SecurityAssetManifest.trustDomain,
        schemaVersion: 1,
        sequence: sequence,
        issuedAt: securityAssetTimestamp(now.addingTimeInterval(-60)),
        expiresAt: securityAssetTimestamp(expiresAt ?? now.addingTimeInterval(86_400)),
        minimumBuild: minimumBuild,
        assets: [
            SecurityAssetDescriptor(
                kind: .privacyCatalog,
                filename: SecurityAssetKind.privacyCatalog.filename,
                version: "catalog-\(sequence)",
                size: declaredPrivacySize ?? privacy.count,
                sha256: SecurityAssetManager.sha256Hex(privacy)
            ),
            SecurityAssetDescriptor(
                kind: .publicSuffixList,
                filename: SecurityAssetKind.publicSuffixList.filename,
                version: "psl-\(sequence)",
                size: publicSuffix.count,
                sha256: SecurityAssetManager.sha256Hex(publicSuffix)
            )
        ],
        controls: controls
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    let signature = try (signingKey ?? fixture.signingKey).signature(for: manifestData)
    try manifestData.write(to: directory.appending(path: "manifest.json"))
    try Data(signature.base64EncodedString().utf8).write(
        to: directory.appending(path: "manifest.sig")
    )
    try privacy.write(to: directory.appending(path: SecurityAssetKind.privacyCatalog.filename))
    try publicSuffix.write(to: directory.appending(path: SecurityAssetKind.publicSuffixList.filename))
    return directory
}

@Test("Signed security assets activate on the next launch and become last-known-good")
@MainActor
func signedSecurityAssetsActivateAndBecomeKnownGood() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(try manager.prepareForLaunch(now: now).source == .bundled)
    let package = try writeSecurityAssetPackage(fixture: fixture, sequence: 10, now: now)
    #expect(try manager.installPackage(from: package, now: now) == 10)
    #expect(try manager.stateSnapshot().candidateSequence == 10)

    let candidate = try manager.prepareForLaunch(now: now)
    #expect(candidate.source == .signedPackage(sequence: 10))
    #expect(try manager.stateSnapshot().validationPendingSequence == 10)
    try manager.markLaunchHealthy()
    #expect(try manager.stateSnapshot().knownGoodSequences == [10])
    #expect(try manager.prepareForLaunch(now: now).source == .signedPackage(sequence: 10))
}

@Test("An unvalidated security asset candidate rolls back to last-known-good")
@MainActor
func failedSecurityAssetLaunchRollsBack() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try manager.installPackage(
        from: writeSecurityAssetPackage(fixture: fixture, sequence: 10, now: now),
        now: now
    )
    _ = try manager.prepareForLaunch(now: now)
    try manager.markLaunchHealthy()
    try manager.installPackage(
        from: writeSecurityAssetPackage(fixture: fixture, sequence: 11, now: now),
        now: now
    )
    #expect(try manager.prepareForLaunch(now: now).source == .signedPackage(sequence: 11))

    let recovered = try manager.prepareForLaunch(now: now)
    #expect(recovered.source == .signedPackage(sequence: 10))
    let state = try manager.stateSnapshot()
    #expect(state.activeSequence == 10)
    #expect(state.failedValidationSequences == [11])
    #expect(state.knownGoodSequences == [10])
}

@Test("Security asset packages reject wrong signatures and corrupted payloads atomically")
@MainActor
func securityAssetVerificationRejectsTampering() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let wrongSignature = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 1,
        now: now,
        signingKey: Curve25519.Signing.PrivateKey()
    )
    #expect(throws: SecurityAssetError.invalidSignature) {
        try manager.installPackage(from: wrongSignature, now: now)
    }

    let corrupted = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 2,
        now: now
    )
    try Data("tampered".utf8).write(
        to: corrupted.appending(path: SecurityAssetKind.privacyCatalog.filename)
    )
    #expect(throws: SecurityAssetError.assetDigestMismatch(.privacyCatalog)) {
        try manager.installPackage(from: corrupted, now: now)
    }
    #expect(try manager.stateSnapshot().highestAcceptedSequence == 0)
}

@Test("Security asset policy rejects expiration, oversize declarations, and downgrades")
@MainActor
func securityAssetPolicyRejectsInvalidVersions() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let expired = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 1,
        now: now,
        expiresAt: now.addingTimeInterval(-1)
    )
    #expect(throws: SecurityAssetError.expiredManifest) {
        try manager.installPackage(from: expired, now: now)
    }
    let oversized = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 2,
        now: now,
        declaredPrivacySize: SecurityAssetKind.privacyCatalog.maximumBytes + 1
    )
    #expect(throws: SecurityAssetError.invalidManifest) {
        try manager.installPackage(from: oversized, now: now)
    }

    try manager.installPackage(
        from: writeSecurityAssetPackage(fixture: fixture, sequence: 5, now: now),
        now: now
    )
    let downgrade = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 4,
        now: now
    )
    #expect(throws: SecurityAssetError.downgradeRejected(highest: 5, received: 4)) {
        try manager.installPackage(from: downgrade, now: now)
    }
}

@Test("A package rename completed before a state write can be adopted atomically")
@MainActor
func securityAssetInstallerAdoptsOrphanedAtomicPackage() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try manager.prepareForLaunch(now: now)
    let source = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 7,
        now: now
    )
    let orphan = fixture.root
        .appending(path: "installed/packages/7", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: orphan)

    #expect(try manager.installPackage(from: source, now: now) == 7)
    #expect(try manager.stateSnapshot().candidateSequence == 7)
}

@Test("A signed security asset kill switch forces the audited bundled baseline")
@MainActor
func securityAssetKillSwitchForcesBundledBaseline() throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try manager.installPackage(
        from: writeSecurityAssetPackage(fixture: fixture, sequence: 10, now: now),
        now: now
    )
    _ = try manager.prepareForLaunch(now: now)
    try manager.markLaunchHealthy()
    let killSwitch = SecurityAssetControls(
        forceBundledAssets: true,
        revokedSequences: [10],
        suspendRemoteUpdatesUntil: securityAssetTimestamp(now.addingTimeInterval(3_600))
    )
    try manager.installPackage(
        from: writeSecurityAssetPackage(
            fixture: fixture,
            sequence: 11,
            now: now,
            controls: killSwitch
        ),
        now: now
    )
    #expect(try manager.prepareForLaunch(now: now).source == .bundled)
    #expect(try manager.stateSnapshot().knownGoodSequences.isEmpty)
}

@Test("Online security asset fetch uses the same signed package installer")
@MainActor
func onlineSecurityAssetFetchUsesVerifiedInstaller() async throws {
    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let package = try writeSecurityAssetPackage(fixture: fixture, sequence: 20, now: now)
    let policy = try SecurityAssetNetworkPolicy(baseURL: fixture.endpoint)
    var payloads: [URL: Data] = [:]
    for filename in [
        "manifest.json", "manifest.sig",
        SecurityAssetKind.privacyCatalog.filename,
        SecurityAssetKind.publicSuffixList.filename
    ] {
        payloads[try policy.url(for: filename, relativeTo: fixture.endpoint)] = try Data(
            contentsOf: package.appending(path: filename)
        )
    }

    let result = try await manager.checkForUpdates(
        now: now,
        fetcher: FixtureSecurityAssetFetcher(payloads: payloads)
    )
    #expect(result == .installed(sequence: 20))
    #expect(try manager.stateSnapshot().candidateSequence == 20)
}

@Test("Security asset endpoints reject cross-origin and nested-path downloads")
func securityAssetNetworkPolicyPinsOneHTTPSDirectory() throws {
    let endpoint = try #require(URL(string: "https://updates.rex.test/security-assets"))
    let policy = try SecurityAssetNetworkPolicy(baseURL: endpoint)
    #expect(policy.permits(URL(string: "https://updates.rex.test/security-assets/manifest.json")))
    #expect(!policy.permits(URL(string: "http://updates.rex.test/security-assets/manifest.json")))
    #expect(!policy.permits(URL(string: "https://cdn.rex.test/security-assets/manifest.json")))
    #expect(!policy.permits(URL(string: "https://updates.rex.test/security-assets/nested/manifest.json")))
    #expect(!policy.permits(URL(string: "https://updates.rex.test/security-assets/manifest.json?next=1")))
}

@Test("PSL and privacy catalog parsers reject structurally incomplete updates")
@MainActor
func securityAssetParsersRejectIncompleteUpdates() throws {
    #expect(throws: PublicSuffixListError.missingVersion) {
        try PublicSuffixList.parseValidated("com\n", minimumRuleCount: 1)
    }

    let fixture = try makeSecurityAssetFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manager = try fixture.manager()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let invalidCatalog = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "catalogVersion": "invalid",
        "advertising": [],
        "tracking": ["tracker.example"],
        "fingerprinting": ["fingerprint.example"],
        "social": ["social.example"]
    ])
    let package = try writeSecurityAssetPackage(
        fixture: fixture,
        sequence: 1,
        now: now,
        privacyData: invalidCatalog
    )
    #expect(throws: SecurityAssetError.invalidPrivacyCatalog) {
        try manager.installPackage(from: package, now: now)
    }
}

@Test("The four supply-chain classes keep independent verification authorities")
func fourSupplyChainBoundariesAreExplicitAndIsolated() {
    let records = SupplyChainBoundaryAudit.records
    #expect(records.count == 4)
    #expect(Set(records.map(\.artifact)) == Set(SupplyChainArtifactKind.allCases))
    #expect(Set(records.map(\.authority)).count == 4)
    #expect(records.first(where: { $0.artifact == .ordinaryDownload })?.signatureTrustDomain == nil)
    #expect(
        records.first(where: { $0.artifact == .securityAssetPackage })?.signatureTrustDomain
            != records.first(where: { $0.artifact == .applicationUpdatePackage })?.signatureTrustDomain
    )
}

@Test("Application updates require a distinct signature, forward build, and exact rollback artifact")
func applicationUpdateVerifierEnforcesUpdateAndRollback() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rex-app-update-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let updateURL = root.appending(path: "Rex-v0.9.9-build990.zip")
    let rollbackURL = root.appending(path: "Rex-v0.9.8-build981.zip")
    try Data("new signed app package".utf8).write(to: updateURL)
    try Data("known-good rollback package".utf8).write(to: rollbackURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let signingKey = Curve25519.Signing.PrivateKey()
    let manifest = ApplicationUpdateManifest(
        trustDomain: ApplicationUpdateManifest.trustDomain,
        schemaVersion: 1,
        issuedAt: securityAssetTimestamp(now.addingTimeInterval(-60)),
        expiresAt: securityAssetTimestamp(now.addingTimeInterval(86_400)),
        minimumSourceBuild: 970,
        update: ApplicationUpdateArtifact(
            filename: updateURL.lastPathComponent,
            version: "0.9.9",
            build: 990,
            size: Int64(try #require(updateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
            sha256: try ApplicationUpdateVerifier.sha256Hex(of: updateURL)
        ),
        rollback: ApplicationUpdateArtifact(
            filename: rollbackURL.lastPathComponent,
            version: "0.9.8",
            build: 981,
            size: Int64(try #require(rollbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)),
            sha256: try ApplicationUpdateVerifier.sha256Hex(of: rollbackURL)
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    let signature = try signingKey.signature(for: manifestData)
    let verifier = try ApplicationUpdateVerifier(
        publicKey: signingKey.publicKey.rawRepresentation,
        currentBuild: 981
    )
    let verified = try verifier.verify(
        manifestData: manifestData,
        signatureData: Data(signature.base64EncodedString().utf8),
        updateURL: updateURL,
        rollbackURL: rollbackURL,
        now: now
    )
    #expect(verified.update.build == 990)
    #expect(verified.rollback.build == 981)

    let securityAssetKey = Curve25519.Signing.PrivateKey()
    let wrongSignature = try securityAssetKey.signature(for: manifestData)
    #expect(throws: ApplicationUpdateVerificationError.invalidSignature) {
        try verifier.verify(
            manifestData: manifestData,
            signatureData: Data(wrongSignature.base64EncodedString().utf8),
            updateURL: updateURL,
            rollbackURL: rollbackURL,
            now: now
        )
    }
}

@Test("A security-asset trust-domain manifest cannot authorize an application update")
func applicationUpdateVerifierRejectsCrossPurposeManifest() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rex-cross-purpose-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let updateURL = root.appending(path: "update.zip")
    let rollbackURL = root.appending(path: "rollback.zip")
    try Data("update".utf8).write(to: updateURL)
    try Data("rollback".utf8).write(to: rollbackURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = Curve25519.Signing.PrivateKey()
    let object: [String: Any] = [
        "trustDomain": SecurityAssetManifest.trustDomain,
        "schemaVersion": 1,
        "issuedAt": securityAssetTimestamp(now.addingTimeInterval(-60)),
        "expiresAt": securityAssetTimestamp(now.addingTimeInterval(3_600)),
        "minimumSourceBuild": 981,
        "update": [
            "filename": updateURL.lastPathComponent,
            "version": "0.9.9",
            "build": 990,
            "size": 6,
            "sha256": try ApplicationUpdateVerifier.sha256Hex(of: updateURL)
        ],
        "rollback": [
            "filename": rollbackURL.lastPathComponent,
            "version": "0.9.8",
            "build": 981,
            "size": 8,
            "sha256": try ApplicationUpdateVerifier.sha256Hex(of: rollbackURL)
        ]
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let signature = try key.signature(for: manifestData)
    let verifier = try ApplicationUpdateVerifier(
        publicKey: key.publicKey.rawRepresentation,
        currentBuild: 981
    )
    #expect(throws: ApplicationUpdateVerificationError.invalidManifest) {
        try verifier.verify(
            manifestData: manifestData,
            signatureData: Data(signature.base64EncodedString().utf8),
            updateURL: updateURL,
            rollbackURL: rollbackURL,
            now: now
        )
    }
}

@Test("QA initial navigation is restricted to an isolated profile and loopback HTTP")
@MainActor
func qaInitialNavigationCannotTargetProductionOrRemoteSites() throws {
    let allowed = BrowserStore.isolatedQAInitialURL(environment: [
        "CFFIXED_USER_HOME": "/private/tmp/rex-qa-smoke.ABC123",
        "REX_QA_ISOLATED": "1",
        "REX_QA_INITIAL_URL": "http://127.0.0.1:18765/"
    ])
    #expect(allowed?.absoluteString == "http://127.0.0.1:18765/")
    #expect(BrowserStore.isolatedQAInitialURL(environment: [
        "CFFIXED_USER_HOME": NSHomeDirectory(),
        "REX_QA_ISOLATED": "1",
        "REX_QA_INITIAL_URL": "http://127.0.0.1:18765/"
    ]) == nil)
    #expect(BrowserStore.isolatedQAInitialURL(environment: [
        "CFFIXED_USER_HOME": "/tmp/rex-qa-smoke.ABC123",
        "REX_QA_ISOLATED": "1",
        "REX_QA_INITIAL_URL": "https://example.com/"
    ]) == nil)
    #expect(BrowserStore.isolatedQAInitialURL(environment: [
        "CFFIXED_USER_HOME": "/tmp/rex-qa-smoke.ABC123",
        "REX_QA_INITIAL_URL": "http://127.0.0.1:18765/"
    ]) == nil)

    let qaEnvironment = [
        "CFFIXED_USER_HOME": "/private/tmp/rex-qa-smoke.ABC123",
        "REX_QA_ISOLATED": "1",
        "REX_QA_INITIAL_URL": "http://localhost:18765/installer.pkg",
        "REX_QA_DOWNLOAD_DIRECTORY": "/private/tmp/rex-qa-smoke.ABC123/Downloads/Rex"
    ]
    #expect(BrowserStore.isolatedQADownloadDirectory(environment: qaEnvironment)?.path
        == "/private/tmp/rex-qa-smoke.ABC123/Downloads/Rex")
    #expect(BrowserStore.isolatedQADownloadDirectory(environment: [
        "CFFIXED_USER_HOME": "/private/tmp/rex-qa-smoke.ABC123",
        "REX_QA_ISOLATED": "1",
        "REX_QA_INITIAL_URL": "http://localhost:18765/installer.pkg",
        "REX_QA_DOWNLOAD_DIRECTORY": "/tmp/rex-qa-downloads"
    ]) == nil)
}
