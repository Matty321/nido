// SPDX-License-Identifier: Apache-2.0
//
// Fixed dimensions of the Nido windows and components. They are not FigCraft variables (the
// design binds colours, spacing, radii and type sizes; sizes are literal numbers in the
// generator), so they are not in design/tokens.json: each value here mirrors, by name, the number
// in scripts/design/Components.swift or scripts/design/Screens.swift. Keep both in sync.

import CoreGraphics
import SwiftUI

extension Theme {
    enum Layout {
        /// Screens.swift `windowWidth` / `windowHeight`: every screen is a 1100×720 window.
        static let windowWidth: CGFloat = 1100
        static let windowHeight: CGFloat = 720
        /// Smallest library window that still fits one column of cards.
        static let windowMinWidth: CGFloat = 640
        static let windowMinHeight: CGFloat = 420

        /// Screens.swift `toolbar`: the unified title bar and toolbar.
        static let toolbarHeight: CGFloat = 52
        /// Screens.swift `trafficLights`: three 12 pt dots, `Space.s` apart.
        static let trafficLightsWidth: CGFloat = 3 * 12 + 2 * Theme.Space.s
        /// Screens.swift `searchField`.
        static let searchFieldWidth: CGFloat = 200
        /// Screens.swift `libraryWindow`: cards are 340 pt wide in three columns at 1100 pt; below
        /// this width a column is dropped (1100 pt still fits three: 3 × 300 + 2 × 16 < 1052).
        static let cardMinWidth: CGFloat = 300

        /// Components.swift NidoButton.
        static let buttonHeight: CGFloat = 28
        /// Components.swift StatusBadge.
        static let badgeHeight: CGFloat = 20
        static let badgeDot: CGFloat = 8
        static let badgeHollowDotStroke: CGFloat = 1.5
        /// Components.swift VMCard: the system glyph.
        static let cardGlyph: CGFloat = 40
        /// Components.swift EmptyState.
        static let emptyStateWidth: CGFloat = 480
        static let emptyStateNest: CGFloat = 64
        static let emptyStateNestStroke: CGFloat = 2
        static let emptyStateEgg: CGFloat = 24
        /// Components.swift ConfirmSheet.
        static let confirmSheetWidth: CGFloat = 440
        /// Components.swift WizardStep: the sheet and its step indicator.
        static let wizardWidth: CGFloat = 560
        static let wizardStepSegmentWidth: CGFloat = 32
        static let wizardStepSegmentHeight: CGFloat = 4
        /// Components.swift OSTile: the system glyph and the outline of the selected tile.
        static let osTileGlyph: CGFloat = 48
        static let selectedStroke: CGFloat = 2
        /// Components.swift ResourceStepper: the value field and the two arrows.
        static let stepperValueWidth: CGFloat = 72
        static let stepperHeight: CGFloat = 24
        static let stepperArrowWidth: CGFloat = 28
        /// Components.swift ToggleRow: the switch's track (corner radius = half its height) and knob.
        static let toggleTrackWidth: CGFloat = 40
        static let toggleTrackHeight: CGFloat = 24
        static let toggleKnob: CGFloat = 16
        /// Screens.swift `settingsWindow`: the sidebar, its rows and the form column.
        static let settingsSidebarWidth: CGFloat = 220
        static let settingsSidebarRowHeight: CGFloat = 28
        static let settingsFormWidth: CGFloat = 560
        /// Screens.swift `snapshotsWindow`: the column of S09.
        static let snapshotsColumnWidth: CGFloat = 720
        /// Components.swift SnapshotRow: the line under the name (fixed, so rows with and without
        /// the "con stato salvato" pill line up) and the pill.
        static let snapshotDetailsHeight: CGFloat = 20
        static let snapshotPillHeight: CGFloat = 18
        /// Components.swift ProgressPanel: the bar.
        static let progressBarHeight: CGFloat = 6
        /// The indeterminate bar (no design number: the render shows a fraction): the sweeping
        /// segment's share of the track and the duration of one sweep, in seconds.
        static let indeterminateSegment: CGFloat = 0.3
        static let indeterminatePeriod: Double = 1.4
        /// Screens.swift `vmWindow`: the title bar above the VMToolbar.
        static let titleBarHeight: CGFloat = 28
        /// Screens.swift `vmWindow` "paused": the framebuffer is dimmed under a 360 pt note.
        static let pauseNoteWidth: CGFloat = 360
        static let pausedDisplayOpacity: Double = 0.35
        /// Screens.swift `vmWindow` "paused": the note's top edge at y = 330 of the 720 pt window.
        /// Kept as a fraction of the window's height, so a full-screen or resized window puts it
        /// at the same relative place (exactly 330 pt at the design's size).
        static let pauseNoteTopFraction: CGFloat = 330 / windowHeight
        /// Screens.swift `sheetShadow`: #00000040, offset (0, 10), radius 28 (the pause note and
        /// the full-screen toolbar).
        static let sheetShadowOpacity: Double = 0x40 / 255
        static let sheetShadowY: CGFloat = 10
        static let sheetShadowRadius: CGFloat = 28
        static let sheetShadowColor = SwiftUI.Color(white: 0, opacity: sheetShadowOpacity)
        /// Components.swift: the hairline of every bordered component.
        static let hairline: CGFloat = 1
        /// Components.swift NidoButton "disabled".
        static let disabledOpacity: Double = 0.5
        /// Feedback while a NidoButton is held down (not in the static design).
        static let pressedOpacity: Double = 0.8
        /// Screens.swift `console`: 13 pt text (`TypeSize.body`) on 20 pt lines.
        static let consoleLineHeight: CGFloat = 20
        /// The console's cursor, an underline as the "_" of the design (not a design number).
        static let consoleCursorHeight: CGFloat = 2
        /// Gap between the text baseline and the cursor underline (not a design number).
        static let consoleCursorBaselineGap: CGFloat = 1
        /// The cursor while the console does not have the keyboard (not a design number).
        static let consoleCursorInactiveOpacity: Double = 0.5
        /// The accent behind the cells selected in the console (not a design number).
        static let consoleSelectionOpacity: Double = 0.4

