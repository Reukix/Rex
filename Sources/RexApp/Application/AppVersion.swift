import Foundation

#if !arch(arm64)
#error("Rex supports Apple Silicon (arm64) only.")
#endif

enum AppVersion {
    static let releaseVersion = "0.9.7"
    static let buildNumber = 970
    static let chromiumVersion: String? = "150.0.7871.129"
    static let cefVersion = "150.0.14+g7c1aa68+chromium-150.0.7871.129"
    static let supportedArchitecture = "arm64"
}
