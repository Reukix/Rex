import CryptoKit
import Foundation
import Security
import Testing
import zlib
@testable import RexApp

private struct ChromePackageFixtureFetcher: ChromeWebStorePackageFetching {
    let packageData: Data

    func fetchPackage(
        extensionID: String,
        destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        progress(0, Int64(packageData.count))
        try packageData.write(to: destinationURL, options: .withoutOverwriting)
        progress(Int64(packageData.count), Int64(packageData.count))
    }
}

private struct SignedCRXFixture {
    let extensionID: String
    let publicKey: Data
    let data: Data
}

private enum SignedCRXVersion: UInt32, CaseIterable {
    case crx2 = 2
    case crx3 = 3
}

private enum ChromePackageFixtureError: Error {
    case keyGeneration
    case keyExport
    case signature
}

private func makeSignedCRXFixture(
    version: SignedCRXVersion = .crx3,
    manifestKey: String? = nil
) throws -> SignedCRXFixture {
    var manifestObject: [String: Any] = [
        "manifest_version": 3,
        "name": "Signed Store Fixture",
        "version": "1.2.3",
        "description": "A deterministic install pipeline fixture"
    ]
    if let manifestKey {
        manifestObject["key"] = manifestKey
    }
    let manifest = try JSONSerialization.data(
        withJSONObject: manifestObject,
        options: [.prettyPrinted, .sortedKeys]
    )
    let zip = makeStoredZIP(filename: "manifest.json", contents: manifest)

    let privateKeyAttributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: 2_048
    ]
    var keyError: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(
        privateKeyAttributes as CFDictionary,
        &keyError
    ) else {
        throw keyError?.takeRetainedValue() ?? ChromePackageFixtureError.keyGeneration
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
        throw ChromePackageFixtureError.keyGeneration
    }

    var exportError: Unmanaged<CFError>?
    guard let rawPublicKey = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
        throw exportError?.takeRetainedValue() ?? ChromePackageFixtureError.keyExport
    }
    let subjectPublicKeyInfo = rsaSubjectPublicKeyInfo(rawPublicKey)
    let extensionID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: subjectPublicKeyInfo)

    var crx = Data("Cr24".utf8)
    crx.appendLittleEndian(version.rawValue)
    switch version {
    case .crx2:
        let digest = Data(Insecure.SHA1.hash(data: zip))
        let signature = try sign(
            digest,
            with: privateKey,
            algorithm: .rsaSignatureDigestPKCS1v15SHA1
        )
        crx.appendLittleEndian(UInt32(subjectPublicKeyInfo.count))
        crx.appendLittleEndian(UInt32(signature.count))
        crx.append(subjectPublicKeyInfo)
        crx.append(signature)
    case .crx3:
        let signedHeaderData = protobufBytesField(
            1,
            try ChromeExtensionArchiveVerifier.extensionIDBytes(extensionID)
        )
        var hasher = SHA256()
        hasher.update(data: Data("CRX3 SignedData\0".utf8))
        var signedHeaderLength = UInt32(signedHeaderData.count).littleEndian
        Swift.withUnsafeBytes(of: &signedHeaderLength) {
            hasher.update(bufferPointer: $0)
        }
        hasher.update(data: signedHeaderData)
        hasher.update(data: zip)
        let signature = try sign(
            Data(hasher.finalize()),
            with: privateKey,
            algorithm: .rsaSignatureDigestPKCS1v15SHA256
        )
        var proof = protobufBytesField(1, subjectPublicKeyInfo)
        proof.append(protobufBytesField(2, signature))
        var header = protobufBytesField(2, proof)
        header.append(protobufBytesField(10_000, signedHeaderData))
        crx.appendLittleEndian(UInt32(header.count))
        crx.append(header)
    }
    crx.append(zip)
    return SignedCRXFixture(
        extensionID: extensionID,
        publicKey: subjectPublicKeyInfo,
        data: crx
    )
}

