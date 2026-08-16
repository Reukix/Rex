import Foundation

#if !arch(arm64)
#error("Rex supports Apple Silicon (arm64) only.")
#endif

enum AppVersion {
    static let releaseVersion = "0.9.9"
    static let buildNumber = 995
    static let chromiumVersion: String? = "151.0.7922.138"
    static let cefVersion = "151.3.18+gbeff58d+chromium-151.0.7922.138"
    static let supportedArchitecture = "arm64"
}
