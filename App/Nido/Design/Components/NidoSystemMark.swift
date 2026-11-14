// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Logos.swift SystemMark: a VM's system on a tile. Debian shows its swirl (the Debian Open Use
/// Logo, Assets.xcassets/DebianLogo), macOS the system symbol `apple.logo`; Ubuntu and Windows keep
/// their letter, as their logos need their owners' permission; an unreadable VM shows "?".
struct NidoSystemMark: View {
    enum System: Equatable {
        case debian, ubuntu, macos, windows, unknown

        /// The letter the cards and tiles have always carried ("D", "U", "M", "W", "?").
        init(glyph: String) {
            switch glyph {
            case "D": self = .debian
            case "U": self = .ubuntu
            case "M": self = .macos
            case "W": self = .windows
            default: self = .unknown
            }
        }

        var letter: String {
            switch self {
            case .debian: "D"
            case .ubuntu: "U"
            case .macos: "M"
            case .windows: "W"
            case .unknown: "?"
            }
        }
    }

    let system: System
    let size: CGFloat
    let fill: SwiftUI.Color
    let mark: SwiftUI.Color

    /// A VM's mark, on its tint.
    init(system: System, tint: VMTint, size: CGFloat) {
        self.init(system: system, size: size, fill: tint.fill, mark: tint.mark)
    }

    init(system: System, size: CGFloat, fill: SwiftUI.Color, mark: SwiftUI.Color) {
        self.system = system
        self.size = size
        self.fill = fill
        self.mark = mark
    }

    var body: some View {
        content
            .foregroundStyle(mark)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size >= Theme.Layout.osTileGlyph ? Theme.Radius.m : Theme.Radius.s))
            // The system is in the text next to the mark: VoiceOver reads it there.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch system {
        case .debian:
            Image("DebianLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: (size * 0.6).rounded())
        case .macos:
            Image(systemName: "apple.logo")
                .font(.system(size: (size * 0.5).rounded(), weight: .medium))
        default:
            Text(verbatim: system.letter)
                .font(.nido(size >= Theme.Layout.osTileGlyph ? Theme.TypeSize.title : Theme.TypeSize.headline, .bold))
        }
    }
}

/// Screens.swift ColorRow: a VM's tint among the eight, the chosen one ringed. The choice applies
/// at once (no Save): it only changes how Nido shows the VM.
struct NidoColorRow: View {
    @Binding var selection: VMTint
    let note: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Color")
                    .font(.nido(Theme.TypeSize.body, .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(note)
                    .font(.nido(Theme.TypeSize.caption))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.xs) {
                ForEach(VMTint.allCases) { tint in swatch(tint) }
            }
        }
        .nidoRow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("color-row")
    }

    private func swatch(_ tint: VMTint) -> some View {
        let isSelected = tint == selection
        return Button { selection = tint } label: {
            Circle()
                .fill(tint.mark)
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(isSelected ? Theme.Color.accent : .clear, lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tint.title)
        .accessibilityLabel(Text(verbatim: tint.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("color-\(tint.rawValue)")
    }
}
