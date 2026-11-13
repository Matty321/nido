// SPDX-License-Identifier: Apache-2.0

/// The version of Nido, shared by the app (`MARKETING_VERSION`, checked by a test) and the `nido`
/// command (`nido --version`). Each version has its section in CHANGELOG.md.
public enum NidoVersion {
    public static let current = "0.8.0"

    /// The build number (`CFBundleVersion`): `major*10000 + minor*100 + patch`, so it grows with
    /// the version and Sparkle can compare releases. 0.7.6 is 706, 0.8.0 is 800.
    public static var build: Int { build(for: current) ?? 0 }

    /// The build number of an `x.y.z` version, or nil when it is not that shape or when the minor
    /// or the patch is 100 or more (they would overlap the next digit group).
    public static func build(for version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil
        }
        guard numbers.count == 3, numbers[1] < 100, numbers[2] < 100 else { return nil }
        return numbers[0] * 10000 + numbers[1] * 100 + numbers[2]
    }
}
