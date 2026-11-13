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
}