private func sign(
    _ digest: Data,
    with privateKey: SecKey,
    algorithm: SecKeyAlgorithm
) throws -> Data {
    var signatureError: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
        privateKey,
        algorithm,
        digest as CFData,
        &signatureError
    ) as Data? else {
        throw signatureError?.takeRetainedValue() ?? ChromePackageFixtureError.signature
    }
    return signature
}

private func protobufBytesField(_ fieldNumber: UInt64, _ contents: Data) -> Data {
    var result = protobufVarint((fieldNumber << 3) | 2)
    result.append(protobufVarint(UInt64(contents.count)))
    result.append(contents)
    return result
}

private func protobufVarint(_ value: UInt64) -> Data {
    var remaining = value
    var result = Data()
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        result.append(byte)
    } while remaining != 0
    return result
}

private func makeStoredZIP(filename: String, contents: Data) -> Data {
    let name = Data(filename.utf8)
    let checksum = contents.withUnsafeBytes { buffer in
        UInt32(zlib.crc32(
            0,
            buffer.bindMemory(to: Bytef.self).baseAddress,
            uInt(buffer.count)
        ))
    }

    var local = Data()
    local.appendLittleEndian(UInt32(0x0403_4b50))
    local.appendLittleEndian(UInt16(20))
    local.appendLittleEndian(UInt16(0))
    local.appendLittleEndian(UInt16(0))
    local.appendLittleEndian(UInt16(0))
    local.appendLittleEndian(UInt16(0))
    local.appendLittleEndian(checksum)
    local.appendLittleEndian(UInt32(contents.count))
    local.appendLittleEndian(UInt32(contents.count))
    local.appendLittleEndian(UInt16(name.count))
    local.appendLittleEndian(UInt16(0))
    local.append(name)
    local.append(contents)

    var central = Data()
    central.appendLittleEndian(UInt32(0x0201_4b50))
    central.appendLittleEndian(UInt16(20))
    central.appendLittleEndian(UInt16(20))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(checksum)
    central.appendLittleEndian(UInt32(contents.count))
    central.appendLittleEndian(UInt32(contents.count))
    central.appendLittleEndian(UInt16(name.count))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt16(0))
    central.appendLittleEndian(UInt32(0))
    central.appendLittleEndian(UInt32(0))
    central.append(name)

    var end = Data()
    end.appendLittleEndian(UInt32(0x0605_4b50))
    end.appendLittleEndian(UInt16(0))
    end.appendLittleEndian(UInt16(0))
    end.appendLittleEndian(UInt16(1))
    end.appendLittleEndian(UInt16(1))
    end.appendLittleEndian(UInt32(central.count))
    end.appendLittleEndian(UInt32(local.count))
    end.appendLittleEndian(UInt16(0))

    var zip = local
    zip.append(central)
    zip.append(end)
    return zip
}

private func rsaSubjectPublicKeyInfo(_ rawPublicKey: Data) -> Data {
    let rsaEncryptionIdentifier = Data([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00
    ])
    var bitStringContents = Data([0])
    bitStringContents.append(rawPublicKey)
    let bitString = derValue(tag: 0x03, contents: bitStringContents)
    var body = rsaEncryptionIdentifier
    body.append(bitString)
    return derValue(tag: 0x30, contents: body)
}

private func derValue(tag: UInt8, contents: Data) -> Data {
    var result = Data([tag])
    if contents.count < 128 {
        result.append(UInt8(contents.count))
    } else {
        var value = contents.count
        var lengthBytes: [UInt8] = []
        while value > 0 {
            lengthBytes.append(UInt8(value & 0xff))
            value >>= 8
        }
        result.append(0x80 | UInt8(lengthBytes.count))
        result.append(contentsOf: lengthBytes.reversed())
    }
    result.append(contents)
    return result
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private func writeTestManifest(to directory: URL, key: Any? = nil) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var manifest: [String: Any] = [
        "manifest_version": 3,
        "name": "Identity Fixture",
        "version": "1.0.0"
    ]
    if let key {
        manifest["key"] = key
    }
    let data = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted, .sortedKeys]
    )
    let manifestURL = directory.appendingPathComponent("manifest.json")
    try data.write(to: manifestURL)
    return manifestURL
}

