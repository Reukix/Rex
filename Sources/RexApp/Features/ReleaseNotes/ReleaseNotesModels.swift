import Foundation

struct FeatureCatalog: Decodable, Sendable {
    let lastUpdatedVersion: String
    let categories: [FeatureCategory]
}

struct FeatureCategory: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    let features: [FeatureRecord]
}

struct FeatureRecord: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    let status: FeatureStatus
    let testStatus: String
    let introducedIn: String
    let updatedIn: String
    let description: String
    let supportsPrivateWindow: Bool
    let supportsSplitView: Bool
    let supportsKeyboard: Bool
    let requiresRestart: Bool
    let settingsPath: String
    let limitations: [String]
}

enum FeatureStatus: String, CaseIterable, Decodable, Equatable, Sendable {
    case completed, testing, inProgress, planned, paused, limited, removed

    var label: String {
        switch self {
        case .completed: "已完成"
        case .testing: "测试中"
        case .inProgress: "开发中"
        case .planned: "已规划"
        case .paused: "已暂停"
        case .limited: "存在限制"
        case .removed: "已移除"
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .testing: "testtube.2"
        case .inProgress: "hammer.fill"
        case .planned: "list.bullet.clipboard"
        case .paused: "pause.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .removed: "xmark.circle.fill"
        }
    }
}

struct ReleaseCatalog: Decodable, Sendable {
    let releases: [ReleaseRecord]
}

struct ReleaseRecord: Identifiable, Decodable, Sendable {
    var id: String { "\(version)-build-\(build)" }
    let version: String
    let build: Int
    let date: String
    let channel: String
    let summary: String
    let added: [String]
    let improved: [String]
    let fixed: [String]
    let changed: [String]
    let removed: [String]
    let knownIssues: [String]
    let inProgress: [String]
}

extension ReleaseRecord {
    private enum CodingKeys: String, CodingKey {
        case version, build, date, channel, summary
        case added, improved, fixed, changed, removed, knownIssues, inProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decode(Int.self, forKey: .build)
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        channel = try container.decodeIfPresent(String.self, forKey: .channel) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        added = try container.decodeIfPresent([String].self, forKey: .added) ?? []
        improved = try container.decodeIfPresent([String].self, forKey: .improved) ?? []
        fixed = try container.decodeIfPresent([String].self, forKey: .fixed) ?? []
        changed = try container.decodeIfPresent([String].self, forKey: .changed) ?? []
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
        knownIssues = try container.decodeIfPresent([String].self, forKey: .knownIssues) ?? []
        inProgress = try container.decodeIfPresent([String].self, forKey: .inProgress) ?? []
    }
}

struct RexAboutInformation: Equatable, Sendable {
    struct CapabilityGroup: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let featureNames: [String]
        let statusSummary: String
    }

    let version: String
    let build: Int
    let chromiumVersion: String?
    let cefVersion: String
    let architecture: String
    let channel: String
    let featureCatalogVersion: String
    let capabilityGroups: [CapabilityGroup]
    let knownLimitations: [String]

    var channelDisplayName: String {
        Self.channelDisplayName(channel)
    }

    static func channelDisplayName(_ channel: String) -> String {
        switch channel.lowercased() {
        case "stable", "release": "稳定"
        case "beta": "Beta"
        case "alpha": "Alpha"
        case "development", "dev", "nightly": "开发"
        default: channel.isEmpty ? "未知" : channel
        }
    }

    static func make(
        version: String,
        build: Int,
        chromiumVersion: String?,
        cefVersion: String,
        architecture: String,
        features: FeatureCatalog,
        releases: ReleaseCatalog
    ) -> RexAboutInformation {
        let currentRelease = releases.release(version: version, build: build)
        let groups = features.categories.map { category in
            let activeFeatures = category.features.filter { $0.status != .removed }
            let statuses = FeatureStatus.allCases.compactMap { status -> String? in
                let count = activeFeatures.lazy.filter { $0.status == status }.count
                return count == 0 ? nil : "\(count) \(status.label)"
            }
            return CapabilityGroup(
                id: category.id,
                name: category.name,
                featureNames: activeFeatures.map(\.name),
                statusSummary: statuses.joined(separator: " · ")
            )
        }
        .filter { !$0.featureNames.isEmpty }

        return RexAboutInformation(
            version: version,
            build: build,
            chromiumVersion: chromiumVersion,
            cefVersion: cefVersion,
            architecture: architecture,
            channel: currentRelease?.channel ?? "",
            featureCatalogVersion: features.lastUpdatedVersion,
            capabilityGroups: groups,
            knownLimitations: currentRelease?.knownIssues ?? []
        )
    }
}

extension ReleaseCatalog {
    func release(version: String, build: Int) -> ReleaseRecord? {
        releases.first { $0.version == version && $0.build == build }
    }
}

enum ReleaseNotesService {
    static func load() throws -> (FeatureCatalog, ReleaseCatalog) {
        let decoder = JSONDecoder()
#if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
#else
        let resourceBundle = Bundle.main
#endif
        guard let featuresURL = resourceBundle.url(forResource: "features", withExtension: "json", subdirectory: "ReleaseNotes")
                ?? resourceBundle.url(forResource: "features", withExtension: "json"),
              let releasesURL = resourceBundle.url(forResource: "releases", withExtension: "json", subdirectory: "ReleaseNotes")
                ?? resourceBundle.url(forResource: "releases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (
            try decoder.decode(FeatureCatalog.self, from: Data(contentsOf: featuresURL)),
            try decoder.decode(ReleaseCatalog.self, from: Data(contentsOf: releasesURL))
        )
    }

    static func loadAboutInformation() throws -> RexAboutInformation {
        let (features, releases) = try load()
        return RexAboutInformation.make(
            version: AppVersion.releaseVersion,
            build: AppVersion.buildNumber,
            chromiumVersion: AppVersion.chromiumVersion,
            cefVersion: AppVersion.cefVersion,
            architecture: AppVersion.supportedArchitecture,
            features: features,
            releases: releases
        )
    }
}
