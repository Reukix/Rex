import Foundation
import SwiftUI
import Testing
@testable import RexApp

private actor SiteSecurityTestEngine: BrowserEngine {
    private var continuation: AsyncStream<BrowserEvent>.Continuation?
    private var commands: [BrowserCommand] = []

    func execute(_ command: BrowserCommand) {
        commands.append(command)
    }

    func eventStream() -> AsyncStream<BrowserEvent> {
        AsyncStream { continuation = $0 }
    }

    func waitForSubscriber() async {
        while continuation == nil { await Task.yield() }
    }

    func emit(_ event: BrowserEvent) {
        continuation?.yield(event)
    }

    func loadURLs() -> [URL] {
        commands.compactMap { command in
            guard case let .loadURL(_, url) = command else { return nil }
            return url
        }
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        while loadURLs().count < expectedCount { await Task.yield() }
    }
}

private func securityInfo(
    url: URL? = URL(string: "https://example.com"),
    generation: UInt64 = 1,
    isPending: Bool = false,
    isSecure: Bool = true,
    hasCertificateError: Bool = false,
    certificateErrorCode: Int? = nil,
    certificateStatus: SiteCertificateStatus = [],
    contentStatus: SiteSecurityContentStatus = []
) -> SiteSecurityInfo {
    SiteSecurityInfo(
        url: url,
        navigationGeneration: generation,
        isPending: isPending,
        isSecureConnection: isSecure,
        hasCertificateError: hasCertificateError,
        certificateErrorCode: certificateErrorCode,
        certificateStatus: certificateStatus,
        tlsVersion: .tls1_3,
        contentStatus: contentStatus,
        certificate: nil
    )
}

@Test("CEF site security payload decodes certificate metadata and DER chain")
func siteSecurityPayloadDecodesCertificate() throws {
    let leafDER = Data([0x30, 0x82, 0x01])
    let issuerDER = Data([0x30, 0x82, 0x02])
    let payload: [String: Any] = [
        "url": "https://example.com/",
        "navigationGeneration": NSNumber(value: UInt64(7)),
        "isPending": NSNumber(value: false),
        "isSecureConnection": NSNumber(value: true),
        "hasCertificateError": NSNumber(value: false),
        "certificateStatus": NSNumber(value: SiteCertificateStatus.isEV.rawValue),
        "tlsVersion": "tls1_3",
        "contentStatus": NSNumber(value: 0),
        "certificate": [
            "subject": [
                "displayName": "example.com",
                "commonName": "example.com",
                "localityName": "Singapore",
                "stateOrProvinceName": "Singapore",
                "countryName": "SG",
                "organizationNames": ["Example Pte Ltd"],
                "organizationalUnitNames": ["Web"]
            ],
            "issuer": [
                "displayName": "Example Root CA",
                "commonName": "Example Root CA",
                "localityName": "",
                "stateOrProvinceName": "",
                "countryName": "US",
                "organizationNames": ["Example Trust"],
                "organizationalUnitNames": []
            ],
            "serialNumberHex": "00A1B2",
            "validFrom": NSNumber(value: 1_700_000_000.0),
            "validTo": NSNumber(value: 1_800_000_000.0),
            "leafDER": leafDER as NSData,
            "issuerDERChain": [issuerDER as NSData]
        ]
    ]

    let info = try #require(SiteSecurityPayloadDecoder.decode(payload))
    #expect(info.url == URL(string: "https://example.com/"))
    #expect(info.navigationGeneration == 7)
    #expect(info.level == .secure)
    #expect(info.tlsVersion == .tls1_3)
    #expect(info.certificateStatus.contains(.isEV))
    let certificate = try #require(info.certificate)
    #expect(certificate.subject?.commonName == "example.com")
    #expect(certificate.subject?.organizationNames == ["Example Pte Ltd"])
    #expect(certificate.issuer?.displayName == "Example Root CA")
    #expect(certificate.serialNumberHex == "00A1B2")
    #expect(certificate.validFrom == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(certificate.validTo == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(certificate.leafDER == leafDER)
    #expect(certificate.issuerDERChain == [issuerDER])
    #expect(certificate.derChain == [leafDER, issuerDER])
}

