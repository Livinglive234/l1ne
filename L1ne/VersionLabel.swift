import Foundation

/// How the version is shown in Settings: "0.1.0-beta.9" reads as "0.1.0 beta 9".
enum VersionLabel {
    static func pretty(_ version: String) -> String {
        let parts = version.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return version }
        return parts[0] + " " + parts[1].split(separator: ".").joined(separator: " ")
    }
}