private func readTestManifest(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("Chrome Web Store URL policy stays pinned to Google package hosts")
func chromeWebStoreDownloadPolicyIsRestricted() throws {
    let extensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    let url = try #require(ChromeWebStoreDownloadPolicy.downloadURL(extensionID: extensionID))
    #expect(url.scheme == "https")
    #expect(url.host == ChromeWebStoreDownloadPolicy.updateHost)
    #expect(ChromeWebStoreDownloadPolicy.permits(url))
    #expect(ChromeWebStoreDownloadPolicy.permits(
        URL(string: "https://clients2.googleusercontent.com/package.crx")
    ))
    #expect(!ChromeWebStoreDownloadPolicy.permits(
        URL(string: "https://example.com/package.crx")
    ))
    #expect(ChromeWebStoreDownloadPolicy.downloadURL(extensionID: "invalid") == nil)
}

@Test("CRX2 and CRX3 verification retain the signing identity key")
func signedChromeArchivesRetainVerifiedPublicKey() throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-crx-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    for version in SignedCRXVersion.allCases {
        let fixture = try makeSignedCRXFixture(version: version)
        let crxURL = sandbox.appendingPathComponent("\(version.rawValue).crx")
        try fixture.data.write(to: crxURL)
        let archive = try ChromeExtensionArchiveVerifier.verify(
            crxAt: crxURL,
            expectedExtensionID: fixture.extensionID
        )

        #expect(archive.publicKey == fixture.publicKey)
        #expect(archive.extensionID == fixture.extensionID)
        #expect(
            ChromeExtensionArchiveVerifier.extensionID(forPublicKey: archive.publicKey)
                == fixture.extensionID
        )
    }
}

@Test("A missing manifest key is populated from the verified CRX identity")
func missingManifestIdentityIsInjected() throws {
    let publicKey = Data("verified manifest identity".utf8)
    let extensionID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-manifest-missing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = try writeTestManifest(to: directory)

    try ChromeExtensionManifestIdentity.ensurePublicKey(
        in: directory,
        expectedExtensionID: extensionID,
        publicKey: publicKey
    )

    let manifest = try readTestManifest(at: manifestURL)
    #expect(manifest["key"] as? String == publicKey.base64EncodedString())
}

@Test("A matching manifest key is accepted without rewriting the manifest")
func matchingManifestIdentityIsPreserved() throws {
    let publicKey = Data("existing manifest identity".utf8)
    let extensionID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
    let encodedKey = publicKey.base64EncodedString()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-manifest-matching-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = try writeTestManifest(to: directory, key: encodedKey)
    let originalData = try Data(contentsOf: manifestURL)

    try ChromeExtensionManifestIdentity.ensurePublicKey(
        in: directory,
        expectedExtensionID: extensionID,
        publicKey: publicKey
    )

    #expect(try Data(contentsOf: manifestURL) == originalData)
}

@Test("Invalid and mismatched manifest identity keys are rejected")
func unsafeManifestIdentitiesAreRejected() throws {
    let publicKey = Data("verified manifest identity".utf8)
    let extensionID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-manifest-rejected-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let invalidDirectory = sandbox.appendingPathComponent("invalid", isDirectory: true)
    _ = try writeTestManifest(to: invalidDirectory, key: "not base64!")
    #expect(throws: ChromeWebStoreInstallError.invalidExtensionManifest) {
        try ChromeExtensionManifestIdentity.ensurePublicKey(
            in: invalidDirectory,
            expectedExtensionID: extensionID,
            publicKey: publicKey
        )
    }

    let mismatchedDirectory = sandbox.appendingPathComponent("mismatched", isDirectory: true)
    _ = try writeTestManifest(
        to: mismatchedDirectory,
        key: Data("another identity".utf8).base64EncodedString()
    )
    #expect(throws: ChromeWebStoreInstallError.extensionIDMismatch) {
        try ChromeExtensionManifestIdentity.ensurePublicKey(
            in: mismatchedDirectory,
            expectedExtensionID: extensionID,
            publicKey: publicKey
        )
    }
}

