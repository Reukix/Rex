import Foundation

/// A user-visible Chromium extension resource URL.
///
/// Rex stores and displays `rex-extension://` URLs. The equivalent
/// `chrome-extension://` URL exists only at the CEF execution boundary so the
/// extension keeps Chromium's native origin, APIs, permissions and lifecycle.
struct RexExtensionResourceURL: Equatable, Sendable {
    static let scheme = "rex-extension"
    static let chromiumScheme = "chrome-extension"

    let runtimeID: String
    let percentEncodedPath: String
    let percentEncodedQuery: String?
    let percentEncodedFragment: String?

    init?(runtimeID: String, relativePath: String) {
        guard Self.isValidRuntimeID(runtimeID),
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = runtimeID
        components.path = "/\(relativePath)"
        guard let url = components.url else { return nil }
        self.init(rexURL: url)
    }

    init?(rexURL url: URL) {
        self.init(url: url, expectedScheme: Self.scheme)
    }

    init?(chromiumURL url: URL) {
        self.init(url: url, expectedScheme: Self.chromiumScheme)
    }

    var rexURL: URL {
        makeURL(scheme: Self.scheme)
    }

    var chromiumURL: URL {
        makeURL(scheme: Self.chromiumScheme)
    }

    static func isValidRuntimeID(_ value: String) -> Bool {
        value.utf8.count == 32
            && value.utf8.allSatisfy { (97...112).contains($0) }
    }

    static func rexURL(fromChromiumURL url: URL) -> URL? {
        RexExtensionResourceURL(chromiumURL: url)?.rexURL
    }

    static func chromiumURL(fromRexURL url: URL) -> URL? {
        RexExtensionResourceURL(rexURL: url)?.chromiumURL
    }

    /// Converts an execution-only Chromium extension URL into the Rex URL
    /// exposed to application state. Invalid Chromium extension URLs are
    /// rejected instead of leaking across the runtime boundary.
    static func userVisibleURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == chromiumScheme else { return url }
        return rexURL(fromChromiumURL: url)
    }

    /// Permission APIs report origins without a resource path, so they cannot
    /// use the resource URL parser above.
    static func userVisibleOrigin(from value: String) -> String {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == chromiumScheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased(),
              isValidRuntimeID(host) else {
            return value
        }
        return "\(scheme)://\(host)"
    }

    /// Chromium may use a page URL as its fallback title. Convert only values
    /// that are themselves extension URLs or origins; normal page titles stay
    /// untouched.
    static func userVisibleString(from value: String) -> String {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == chromiumScheme else {
            return value
        }
        if let visibleURL = userVisibleURL(from: url) {
            return visibleURL.absoluteString
        }
        return userVisibleOrigin(from: value)
    }

    static func matchesScheme(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }

    private init?(url: URL, expectedScheme: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == expectedScheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host,
              components.percentEncodedHost == host,
              Self.isValidRuntimeID(host),
              components.percentEncodedPath.utf8.count <= 8_192,
              Self.isSafePercentEncodedPath(components.percentEncodedPath),
              Self.isSafeOptionalURLComponent(
                  components.percentEncodedQuery,
                  maximumUTF8Count: 8_192
              ),
              Self.isSafeOptionalURLComponent(
                  components.percentEncodedFragment,
                  maximumUTF8Count: 4_096
              ) else {
            return nil
        }

        runtimeID = host
        percentEncodedPath = components.percentEncodedPath
        percentEncodedQuery = components.percentEncodedQuery
        percentEncodedFragment = components.percentEncodedFragment
    }

    private func makeURL(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = runtimeID
        components.percentEncodedPath = percentEncodedPath
        components.percentEncodedQuery = percentEncodedQuery
        components.percentEncodedFragment = percentEncodedFragment
        return components.url!
    }

    private static func isSafePercentEncodedPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              !value.hasPrefix("//"),
              value.count > 1,
              hasCanonicalPercentEncoding(value),
              let decoded = value.removingPercentEncoding,
              decoded.hasPrefix("/"),
              !decoded.contains("%"),
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }
        let encodedSlashCount = value.utf8.filter { $0 == 47 }.count
        let decodedSlashCount = decoded.utf8.filter { $0 == 47 }.count
        guard encodedSlashCount == decodedSlashCount else { return false }
        return decoded.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeOptionalURLComponent(
        _ value: String?,
        maximumUTF8Count: Int
    ) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= maximumUTF8Count,
              hasValidPercentEncoding(value),
              let decoded = value.removingPercentEncoding else {
            return false
        }
        return !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func hasCanonicalPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 37 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isUppercaseHexDigit(bytes[index + 1]),
                  isUppercaseHexDigit(bytes[index + 2]),
                  let decodedByte = decodedHexByte(
                      high: bytes[index + 1],
                      low: bytes[index + 2]
                  ),
                  !isUnreserved(decodedByte),
                  decodedByte != 37,
                  decodedByte != 47,
                  decodedByte != 92 else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 37 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isHexDigit(bytes[index + 1]),
                  isHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isHexDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
            || (65...70).contains(value)
            || (97...102).contains(value)
    }

    private static func isUppercaseHexDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...70).contains(value)
    }

    private static func decodedHexByte(high: UInt8, low: UInt8) -> UInt8? {
        guard let highValue = hexValue(high), let lowValue = hexValue(low) else { return nil }
        return highValue << 4 | lowValue
    }

    private static func hexValue(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: nil
        }
    }

    private static func isUnreserved(_ value: UInt8) -> Bool {
        (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || [45, 46, 95, 126].contains(value)
    }
}

struct RexExtensionSurfaceRuntimeID: Equatable, Sendable {
    private static let prefix = "rex-extension-surface"

    let sourceTabID: UUID?
    let surfaceID: String
    let nonce: UUID

    init(sourceTabID: UUID?, surfaceID: String, nonce: UUID = UUID()) {
        self.sourceTabID = sourceTabID
        self.surfaceID = Self.normalizedSurfaceID(surfaceID)
        self.nonce = nonce
    }

    init?(rawValue: String) {
        let components = rawValue.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == Self.prefix,
              !components[2].isEmpty,
              components[2].utf8.count <= 80,
              components[2].allSatisfy(Self.isAllowedSurfaceCharacter),
              let nonce = UUID(uuidString: String(components[3])) else {
            return nil
        }

        let sourceValue = String(components[1])
        if sourceValue == "none" {
            sourceTabID = nil
        } else if let sourceTabID = UUID(uuidString: sourceValue) {
            self.sourceTabID = sourceTabID
        } else {
            return nil
        }
        surfaceID = String(components[2])
        self.nonce = nonce
    }

    var rawValue: String {
        [
            Self.prefix,
            sourceTabID?.uuidString.lowercased() ?? "none",
            surfaceID,
            nonce.uuidString.lowercased()
        ].joined(separator: ":")
    }

    private static func normalizedSurfaceID(_ value: String) -> String {
        let normalized = String(
            value.lowercased().map { isAllowedSurfaceCharacter($0) ? $0 : "-" }
        )
        let bounded = String(normalized.prefix(80))
        return bounded.isEmpty ? "extension" : bounded
    }

    private static func isAllowedSurfaceCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }
}