        // MARK: M3c (ScreensAI.swift)

        /// ScreensAI.swift `vmTabs`: the views strip under the VMToolbar, its 2 pt underline.
        static let viewTabsHeight: CGFloat = 36
        static let viewTabUnderline: CGFloat = 2
        /// Components.swift `bridgePill`: "Ponte AI attivo".
        static let pillHeight: CGFloat = 20
        static let pillDot: CGFloat = 8
        /// ScreensAI.swift Avviso: the dot on the title's first line.
        static let noticeDot: CGFloat = 10
        static let noticeDotLineHeight: CGFloat = 18
        /// ScreensAI.swift PassoPreparazione: the row, its dot, the "in corso" ring and centre.
        static let stepRowHeight: CGFloat = 24
        static let stepDot: CGFloat = 10
        static let stepRing: CGFloat = 12
        static let stepRingStroke: CGFloat = 2
        static let stepRingCentre: CGFloat = 4
        static let stepWaitingStroke: CGFloat = 1.5
        /// ScreensAI.swift `provisioningScreen`: the floating panel, wider with the log.
        static let provisioningPanelWidth: CGFloat = 400
        static let provisioningPanelWideWidth: CGFloat = 560
        /// The log's console text (12 pt on 18 pt lines in the design).
        static let logFontSize: CGFloat = 12
        static let logMaxHeight: CGFloat = 220
        /// ScreensAI.swift `meterRow`: name column, value column; the side column of the monitor.
        static let monitorNameColumn: CGFloat = 112
        static let monitorValueColumn: CGFloat = 80
        static let monitorSideColumn: CGFloat = 320
        /// ScreensAI.swift `keyValue`: the key column.
        static let keyColumnWidth: CGFloat = 112
        /// ScreensAI.swift `meterRow`: the warning dot in a measure's detail line.
        static let warningDot: CGFloat = 8
        /// ScreensAI.swift ProfileChoice: the tiles' fixed height.
        static let profileTileHeight: CGFloat = 84
        /// ScreensAI.swift `radio`: the choice and its centre.
        static let radio: CGFloat = 16
        static let radioCentre: CGFloat = 6
        static let radioStroke: CGFloat = 1.5
        /// ScreensAI.swift `textField`: the model field.
        static let textFieldHeight: CGFloat = 28
        static let modelFieldWidth: CGFloat = 200
        /// ScreensMac.swift TextFieldRow: the bordered field of the row ("Nome utente in macOS").
        static let textFieldRowFieldWidth: CGFloat = 160
        /// ScreensAI.swift `localeMode` "chat": the user's message bubble, the model picker.
        static let chatBubbleWidth: CGFloat = 300
        static let chatModelPickerWidth: CGFloat = 160
        /// The conversation's smallest height (not a design number: the design's column fills it).
        static let chatMinHeight: CGFloat = 240
        /// How close to the end the conversation counts as "at the end" (it follows the answer).
        static let chatFollowSlack: CGFloat = 24
        /// Markdown (not design numbers, M3c chat): the list marker's column, one indentation
        /// level, the quote's bar.
        static let markdownMarkerWidth: CGFloat = 14
        static let markdownListIndent: CGFloat = 16
        static let markdownQuoteBar: CGFloat = 3
        /// The release notes window.
        static let releaseNotesWidth: CGFloat = 520
        static let releaseNotesHeight: CGFloat = 560
        /// ScreensAI.swift `catalogSheet`: the wider sheet of the catalog.
        static let catalogSheetWidth: CGFloat = 600
        static let catalogListHeight: CGFloat = 320
        /// ScreensAI.swift `remoteMode` "registro": the log's fixed columns (time, tokens,
        /// outcome, duration); the model column takes the rest.
        static let logTimeColumn: CGFloat = 60
        static let logTokensColumn: CGFloat = 80
        static let logOutcomeColumn: CGFloat = 96
        static let logDurationColumn: CGFloat = 44
        /// The Rete view's log (M3d, no render yet): outcome and protocol columns.
        static let networkOutcomeColumn: CGFloat = 72
        static let networkProtoColumn: CGFloat = 28
        /// The count on the Rete tab while notifications are off.
        static let tabCountMinWidth: CGFloat = 18
        /// ScreensMac.swift `macVMWindow`: the "Accesso da terminale" panel beside the screen.
        static let terminalAccessPanelWidth: CGFloat = 384
        /// ScreensMac.swift `numberedStep`: the accent disc with the step's number.
        static let stepNumberSize: CGFloat = 22
    }
}

extension Theme {
    /// ScreensMac.swift `macScreenFill`: behind the macOS guest's screen until it draws (literal
    /// in the generator, not a FigCraft variable).
    enum MacScreen {
        static let background = SwiftUI.Color(light: 0x1D2733, dark: 0x1D2733)
    }
}

extension Theme {
    /// Screens.swift `consoleFill` and `consoleText`: the VM's serial console, dark in both
    /// modes (literals in the generator, not FigCraft variables).
    enum Console {
        static let background = SwiftUI.Color(light: 0x101312, dark: 0x101312)
        static let foreground = SwiftUI.Color(light: 0xCDD2CB, dark: 0xCDD2CB)
    }
}