@Test("A symlinked manifest cannot be modified during identity binding")
func symlinkedManifestIdentityIsRejected() throws {
    let publicKey = Data("verified manifest identity".utf8)
    let extensionID = ChromeExtensionArchiveVerifier.extensionID(forPublicKey: publicKey)
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-manifest-symlink-\(UUID().uuidString)", isDirectory: true)
    let extensionDirectory = sandbox.appendingPathComponent("extension", isDirectory: true)
    try FileManager.default.createDirectory(
        at: extensionDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let targetURL = try writeTestManifest(
        to: sandbox.appendingPathComponent("target", isDirectory: true)
    )
    try FileManager.default.createSymbolicLink(
        at: extensionDirectory.appendingPathComponent("manifest.json"),
        withDestinationURL: targetURL
    )

    #expect(throws: ChromeWebStoreInstallError.invalidExtensionManifest) {
        try ChromeExtensionManifestIdentity.ensurePublicKey(
            in: extensionDirectory,
            expectedExtensionID: extensionID,
            publicKey: publicKey
        )
    }
}

@Test("A signed CRX installs end to end and persists its Web Store identity")
@MainActor
func signedChromePackageInstallsEndToEnd() async throws {
    let fixture = try makeSignedCRXFixture()
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-store-install-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let store = BrowserExtensionsStore(
        rootDirectoryURL: sandbox,
        packageFetcher: ChromePackageFixtureFetcher(packageData: fixture.data)
    )
    let installed = try await store.installFromWebStore(
        extensionID: fixture.extensionID,
        displayName: "Fixture"
    )

    #expect(installed.name == "Signed Store Fixture")
    #expect(installed.version == "1.2.3")
    #expect(installed.storeID == fixture.extensionID)
    #expect(installed.resolvedInstallationSource == .chromeWebStore)
    #expect(installed.runtimeStatus == .pendingRuntime)
    #expect(installed.statusDetail?.contains("已从 Chrome Web Store") == true)
    let installedManifestURL = installed.path.appendingPathComponent("manifest.json")
    let installedManifest = try readTestManifest(at: installedManifestURL)
    let encodedManifestKey = try #require(installedManifest["key"] as? String)
    let manifestPublicKey = try #require(Data(base64Encoded: encodedManifestKey))
    let runtimeExtensionID = ChromeExtensionArchiveVerifier.extensionID(
        forPublicKey: manifestPublicKey
    )
    #expect(encodedManifestKey == fixture.publicKey.base64EncodedString())
    #expect(runtimeExtensionID == fixture.extensionID)
    #expect(installed.storeID == runtimeExtensionID)
    #expect(store.catalogInstallState(for: fixture.extensionID)?.phase == .installed)

    let reloaded = BrowserExtensionsStore(rootDirectoryURL: sandbox)
    #expect(reloaded.extensions.count == 1)
    #expect(reloaded.extensions.first?.id == installed.id)
    #expect(reloaded.extensions.first?.storeID == fixture.extensionID)
    #expect(reloaded.extensions.first?.storeID == runtimeExtensionID)
    #expect(reloaded.extensions.first?.resolvedInstallationSource == .chromeWebStore)

    #expect(reloaded.setEnabled(false, for: installed.id))
    let stoppedStore = BrowserExtensionsStore(rootDirectoryURL: sandbox)
    let locallyReimported = try stoppedStore.installUnpacked(from: installed.path)
    #expect(locallyReimported.storeID == nil)
    #expect(locallyReimported.resolvedInstallationSource == .localUnpacked)
}

