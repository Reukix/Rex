import Foundation

enum SiteSecurityLevel: String, Sendable {
    case pending
    case secure
    case warning
    case dangerous
    case insecure
    case internalPage
    case unknown
}

enum SiteTLSVersion: String, Sendable {
    case unknown
    case ssl2
    case ssl3
    case tls1
    case tls1_1
    case tls1_2
    case tls1_3
    case quic
}

struct SiteCertificateStatus: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let commonNameInvalid = Self(rawValue: 1 << 0)
    static let dateInvalid = Self(rawValue: 1 << 1)
    static let authorityInvalid = Self(rawValue: 1 << 2)
    static let noRevocationMechanism = Self(rawValue: 1 << 4)
    static let unableToCheckRevocation = Self(rawValue: 1 << 5)
    static let revoked = Self(rawValue: 1 << 6)
    static let invalid = Self(rawValue: 1 << 7)
    static let weakSignatureAlgorithm = Self(rawValue: 1 << 8)
    static let nonUniqueName = Self(rawValue: 1 << 10)
    static let weakKey = Self(rawValue: 1 << 11)
    static let pinnedKeyMissing = Self(rawValue: 1 << 13)
    static let nameConstraintViolation = Self(rawValue: 1 << 14)
    static let validityTooLong = Self(rawValue: 1 << 15)
    static let isEV = Self(rawValue: 1 << 16)
    static let revocationCheckingEnabled = Self(rawValue: 1 << 17)
    static let sha1SignaturePresent = Self(rawValue: 1 << 19)
    static let ctComplianceFailed = Self(rawValue: 1 << 20)

    static let warningStatuses: Self = [
        .noRevocationMechanism,
        .unableToCheckRevocation,
        .sha1SignaturePresent,
        .ctComplianceFailed
    ]

    static let blockingStatuses: Self = [
        .commonNameInvalid,
        .dateInvalid,
        .authorityInvalid,
        .revoked,
        .invalid,
        .weakSignatureAlgorithm,
        .nonUniqueName,
        .weakKey,
        .pinnedKeyMissing,
        .nameConstraintViolation,
        .validityTooLong
    ]
}

struct SiteSecurityContentStatus: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let displayedInsecureContent = Self(rawValue: 1 << 0)
    static let ranInsecureContent = Self(rawValue: 1 << 1)
}

struct SiteCertificatePrincipal: Hashable, Sendable {
    var displayName: String
    var commonName: String
    var localityName: String
    var stateOrProvinceName: String
    var countryName: String
    var organizationNames: [String]
    var organizationalUnitNames: [String]
}

struct SiteCertificate: Hashable, Sendable {
    var subject: SiteCertificatePrincipal?
    var issuer: SiteCertificatePrincipal?
    var serialNumberHex: String
    var validFrom: Date?
    var validTo: Date?
    var leafDER: Data?
    var issuerDERChain: [Data]

    var derChain: [Data] {
        leafDER.map { [$0] + issuerDERChain } ?? issuerDERChain
    }
}

struct SiteSecurityInfo: Hashable, Sendable {
    var url: URL?
    var navigationGeneration: UInt64
    var isPending: Bool
    var isSecureConnection: Bool
    var hasCertificateError: Bool
    var certificateErrorCode: Int?
    var certificateStatus: SiteCertificateStatus
    var tlsVersion: SiteTLSVersion
    var contentStatus: SiteSecurityContentStatus
    var certificate: SiteCertificate?

    var level: SiteSecurityLevel {
        if isPending { return .pending }
        if url?.scheme?.lowercased() == "about" { return .internalPage }
        if hasCertificateError || certificateErrorCode != nil ||
            !certificateStatus.intersection(.blockingStatuses).isEmpty ||
            contentStatus.contains(.ranInsecureContent) {
            return .dangerous
        }
        if contentStatus.contains(.displayedInsecureContent) ||
            !certificateStatus.intersection(.warningStatuses).isEmpty {
            return .warning
        }
        if isSecureConnection { return .secure }
        switch url?.scheme?.lowercased() {
        case "http": return .insecure
        case "https": return .dangerous
        default: return .unknown
        }
    }
}

enum SiteSecurityPayloadDecoder {
    static func decode(_ payload: [String: Any]) -> SiteSecurityInfo? {
        guard let generation = unsignedInteger(payload["navigationGeneration"]) else { return nil }

        let certificate = (payload["certificate"] as? [String: Any]).map(decodeCertificate)
        let errorCode = integer(payload["certificateErrorCode"])
        return SiteSecurityInfo(
            url: string(payload["url"]).flatMap(URL.init(string:)),
            navigationGeneration: generation,
            isPending: boolean(payload["isPending"]) ?? false,
            isSecureConnection: boolean(payload["isSecureConnection"]) ?? false,
            hasCertificateError: boolean(payload["hasCertificateError"]) ?? false,
            certificateErrorCode: errorCode,
            certificateStatus: SiteCertificateStatus(
                rawValue: unsignedInteger32(payload["certificateStatus"]) ?? 0
            ),
            tlsVersion: string(payload["tlsVersion"])
                .flatMap(SiteTLSVersion.init(rawValue:)) ?? .unknown,
            contentStatus: SiteSecurityContentStatus(
                rawValue: unsignedInteger32(payload["contentStatus"]) ?? 0
            ),
            certificate: certificate
        )
    }

    private static func decodeCertificate(_ payload: [String: Any]) -> SiteCertificate {
        SiteCertificate(
            subject: (payload["subject"] as? [String: Any]).map(decodePrincipal),
            issuer: (payload["issuer"] as? [String: Any]).map(decodePrincipal),
            serialNumberHex: string(payload["serialNumberHex"]) ?? "",
            validFrom: date(payload["validFrom"]),
            validTo: date(payload["validTo"]),
            leafDER: data(payload["leafDER"]),
            issuerDERChain: dataArray(payload["issuerDERChain"])
        )
    }

    private static func decodePrincipal(_ payload: [String: Any]) -> SiteCertificatePrincipal {
        SiteCertificatePrincipal(
            displayName: string(payload["displayName"]) ?? "",
            commonName: string(payload["commonName"]) ?? "",
            localityName: string(payload["localityName"]) ?? "",
            stateOrProvinceName: string(payload["stateOrProvinceName"]) ?? "",
            countryName: string(payload["countryName"]) ?? "",
            organizationNames: stringArray(payload["organizationNames"]),
            organizationalUnitNames: stringArray(payload["organizationalUnitNames"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return (value as? NSNumber)?.uint64Value
    }

    private static func unsignedInteger32(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? Int, value >= 0 { return UInt32(clamping: value) }
        return (value as? NSNumber)?.uint32Value
    }

    private static func date(_ value: Any?) -> Date? {
        let seconds: Double?
        if let value = value as? Double {
            seconds = value
        } else {
            seconds = (value as? NSNumber)?.doubleValue
        }
        guard let seconds, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func data(_ value: Any?) -> Data? {
        if let value = value as? Data { return value }
        if let value = value as? NSData { return Data(referencing: value) }
        return nil
    }

    private static func dataArray(_ value: Any?) -> [Data] {
        (value as? [Any])?.compactMap(data) ?? []
    }
}
