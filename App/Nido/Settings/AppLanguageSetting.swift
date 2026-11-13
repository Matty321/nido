// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Settings › General › Language: the language of Nido alone, the same setting System Settings
/// writes for one app (Language & Region › Applications): `AppleLanguages` in Nido's own defaults
/// domain, never the global one. It applies from the next launch: the app relaunches itself.
struct AppLanguageSetting {
    /// The app's languages, English first (the development language).
    static let languages = ["en", "it", "de", "es", "fr"]

    private static let key = "AppleLanguages"

    let defaults: UserDefaults
    /// The domain `defaults` writes to: the bundle identifier for `.standard`, the suite name otherwise.
    let domain: String

    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "io.gitlab.pichierri.Nido") {
        self.defaults = defaults
        self.domain = domain
    }

    /// The chosen language, nil to follow the system. Read from the domain itself: `defaults` would
    /// also see the global list and the launch arguments (`-AppleLanguages (it)` in the UI tests).
    var choice: String? {
        get {
            guard let first = (defaults.persistentDomain(forName: domain)?[Self.key] as? [String])?.first else { return nil }
            // "it-IT" or "it_IT" is Italian.
            let language = String(first.prefix { $0 != "-" && $0 != "_" })
            return Self.languages.contains(language) ? language : nil
        }
        nonmutating set {
            if let newValue {
                defaults.set([newValue], forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Each language named in itself, as in System Settings: never translated.
    static func name(_ language: String) -> String {
        switch language {
        case "en": "English"
        case "it": "Italiano"
        case "de": "Deutsch"
        case "es": "Español"
        case "fr": "Français"
        default: language
        }
    }
}

/// Opens Nido again once this process has ended: a small `sh` that outlives the app.
enum Relauncher {
    /// `sh` arguments: wait while `pid` exists, then `open` the app.
    static func arguments(pid: Int32, app: URL, open: String = "/usr/bin/open") -> [String] {
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec \"$2\" \"$3\"",
         "nido-relaunch", String(pid), open, app.path]
    }

    /// Starts the helper for this process and this app bundle.
    static func start() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier, app: Bundle.main.bundleURL)
        try helper.run()
    }
}