@Test("A loaded Web Store extension updates and can be acknowledged without restart")
@MainActor
func loadedChromePackageUpdatesInPlace() async throws {
    let fixture = try makeSignedCRXFixture()
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-store-running-update-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let fetcher = ChromePackageFixtureFetcher(packageData: fixture.data)

    let installingStore = BrowserExtensionsStore(
        rootDirectoryURL: sandbox,
        packageFetcher: fetcher
    )
    let installed = try await installingStore.installFromWebStore(
        extensionID: fixture.extensionID,
        displayName: "Fixture"
    )
    let runningStore = BrowserExtensionsStore(
        rootDirectoryURL: sandbox,
        packageFetcher: fetcher
    )
    #expect(runningStore.extensions.first?.runtimeStatus == .ready)
    let installedManifestURL = installed.path.appendingPathComponent("manifest.json")
    let originalManifest = try Data(contentsOf: installedManifestURL)

    let updated = try await runningStore.installFromWebStore(
        extensionID: fixture.extensionID,
        displayName: "Fixture"
    )

    #expect(updated.id == installed.id)
    #expect(updated.runtimeStatus == .pendingRuntime)
    #expect(try Data(contentsOf: installedManifestURL) == originalManifest)
    #expect(runningStore.catalogInstallState(for: fixture.extensionID)?.phase == .installed)
    let replacementTokens = runningStore.pendingRuntimeReplacementTokens
    runningStore.acknowledgeRuntimePaths([updated.path.path])
    #expect(runningStore.commitPendingRuntimeReplacements(tokens: replacementTokens).isEmpty)
    #expect(runningStore.extensions.first?.runtimeStatus == .ready)
}

@Test("A legacy keyless Web Store package is repaired in place")
@MainActor
func legacyKeylessChromePackageIsRepairedInPlace() async throws {
    let fixture = try makeSignedCRXFixture()
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("rex-store-keyless-repair-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let fetcher = ChromePackageFixtureFetcher(packageData: fixture.data)

    let installingStore = BrowserExtensionsStore(
        rootDirectoryURL: sandbox,
        packageFetcher: fetcher
    )
    let installed = try await installingStore.installFromWebStore(
        extensionID: fixture.extensionID,
        displayName: "Fixture"
    )
    let manifestURL = installed.path.appendingPathComponent("manifest.json")
    var legacyManifest = try readTestManifest(at: manifestURL)
    legacyManifest["key"] = nil
    try JSONSerialization.data(
        withJSONObject: legacyManifest,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: manifestURL, options: .atomic)

    let repairStore = BrowserExtensionsStore(
        rootDirectoryURL: sandbox,
        packageFetcher: fetcher
    )
    let keylessPackage = try #require(repairStore.extensions.first)
    #expect(keylessPackage.id == installed.id)
    #expect(keylessPackage.storeID == fixture.extensionID)
    #expect(keylessPackage.runtimeStatus == .invalidManifest)
    #expect(repairStore.startupExtensionPaths.isEmpty)

    let repaired = try await repairStore.installFromWebStore(
        extensionID: fixture.extensionID,
        displayName: keylessPackage.name
    )
    #expect(repairStore.extensions.count == 1)
    #expect(repaired.id == installed.id)
    #expect(repaired.installedAt == keylessPackage.installedAt)
    #expect(repaired.runtimeID == fixture.extensionID)
    #expect(repaired.runtimeStatus == .pendingRuntime)
    let repairedManifest = try readTestManifest(at: manifestURL)
    #expect(repairedManifest["key"] as? String == fixture.publicKey.base64EncodedString())
    let replacementTokens = repairStore.pendingRuntimeReplacementTokens
    repairStore.acknowledgeRuntimePaths([repaired.path.path])
    #expect(repairStore.commitPendingRuntimeReplacements(tokens: replacementTokens).isEmpty)

    let restartedStore = BrowserExtensionsStore(rootDirectoryURL: sandbox)
    #expect(restartedStore.extensions.count == 1)
    #expect(restartedStore.extensions.first?.id == installed.id)
    #expect(restartedStore.extensions.first?.runtimeID == fixture.extensionID)
    #expect(restartedStore.extensions.first?.runtimeStatus == .ready)
    #expect(restartedStore.startupExtensionPaths == [installed.path.path])
}
