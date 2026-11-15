// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

// MARK: - nido image: the cached catalog images and their new builds

extension CLISupport {
    /// The catalog image with id `id`, or `CLIError.unknownImage`.
    public static func catalogImage(id: String) throws -> CloudImage {
        guard let image = CloudImageCatalog.image(id: id) else { throw CLIError.unknownImage(id) }
        return image
    }

    /// `nido image list`: one row per catalog image, from the cache alone (no network).
    public static func imageListLines(_ images: [(image: CloudImage, cached: Bool)]) -> [String] {
        let header = ["ID", L10n.string("SYSTEM"), L10n.string("CACHE")]
        let rows = images.map { entry in
            [entry.image.id, entry.image.distribution.displayName,
             entry.cached ? L10n.string("downloaded") : L10n.string("no")]
        }
        return formatTable([header] + rows).components(separatedBy: "\n")
    }

    /// `nido image check`: what the comparison with the published checksum list found, with the
    /// Debian build the list was checked against (`ImageStore.acceptedBuild`) when there is one.
    public static func imageStatusLine(_ image: CloudImage, status: ImageUpdateStatus, build: String? = nil) -> String {
        switch status {
        case .notCached:
            L10n.string("\(image.id): not downloaded (the next VM downloads the current build)")
        case .current:
            build.map { L10n.string("\(image.id): up to date (build \($0))") } ?? L10n.string("\(image.id): up to date")
        case .updateAvailable:
            build.map { L10n.string("\(image.id): new build \($0) available (nido image update \(image.id))") }
                ?? L10n.string("\(image.id): new build available (nido image update \(image.id))")
        }
    }

    /// `nido image update`: after the download, or when there was nothing to do.
    public static func imageUpdateMessage(_ image: CloudImage, status: ImageUpdateStatus, build: String? = nil) -> String {
        switch status {
        case .current:
            L10n.string("\(image.id): already up to date, nothing to download.")
        case .notCached, .updateAvailable:
            build.map { L10n.string("\(image.id): downloaded and verified the current build (\($0)). Existing VMs don’t change.") }
                ?? L10n.string("\(image.id): downloaded and verified the current build. Existing VMs don’t change.")
        }
    }

    /// `nido image reset`: what was forgotten (`ImageStore.forgetAccepted`).
    public static func imageResetMessage(_ image: CloudImage, removed: Int) -> String {
        removed == 0
            ? L10n.string("\(image.id): no accepted build or signature to forget.")
            : L10n.string("\(image.id): forgot the accepted build and signature. The next check accepts the published list as if for the first time; the image in the cache stays.")
    }

    // MARK: - nido image macos: the macOS image Apple offers, on request

    /// `nido image macos`: what Apple offers. `size` is nil while it is not known.
    public static func macImageOfferLine(_ offer: MacImageOffer, size: UInt64?) -> String {
        L10n.string("macOS \(offer.version) (\(offer.build)) — \(macImageSizeText(size)), from Apple")
    }

    /// The size of the image, or "size unknown".
    public static func macImageSizeText(_ size: UInt64?) -> String {
        size.map { ByteSize.format($0) } ?? L10n.string("size unknown")
    }

    /// What the cache holds of the offer: nothing (nil), a complete file at `path`, or `partial`
    /// bytes of it that the same download resumes.
    public static func macImageStateLine(path: String, complete: Bool, partial: Int64) -> String? {
        if complete { return L10n.string("Already downloaded: \(ConsoleSanitizer.echoable(path))") }
        guard partial > 0 else { return nil }
        return L10n.string("Partial download: \(ByteSize.format(UInt64(partial))) already in \(ConsoleSanitizer.echoable(path)); nido image macos --download resumes it.")
    }

    /// The `nido image macos` hint when there is nothing to resume or use yet.
    public static func macImageDownloadHint() -> String {
        L10n.string("Download it with: nido image macos --download")
    }

    /// The question before the download (`[y/N]`, default no).
    public static func macImageDownloadQuestion(_ offer: MacImageOffer, size: UInt64?) -> String {
        L10n.string("Download macOS \(offer.version) (\(macImageSizeText(size))) from Apple? [y/N] ")
    }

    /// The last lines of a finished download: where the file is and how to use it.
    public static func macImageDownloadedLines(path: String) -> [String] {
        [L10n.string("macOS downloaded and checked: \(ConsoleSanitizer.echoable(path))"),
         L10n.string("Use it with: nido create <name> --ipsw \(shellWord(path))")]
    }

    /// `path` as one shell word: bare when it has only safe characters, else single-quoted.
    static func shellWord(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + ConsoleSanitizer.echoable(path).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What Ctrl-C or a lost connection leaves: the partial file, resumed by the same command.
    public static func macImagePausedMessage() -> String {
        L10n.string("Download paused: run the same command to resume.")
    }

    /// `--output` and `--yes` belong to `--download`.
    public static func validateMacImageOptions(download: Bool, hasOutput: Bool, yes: Bool) throws {
        guard !download else { return }
        if hasOutput { throw CLIError.macImageOptionNeedsDownload("--output") }
        if yes { throw CLIError.macImageOptionNeedsDownload("--yes") }
    }

    /// What a failed download prints, from the partial file it left (`partial` bytes in the
    /// macOS cache, 0 when there is none): the error, and the way to resume only when something
    /// is there to resume. Nil when there is nothing to add to the error itself.
    public static func macImageFailureLines(error: any Error, partial: Int64) -> [String]? {
        guard partial > 0 else { return nil }
        return [L10n.string("Error: \(message(for: error))"), macImagePausedMessage()]
    }

    /// A file in the macOS cache that is not part of the offer (an old build, a partial file of
    /// another download): one line, so the user can find it and remove it.
    public static func macImageOtherFileLine(path: String, bytes: UInt64) -> String {
        L10n.string("Also in the macOS cache: \(ConsoleSanitizer.echoable(path)) (\(ByteSize.format(bytes)))")
    }
}
