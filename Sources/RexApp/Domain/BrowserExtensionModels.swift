import AppKit
import Combine
import Foundation

struct BrowserExtensionPackage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var homepageURL: URL?
    var path: URL
    var isEnabled: Bool
    var permissions: [String]
    var runtimeStatus: RuntimeStatus
    var installedAt: Date
    var updatedAt: Date

    enum RuntimeStatus: String, Codable, Sendable, CaseIterable {
        case ready
        case pendingRuntime
        case invalidManifest
        case disabled

        var displayName: String {
            switch self {
            case .ready: "可管理"
            case .pendingRuntime: "待运行时支持"
            case .invalidManifest: "清单无效"
            case .disabled: "已禁用"
            }
        }
    }

    var permissionSummary: String {
        if permissions.isEmpty { return "无声明权限" }
        let head = permissions.prefix(4).joined(separator: " · ")
        return permissions.count > 4 ? "\(head) 等 \(permissions.count) 项" : head
    }
}

@MainActor
final class BrowserExtensionsStore: ObservableObject {
    static let shared = BrowserExtensionsStore()

    @Published private(set) var extensions: [BrowserExtensionPackage] = []
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let catalogURL: URL
    private let packagesDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("Rex/Extensions", isDirectory: true)
        packagesDirectoryURL = root.appendingPathComponent("Packages", isDirectory: true)
        catalogURL = root.appendingPathComponent("catalog.json", isDirectory: false)
        try? fileManager.createDirectory(at: packagesDirectoryURL, withIntermediateDirectories: true)
        load()
    }

    var enabledCount: Int {
        extensions.filter(\.isEnabled).count
    }

    func load() {
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            extensions = []
            return
        }
        do {
            let data = try Data(contentsOf: catalogURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([BrowserExtensionPackage].self, from: data)
            extensions = decoded.sorted { $0.updatedAt > $1.updatedAt }
            lastError = nil
        } catch {
            lastError = "无法读取扩展目录：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func installUnpacked(from sourceDirectory: URL) throws -> BrowserExtensionPackage {
        var isDirectory: ObjCBool = false
        guard sourceDirectory.isFileURL,
              fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExtensionStoreError.notADirectory
        }

        let manifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ExtensionStoreError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        guard let manifest else { throw ExtensionStoreError.invalidManifest }

        let name = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (manifest["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, let version, !version.isEmpty else {
            throw ExtensionStoreError.invalidManifest
        }

        let description = (manifest["description"] as? String) ?? ""
        let author = manifest["author"] as? String
        let homepage = (manifest["homepage_url"] as? String).flatMap(URL.init(string:))
        let permissions = Self.extractPermissions(from: manifest)
        let packageID = (manifest["key"] as? String)
            ?? "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(version)"

        let destination = packagesDirectoryURL.appendingPathComponent(packageID, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceDirectory, to: destination)

        let now = Date()
        let package = BrowserExtensionPackage(
            id: packageID,
            name: name,
            version: version,
            description: description,
            author: author,
            homepageURL: homepage,
            path: destination,
            isEnabled: true,
            permissions: permissions,
            // Current CEF minimal build has no public LoadExtension API.
            runtimeStatus: .pendingRuntime,
            installedAt: extensions.first(where: { $0.id == packageID })?.installedAt ?? now,
            updatedAt: now
        )

        if let index = extensions.firstIndex(where: { $0.id == packageID }) {
            extensions[index] = package
        } else {
            extensions.insert(package, at: 0)
        }
        try persist()
        lastError = nil
        return package
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].isEnabled = enabled
        extensions[index].runtimeStatus = enabled ? .pendingRuntime : .disabled
        extensions[index].updatedAt = .now
        try? persist()
    }

    func remove(_ id: String) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        let package = extensions.remove(at: index)
        try? fileManager.removeItem(at: package.path)
        try? persist()
    }

    func revealInFinder(_ id: String) {
        guard let package = extensions.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([package.path])
    }

    func openPackagesDirectory() {
        try? fileManager.createDirectory(at: packagesDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(packagesDirectoryURL)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(extensions)
        try data.write(to: catalogURL, options: .atomic)
    }

    private static func extractPermissions(from manifest: [String: Any]) -> [String] {
        var values: [String] = []
        if let permissions = manifest["permissions"] as? [String] {
            values.append(contentsOf: permissions)
        }
        if let optional = manifest["optional_permissions"] as? [String] {
            values.append(contentsOf: optional.map { "optional:\($0)" })
        }
        if let host = manifest["host_permissions"] as? [String] {
            values.append(contentsOf: host)
        }
        return values
    }
}

enum ExtensionStoreError: LocalizedError {
    case notADirectory
    case missingManifest
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .notADirectory: "请选择包含 Chrome 扩展文件的文件夹。"
        case .missingManifest: "未找到 manifest.json，这不是有效的未打包扩展。"
        case .invalidManifest: "manifest.json 无法解析，或缺少 name/version。"
        }
    }
}
