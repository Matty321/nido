// Generato da scripts/gen-theme.swift: non modificare
// SPDX-License-Identifier: Apache-2.0
//
// Source: design/tokens.json, the FigCraft variables exported by scripts/design-build.sh.

import AppKit
import SwiftUI

/// Nido design tokens. Views use these values (and the `Nido*` components) only.
enum Theme {
    enum Color {
        static let accent = SwiftUI.Color(light: 0x1D6F64, dark: 0x4DB6A4)
        static let accentText = SwiftUI.Color(light: 0xFFFFFF, dark: 0x0B1F1B)
        static let background = SwiftUI.Color(light: 0xF3F1EC, dark: 0x151817)
        static let border = SwiftUI.Color(light: 0xD9D4C8, dark: 0x3A403D)
        static let scrim = SwiftUI.Color(light: 0x000000, alpha: 0x33, dark: 0x000000, alpha: 0x8C)
        static let statusError = SwiftUI.Color(light: 0xB42B22, dark: 0xF07A6E)
        static let statusPaused = SwiftUI.Color(light: 0x9A6512, dark: 0xE2AA4C)
        static let statusRunning = SwiftUI.Color(light: 0x2F7D4E, dark: 0x5CC98A)
        static let statusStopped = SwiftUI.Color(light: 0x6B6F69, dark: 0x9A9E97)
        static let surface = SwiftUI.Color(light: 0xFBFAF7, dark: 0x1D2120)
        static let surfaceRaised = SwiftUI.Color(light: 0xFFFFFF, dark: 0x262B29)
        static let textPrimary = SwiftUI.Color(light: 0x1E2320, dark: 0xECEAE4)
        static let textSecondary = SwiftUI.Color(light: 0x5B605A, dark: 0xA6AAA3)
        static let vmClay = SwiftUI.Color(light: 0x814F39, dark: 0xE6B098)
        static let vmClayFill = SwiftUI.Color(light: 0xF8E5DD, dark: 0x443027)
        static let vmGraphite = SwiftUI.Color(light: 0x5F5D59, dark: 0xBFBEB8)
        static let vmGraphiteFill = SwiftUI.Color(light: 0xEAE9E7, dark: 0x363533)
        static let vmIndigo = SwiftUI.Color(light: 0x55588A, dark: 0xB4B9EF)
        static let vmIndigoFill = SwiftUI.Color(light: 0xE6E8FB, dark: 0x323348)
        static let vmOlive = SwiftUI.Color(light: 0x606134, dark: 0xC0C294)
        static let vmOliveFill = SwiftUI.Color(light: 0xEAEBDB, dark: 0x363725)
        static let vmPlum = SwiftUI.Color(light: 0x734F75, dark: 0xD6AED7)
        static let vmPlumFill = SwiftUI.Color(light: 0xF2E4F3, dark: 0x3E2F3F)
        static let vmRose = SwiftUI.Color(light: 0x814A60, dark: 0xE6AAC0)
        static let vmRoseFill = SwiftUI.Color(light: 0xF9E3EA, dark: 0x442E36)
        static let vmSea = SwiftUI.Color(light: 0x316673, dark: 0x94C8D5)
        static let vmSeaFill = SwiftUI.Color(light: 0xDCEDF2, dark: 0x25393E)
        static let vmSlate = SwiftUI.Color(light: 0x376285, dark: 0x97C3E9)
        static let vmSlateFill = SwiftUI.Color(light: 0xDDECF9, dark: 0x273746)
    }

    enum Radius {
        static let l: CGFloat = 14
        static let m: CGFloat = 10
        static let s: CGFloat = 6
    }

    enum Space {
        static let l: CGFloat = 16
        static let m: CGFloat = 12
        static let s: CGFloat = 8
        static let xl: CGFloat = 24
        static let xs: CGFloat = 4
        static let xxl: CGFloat = 32
    }

    enum TypeSize {
        static let body: CGFloat = 13
        static let caption: CGFloat = 11
        static let headline: CGFloat = 15
        static let title: CGFloat = 22
    }
}

extension SwiftUI.Color {
    /// A color that follows the effective appearance: `light` in Aqua, `dark` in Dark Aqua.
    /// Components are sRGB `0xRRGGBB`.
    init(light: UInt32, dark: UInt32) {
        self.init(light: light, alpha: 0xFF, dark: dark, alpha: 0xFF)
    }

    /// Same as `init(light:dark:)` with an alpha (`0x00`–`0xFF`) per appearance.
    init(light: UInt32, alpha lightAlpha: UInt32, dark: UInt32, alpha darkAlpha: UInt32) {
        let provider: @Sendable (NSAppearance) -> NSColor = { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(themeHex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
        self.init(nsColor: NSColor(name: nil, dynamicProvider: provider))
    }
}

private extension NSColor {
    convenience init(themeHex hex: UInt32, alpha: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha & 0xFF) / 255
        )
    }
}
