import Foundation

#if !arch(arm64)
#error("Rex supports Apple Silicon (arm64) only.")
#endif

enum AppVersion {
    static let releaseVersion = "1.0.0"
    static let buildNumber = 1001
    static let chromiumVersion: String? = "151.0.7922.138"
    static let cefVersion = "151.3.18+gbeff58d+chromium-151.0.7922.138"
    static let supportedArchitecture = "arm64"
}
