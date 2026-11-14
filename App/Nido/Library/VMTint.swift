// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI

/// A VM's tint: the colour of its system mark in the library, its window and its settings
/// (design tokens vm<Tint> and vm<Tint>Fill). Low chroma, away from the accent and the status
/// colours: it tells VMs apart, never a state.
enum VMTint: String, CaseIterable, Identifiable, Sendable {
    case slate, indigo, plum, rose, clay, olive, sea, graphite

    var id: String { rawValue }

    /// The mark (logo or letter) and the swatch.
    var mark: SwiftUI.Color {
        switch self {
        case .slate: Theme.Color.vmSlate
        case .indigo: Theme.Color.vmIndigo
        case .plum: Theme.Color.vmPlum
        case .rose: Theme.Color.vmRose
        case .clay: Theme.Color.vmClay
        case .olive: Theme.Color.vmOlive
        case .sea: Theme.Color.vmSea
        case .graphite: Theme.Color.vmGraphite
        }
    }

    /// The tile under the mark.
    var fill: SwiftUI.Color {
        switch self {
        case .slate: Theme.Color.vmSlateFill
        case .indigo: Theme.Color.vmIndigoFill
        case .plum: Theme.Color.vmPlumFill
        case .rose: Theme.Color.vmRoseFill
        case .clay: Theme.Color.vmClayFill
        case .olive: Theme.Color.vmOliveFill
        case .sea: Theme.Color.vmSeaFill
        case .graphite: Theme.Color.vmGraphiteFill
        }
    }

    /// The tint's name, for VoiceOver and the swatch's help tag.
    var title: String {
        switch self {
        case .slate: String(localized: "Slate", comment: "A VM color.")
        case .indigo: String(localized: "Indigo", comment: "A VM color.")
        case .plum: String(localized: "Plum", comment: "A VM color.")
        case .rose: String(localized: "Rose", comment: "A VM color.")
        case .clay: String(localized: "Clay", comment: "A VM color.")
        case .olive: String(localized: "Olive", comment: "A VM color.")
        case .sea: String(localized: "Sea", comment: "A VM color.")
        case .graphite: String(localized: "Graphite", comment: "A VM color.")
        }
    }

    /// The tint of a VM nobody chose one for: FNV-1a (32 bits) of its name, as
    /// `designTint(for:)` in scripts/design/Logos.swift, so the mocks show the app's colours.
    static func `default`(for name: String) -> VMTint {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return allCases[Int(hash % UInt32(allCases.count))]
    }
}

/// The tints chosen for VMs, by name (a VM is never renamed), in the app's defaults: the
/// library, the VM windows and the settings read the same store. Deleting a VM forgets its tint.
@MainActor
@Observable
final class VMTintStore {
    static let key = "NidoVMTints"

    @ObservationIgnored private let defaults: UserDefaults
    private var chosen: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosen = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func tint(for name: String) -> VMTint {
        chosen[name].flatMap(VMTint.init(rawValue:)) ?? .default(for: name)
    }

    func set(_ tint: VMTint, for name: String) {
        chosen[name] = tint.rawValue
        defaults.set(chosen, forKey: Self.key)
    }

    func remove(_ name: String) {
        guard chosen.removeValue(forKey: name) != nil else { return }
        defaults.set(chosen, forKey: Self.key)
    }

    /// The tint the wizard proposes for `name`: the first one none of `existing` has, else the
    /// name's own.
    func freshTint(for name: String, among existing: [String]) -> VMTint {
        let used = Set(existing.map(tint(for:)))
        return VMTint.allCases.first { !used.contains($0) } ?? .default(for: name)
    }
}
