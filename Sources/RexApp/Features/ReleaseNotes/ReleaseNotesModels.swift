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

enum FeatureStatus: String, Decodable, Sendable {
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
    var id: String { version }
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
}