@Test("Site security level prioritizes pending, certificate errors, and mixed content")
func siteSecurityLevelMapping() {
    #expect(securityInfo(isPending: true).level == .pending)
    #expect(securityInfo().level == .secure)
    #expect(securityInfo(contentStatus: [.displayedInsecureContent]).level == .warning)
    #expect(securityInfo(contentStatus: [.ranInsecureContent]).level == .dangerous)
    #expect(securityInfo(hasCertificateError: true).level == .dangerous)
    #expect(securityInfo(certificateErrorCode: -202).level == .dangerous)
    #expect(securityInfo(certificateStatus: [.dateInvalid]).level == .dangerous)
    #expect(securityInfo(certificateStatus: [.ctComplianceFailed]).level == .warning)
    #expect(securityInfo(
        url: URL(string: "http://example.com"),
        isSecure: false
    ).level == .insecure)
    #expect(securityInfo(
        url: URL(string: "about:blank"),
        isSecure: false
    ).level == .internalPage)
}

@Test("Site security payload requires a navigation generation")
func siteSecurityPayloadRejectsMissingGeneration() {
    #expect(SiteSecurityPayloadDecoder.decode([
        "url": "https://example.com",
        "isSecureConnection": true
    ]) == nil)
}

@Test("Certificate viewer freezes the selected navigation snapshot")
func certificateViewerUsesFrozenSnapshot() throws {
    let originalURL = try #require(URL(string: "https://example.com/account"))
    let certificate = SiteCertificate(
        subject: nil,
        issuer: nil,
        serialNumberHex: "A1B2C3",
        validFrom: nil,
        validTo: nil,
        leafDER: Data([0x30, 0x01]),
        issuerDERChain: []
    )
    var info = securityInfo(url: originalURL, generation: 42)
    info.certificate = certificate
    let snapshot = CertificateViewerSnapshot(info: info, certificate: certificate)

    info.url = URL(string: "https://next.example/")
    info.navigationGeneration = 43

    #expect(snapshot.info.url == originalURL)
    #expect(snapshot.info.navigationGeneration == 42)
    #expect(snapshot.certificate == certificate)
    #expect(snapshot.id == CertificateViewerSnapshot.ID(
        url: originalURL,
        navigationGeneration: 42,
        serialNumberHex: "A1B2C3"
    ))
}

@Test("Windowed CEF corner mask covers only the square viewport corners")
func windowedCEFCornerMaskGeometry() {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
    let mask = WindowedCEFViewportCornerMask(cornerRadius: 18).path(in: bounds)

    #expect(mask.contains(CGPoint(x: 1, y: 1), eoFill: true))
    #expect(mask.contains(CGPoint(x: 199, y: 119), eoFill: true))
    #expect(!mask.contains(CGPoint(x: 100, y: 60), eoFill: true))
    #expect(!mask.contains(CGPoint(x: 100, y: 1), eoFill: true))
}

@Test("Browser store keeps the newest per-tab security snapshot and clears it on close")
@MainActor
func browserStoreTracksSiteSecurityByTab() async throws {
    let engine = SiteSecurityTestEngine()
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: "rex-site-security-tests-\(UUID().uuidString)/Browser.sqlite")
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: databaseURL,
            legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await engine.waitForSubscriber()

    let tabID = store.selectedTabID
    let tabURL = try #require(store.currentTab?.url)
    let newest = securityInfo(url: tabURL, generation: 2)
    await engine.emit(.siteSecurityChanged(tabID: tabID, info: newest))
    for _ in 0..<100 where store.siteSecurityInfoByTabID[tabID] == nil {
        await Task.yield()
    }
    #expect(store.currentSiteSecurityInfo == newest)

    await engine.emit(.siteSecurityChanged(
        tabID: tabID,
        info: securityInfo(url: tabURL, generation: 1, hasCertificateError: true)
    ))
    await engine.emit(.siteSecurityChanged(
        tabID: tabID,
        info: securityInfo(url: tabURL, generation: 2, isPending: true, isSecure: false)
    ))
    for _ in 0..<5 { await Task.yield() }
    #expect(store.currentSiteSecurityInfo == newest)

    await engine.emit(.navigationFailed(
        tabID: tabID,
        url: tabURL,
        errorCode: -202,
        reason: "certificate rejected"
    ))
    for _ in 0..<5 { await Task.yield() }
    #expect(store.currentSiteSecurityInfo == newest)
    #expect(store.currentTab?.lifecycle != .crashed)
    #expect(store.lastError == nil)

    store.closeTab(tabID)
    #expect(store.siteSecurityInfoByTabID[tabID] == nil)
}

