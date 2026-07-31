import Foundation

/// Mozilla PSL-backed site ownership. The same pinned data file is loaded by
/// the Chromium request layer; Rex uses it to scope user-visible site policy.
struct PublicSuffixList: Sendable {
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var selectedList: PublicSuffixList?
    private static let bundledList = loadBundledList()

    static var current: PublicSuffixList {
        currentLock.withLock { selectedList ?? bundledList }
    }

    let version: String
    let exactRules: Set<String>
    let wildcardRules: Set<String>
    let exceptionRules: Set<String>

    func registrableDomain(for rawHost: String) -> String {
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty,
              host != "localhost",
              !Self.isIPAddress(host) else {
            return host
        }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return host }

        var publicSuffixLabels = 1
        for startIndex in labels.indices {
            let suffix = labels[startIndex...].joined(separator: ".")
            if exceptionRules.contains(suffix) {
                publicSuffixLabels = max(1, labels.count - startIndex - 1)
                break
            }
            if exactRules.contains(suffix) {
                publicSuffixLabels = max(publicSuffixLabels, labels.count - startIndex)
            }
            if startIndex > labels.startIndex, wildcardRules.contains(suffix) {
                publicSuffixLabels = max(publicSuffixLabels, labels.count - startIndex + 1)
            }
        }

        guard labels.count > publicSuffixLabels else { return host }
        return labels.suffix(publicSuffixLabels + 1).joined(separator: ".")
    }

    static func parse(_ source: String) -> PublicSuffixList {
        var version = "unknown"
        var exactRules = Set<String>()
        var wildcardRules = Set<String>()
        var exceptionRules = Set<String>()

        source.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("// VERSION:") {
                version = line.dropFirst("// VERSION:".count)
                    .trimmingCharacters(in: .whitespaces)
                return
            }
            guard !line.isEmpty, !line.hasPrefix("//") else { return }

            if line.hasPrefix("!") {
                let rule = normalizedHost(String(line.dropFirst()))
                if !rule.isEmpty { exceptionRules.insert(rule) }
            } else if line.hasPrefix("*.") {
                let rule = normalizedHost(String(line.dropFirst(2)))
                if !rule.isEmpty { wildcardRules.insert(rule) }
            } else {
                let rule = normalizedHost(line)
                if !rule.isEmpty { exactRules.insert(rule) }
            }
        }
        return PublicSuffixList(
            version: version,
            exactRules: exactRules,
            wildcardRules: wildcardRules,
            exceptionRules: exceptionRules
        )
    }

    static func parseValidated(
        _ source: String,
        minimumRuleCount: Int = 1_000
    ) throws -> PublicSuffixList {
        let parsed = parse(source)
        guard parsed.version != "unknown", parsed.version != "unavailable" else {
            throw PublicSuffixListError.missingVersion
        }
        let totalRuleCount = parsed.exactRules.count
            + parsed.wildcardRules.count
            + parsed.exceptionRules.count
        guard totalRuleCount >= minimumRuleCount else {
            throw PublicSuffixListError.insufficientRules(
                expected: minimumRuleCount,
                actual: totalRuleCount
            )
        }
        return parsed
    }

    static func selectCurrent(contents: String) throws {
        let parsed = try parseValidated(contents)
        currentLock.withLock {
            selectedList = parsed
        }
    }

    static func resetCurrentToBundled() {
        currentLock.withLock {
            selectedList = nil
        }
    }

    private static func loadBundledList() -> PublicSuffixList {
#if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
#else
        let resourceBundle = Bundle.main
#endif
        let resourceURL = resourceBundle.url(
            forResource: "public_suffix_list",
            withExtension: "dat",
            subdirectory: "Privacy"
        ) ?? resourceBundle.url(
            forResource: "public_suffix_list",
            withExtension: "dat"
        )
        guard let resourceURL,
              let source = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return PublicSuffixList(
                version: "unavailable",
                exactRules: [],
                wildcardRules: [],
                exceptionRules: []
            )
        }
        return parse(source)
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        var host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return "" }

        // URL normalizes Unicode domain labels to the ASCII form used by
        // Foundation URL.host and Chromium's request URLs.
        if !host.contains(":"),
           let normalized = URL(string: "https://\(host)")?.host?.lowercased() {
            return normalized
        }
        return host
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.allSatisfy { component in
            guard let value = Int(component) else { return false }
            return (0...255).contains(value) && String(value) == component
        }
    }
}

enum PublicSuffixListError: Error, Equatable {
    case missingVersion
    case insufficientRules(expected: Int, actual: Int)
}
