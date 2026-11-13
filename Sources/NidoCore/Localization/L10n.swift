// SPDX-License-Identifier: Apache-2.0
//
// Where NidoCore's string catalog lives at run time (checked 2026-11-12, Swift 6.4.2 / Xcode 27.2):
// - Command-line SwiftPM compiles Resources/Localizable.xcstrings: `swift build` writes
//   .build/debug/Nido_NidoCore.bundle (a link into .build/out/Products/Debug) with
//   Contents/Resources/{en,it,de,es,fr}.lproj/Localizable.strings. Run from .build/debug, `nido` finds it
//   in its own directory; a `nido` copied anywhere else without it gets the English keys, no crash.
// - `swift test`: Bundle.main is swiftpm-testing-helper inside the toolchain, so neither Bundle.main nor
//   the executable's directory holds the catalog; it sits beside the test bundle that links NidoCore
//   (.build/out/Products/Debug/NidoCoreTests.xctest), found through `Bundle(for:)` on a NidoCore class.
// - The app: Xcode copies the package's resource bundle to Nido.app/Contents/Resources/Nido_NidoCore.bundle
//   (Bundle.main.resourceURL), in Debug and in Release.
// - The CLI in Nido.app/Contents/Helpers/nido (also reached through the ~/.local/bin/nido symlink) finds
//   the app's copy through <executable dir>/../Resources once the symlink is resolved, so
//   scripts/build-app.sh does not copy the bundle a second time; `codesign --verify --deep --strict`
//   on the signed app still passes.
// `Bundle.module` is never used: its accessor traps when the bundle is missing (e.g. a CLI copied
// elsewhere); without the catalog every lookup returns the English key text instead.
import Foundation
import Synchronization

/// NidoCore's user-facing text in the resolved UI language: English (the keys), Italian, German,
/// Spanish or French.
public enum L10n {
    /// The languages Nido ships, the base language first.
    static let supported = ["en", "it", "de", "es", "fr"]

    /// The resolved UI language code, one of `en it de es fr`: the pinned language if any, else
    /// `NIDO_LANGUAGE`, else the system's preferred languages, else English.
    public static var language: String {
        if let pinned { return normalized(pinned) }
        return systemLanguage
    }

    /// The locale for dates and numbers, matching `language`.
    public static var locale: Locale { locale(for: language) }

    /// `key` from NidoCore's catalog in the resolved language; a key the catalog lacks comes back as
    /// its English text.
    public static func string(_ key: String.LocalizationValue) -> String {
        string(key, language: language)
    }

    /// Forces a language (nil = back to the system choice). Process-wide: tests that only need one
    /// language's text use `string(_:language:)` instead.
    @_spi(Testing) public static func pin(_ language: String?) {
        pinState.withLock { $0 = language }
    }

    /// `key` in `language` (anything outside the five falls back to English), without touching the pin.
    @_spi(Testing) public static func string(_ key: String.LocalizationValue, language: String) -> String {
        let code = normalized(language)
        return String(localized: key, bundle: languageBundles[code] ?? catalogBundle, locale: locale(for: code))
    }

    /// The locale for `language` (anything outside the five falls back to English), with the system's
    /// region when there is one: an English UI in Italy still formats numbers as "1,5". `region` is
    /// injectable for tests.
    @_spi(Testing) public static func locale(
        for language: String,
        region: String? = Locale.current.region?.identifier
    ) -> Locale {
        let code = normalized(language)
        guard let region, !region.isEmpty else { return Locale(identifier: code) }
        return Locale(identifier: "\(code)_\(region)")
    }

    /// The language Nido uses without a pin: `NIDO_LANGUAGE` if its language part (before `-` or `_`, any case) is one of the five, else the
    /// first of the five the preferred languages match, else English.
    static func resolve(env: [String: String], preferred: [String]) -> String {
        if let requested = env["NIDO_LANGUAGE"] {
            // "de_DE", "fr-CA" and "DE" name their language too.
            let code = requested.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let code, supported.contains(code) { return code }
        }
        let match = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first
        if let match, supported.contains(match) {
            return match
        }
        return "en"
    }

    /// The pinned language, if any (as passed to `pin`).
    static var pinned: String? { pinState.withLock { $0 } }

    private static let pinState = Mutex<String?>(nil)

    private static let systemLanguage = resolve(
        env: ProcessInfo.processInfo.environment,
        preferred: Locale.preferredLanguages
    )

    private static func normalized(_ language: String) -> String {
        supported.contains(language) ? language : "en"
    }

    /// NidoCore's resource bundle: the first that exists of the app's Resources, the executable's
    /// directory, the executable's ../Resources (the CLI inside Nido.app) and the directory holding
    /// the code that links NidoCore (`swift test`); else Bundle.main, where NidoCore's keys come back
    /// as their English text.
    static let catalogBundle: Bundle = {
        let name = "Nido_NidoCore.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: name))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appending(path: name))
            candidates.append(directory.deletingLastPathComponent().appending(path: "Resources").appending(path: name))
        }
        candidates.append(Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appending(path: name))
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue,
               let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return Bundle.main
    }()

    /// One `<lang>.lproj` sub-bundle per language, so a lookup does not depend on the process's own
    /// language preferences.
    private static let languageBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for code in supported {
            if let path = catalogBundle.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                bundles[code] = bundle
            }
        }
        return bundles
    }()

    private final class BundleToken {}
}