@Test("HTTPS upgrade falls back to HTTP once but never for certificate errors")
@MainActor
func httpsUpgradeFallbackIsBoundedAndCertificateSafe() async throws {
    let fallbackEngine = SiteSecurityTestEngine()
    let fallbackStore = BrowserStore(
        engine: fallbackEngine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "rex-https-fallback-tests-\(UUID().uuidString)/Browser.sqlite"),
            legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await fallbackEngine.waitForSubscriber()
    let fallbackTabID = fallbackStore.selectedTabID
    let submittedHTTPURL = try #require(URL(
        string: "http://legacy.example/path?utm_source=fallback-test&keep=1"
    ))
    let httpURL = try #require(URL(string: "http://legacy.example/path?keep=1"))
    let httpsURL = try #require(URL(string: "https://legacy.example/path?keep=1"))

    fallbackStore.addressText = submittedHTTPURL.absoluteString
    fallbackStore.submitAddress()
    await fallbackEngine.waitForLoadCount(1)
    #expect(await fallbackEngine.loadURLs() == [httpsURL])

    await fallbackEngine.emit(.navigationFailed(
        tabID: fallbackTabID,
        url: httpsURL,
        errorCode: -107,
        reason: "TLS protocol unsupported"
    ))
    await fallbackEngine.waitForLoadCount(2)
    #expect(await fallbackEngine.loadURLs() == [httpsURL, httpURL])
    #expect(fallbackStore.currentTab?.url == httpURL)

    await fallbackEngine.emit(.navigationChanged(
        tabID: fallbackTabID,
        state: NavigationState(url: httpURL, title: "Legacy", isLoading: true)
    ))
    await fallbackEngine.emit(.navigationChanged(
        tabID: fallbackTabID,
        state: NavigationState(url: httpURL, title: "Legacy", isLoading: false)
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(await fallbackEngine.loadURLs() == [httpsURL, httpURL])

    await fallbackEngine.emit(.navigationFailed(
        tabID: fallbackTabID,
        url: httpURL,
        errorCode: -102,
        reason: "HTTP fallback failed"
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(await fallbackEngine.loadURLs() == [httpsURL, httpURL])
    #expect(fallbackStore.lastError == nil)

    let certificateEngine = SiteSecurityTestEngine()
    let certificateStore = BrowserStore(
        engine: certificateEngine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "rex-https-certificate-tests-\(UUID().uuidString)/Browser.sqlite"),
            legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await certificateEngine.waitForSubscriber()
    let certificateTabID = certificateStore.selectedTabID
    certificateStore.addressText = submittedHTTPURL.absoluteString
    certificateStore.submitAddress()
    await certificateEngine.waitForLoadCount(1)

    let certificateError = securityInfo(
        url: httpsURL,
        generation: 4,
        isSecure: false,
        hasCertificateError: true,
        certificateErrorCode: -202,
        certificateStatus: [.authorityInvalid]
    )
    await certificateEngine.emit(.siteSecurityChanged(
        tabID: certificateTabID,
        info: certificateError
    ))
    await certificateEngine.emit(.navigationFailed(
        tabID: certificateTabID,
        url: httpsURL,
        errorCode: -202,
        reason: "Certificate rejected"
    ))
    for _ in 0..<10 { await Task.yield() }

    #expect(await certificateEngine.loadURLs() == [httpsURL])
    #expect(certificateStore.currentTab?.url == httpsURL)
    #expect(certificateStore.currentSiteSecurityInfo == certificateError)
}

@Test("Certificate errors outrank same-generation secure snapshots and stale URLs stay hidden")
@MainActor
func certificateErrorSnapshotPrecedence() async throws {
    let engine = SiteSecurityTestEngine()
    let store = BrowserStore(
        engine: engine,
        databasePersistence: BrowserSQLitePersistence(
            databaseURL: FileManager.default.temporaryDirectory
                .appending(path: "rex-security-precedence-tests-\(UUID().uuidString)/Browser.sqlite"),
            legacyPersistence: nil
        ),
        profile: .privateWindow()
    )
    await engine.waitForSubscriber()
    let tabID = store.selectedTabID
    let securedURL = try #require(URL(string: "https://secure.example/"))
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(url: securedURL, title: "Secure", isLoading: false)
    ))
    for _ in 0..<10 where store.currentTab?.url != securedURL { await Task.yield() }

    let certificateError = securityInfo(
        url: securedURL,
        generation: 9,
        isSecure: false,
        hasCertificateError: true,
        certificateErrorCode: -202,
        certificateStatus: [.authorityInvalid]
    )
    await engine.emit(.siteSecurityChanged(tabID: tabID, info: certificateError))
    await engine.emit(.siteSecurityChanged(
        tabID: tabID,
        info: securityInfo(url: securedURL, generation: 9)
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(store.currentSiteSecurityInfo == certificateError)

    let nextURL = try #require(URL(string: "https://next.example/"))
    await engine.emit(.navigationChanged(
        tabID: tabID,
        state: NavigationState(url: nextURL, title: "Next", isLoading: true)
    ))
    for _ in 0..<10 where store.currentTab?.url != nextURL { await Task.yield() }
    #expect(store.currentSiteSecurityInfo == nil)
}
