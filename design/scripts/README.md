# Nido's FigCraft scripts

Nido's design is built headless with `~/bin/figcraft-cli` (0.7.0). Everything starts here:

```sh
scripts/design-build.sh            # rebuilds everything into design/build/ and design/preview/
scripts/design-build.sh --replace  # also replaces design/nido.figcraft if it differs
```

The design files keep their Italian names (pages, boards, modes, flows), quoted below as they
appear in FigCraft: the modes `Chiaro` and `Scuro` are light and dark, `Valore` is "value".

## Order

| Step | File | What it does |
|---|---|---|
| 1 | `01-tokens.json` | `Tokens` page: variable collections `Color` (modes `Chiaro`, `Scuro`), `Space`, `Radius`, `Type` (mode `Valore`) and the token boards in both modes → `design/build/01-tokens.figcraft` |
| 2 | `02-components.json` | `Components` page (run with `--in` on the result of step 1): components and variants on the `Componenti · Chiaro` board, one instance of every variant on the `Componenti · Scuro` board → `design/build/02-components.figcraft` |
| 3 | `03-screens.json` | `Componenti delle schermate · Chiaro` board (InfoRow, PickerRow, SystemChoice) and a `Contenuto` slot in WizardStep; `Screens` page with the `Schermate · Chiaro` and `Schermate · Scuro` boards (S01–S11, 1100×720 windows made of instances, mode set with `variable.setMode`); `Prototype` page with F01, F03 and F04 linked → `design/build/03-screens.figcraft` |
| 4 | `04-icon.json` | `AppIcon` frame (S12, 1024×1024) on the `Screens` page → `design/build/nido.figcraft` |
| 5 | `90-export-tokens.json` | `variable.export` → `design/tokens.json` |

Then `design-build.sh` checks WCAG AA contrast in both modes (`scripts/check-contrast.swift`), regenerates `App/Nido/Design/Theme.swift` (`scripts/gen-theme.swift`) and writes the previews `design/preview/Tokens.png`, `Components.png`, `Components-chiaro.png`, `Components-scuro.png`, `Components-schermate.png` (scale 2), one PNG per screen in `design/preview/screens/` (scale 2), `overview-chiaro.png` and `overview-scuro.png` (all screens, scale 1) and `Prototype.png`; it exports the icon to `App/Nido/Assets.xcassets/AppIcon.appiconset/AppIcon-{16,32,64,128,256,512,1024}.png` (copies of 1024 and 32 in `design/preview/`). If a step fails, `figcraft-cli run` rolls back the whole script and the build script stops with a non-zero exit code.

## The JSON files are generated

All four scripts are generated with

```sh
scripts/gen-design-scripts.sh design/scripts
```

The generator lives in `scripts/design/`: `Builder.swift` (the `Script` builder that keeps count of the ids, the shared functions, the output and `--verify`), one file per page with its content (`Tokens.swift` with the token values, `Components.swift`, `Screens.swift`, `ScreensAI.swift` (the M3c screens: S13 Monitor, S14 Preparazione (provisioning), S15 AI, VM templates, Hugging Face token, Guest Tools), `ScreensMac.swift` (the M3b screens: the wizard's macOS path, macOS Image, installation, the Installing and Busy cards, the macOS window with the Terminal Access panel, Clone for macOS), `Prototype.swift`, `Icon.swift`) and `main.swift`. Other uses: `--verify <script> <log>`, `--list-screens` (the names of the screen frames, for the previews), `--count-clicks design/scripts/03-screens.json` (the clicks of F01 and of F01 macOS in the prototype, exit 1 above 6). `scripts/gen-design-scripts.sh` compiles them together with `xcrun swiftc` into a temporary binary and runs it (no dependencies). Edit these files, not the JSON: `design-build.sh` regenerates the scripts into `design/build/scripts/` and stops if they don't match the ones in `design/scripts/`.

Why: FigCraft scripts refer to layers by numeric id (`parent`, `ids`, `component`), and in a new headless session the ids are positional. Rules verified with FigCraft 0.7.0:

- the initial page is id 1; every layer created (`frame.create`, `text.create`, `shape.*`, `page.add`) takes the next id;
- `component.create` keeps the frame's id; `component.combineVariants` takes a new id for the set;
- `instance.create` takes one id for every layer of the main component, in pre-order (the instance, then the children depth-first): the text of a button inside an instance is `instance id + position in the component`;
- a file opened with `--in` continues from the file's highest id;
- `instance.setProperties` that changes the variant leaves the id with the instance and gives new ids to the layers inside (in pre-order);
- `instance.slotInsert` gives the inserted instance the next ids; with `replace`, the removed layers don't come back;
- `strokesIncluded` is an auto layout property: setting it turns auto layout on. Freely positioned frames (icon, sheet scrim) are created without it (`Script.freeFrame`);
- a shadow is written with `"offset": [x, y]` (the keys `offsetX`/`offsetY` are ignored).

The generator keeps count and writes, on every step that creates a layer, a collection or a variable, the key `expectId` (a number for layers, `VariableCollectionId:n` / `VariableID:n` for collections and variables; FigCraft ignores unknown keys). After every `run`, `design-build.sh` compares the ids returned with the expected ones (`scripts/gen-design-scripts.sh --verify <script> <log>`) and stops at the first difference.

Variables are bound by id (`VariableID:n`, in creation order: 12 colors, then `Space`, `Radius`, `Type`), because `s`, `m` and `l` exist in both `Space` and `Radius` and the name alone is ambiguous.

## Fonts

All text uses **Inter** (Regular, SemiBold, Bold), bundled with FigCraft, and every command runs with `--no-system-fonts`: renders are identical on every Mac. The system font (SF Pro) isn't among the bundled ones; in the SwiftUI app, the system font is used with the sizes in `Theme.TypeSize`, and Inter has close metrics.

## Notes

- No absolute paths in the scripts: `variable.export` writes `design/tokens.json` relative to the repository root (from which `design-build.sh` runs everything).
- `design/build/` and `design/preview/` aren't under version control.
- `design/nido.figcraft` is the approved copy of `design/build/nido.figcraft`; `design-build.sh` compares it with `cmp` and never overwrites it without `--replace` (exit 3). Builds are byte-for-byte deterministic.
- The scrim behind sheets is the color variable `scrim` (black at 20% in `Chiaro`, at 55% in `Scuro`), created by `03-screens.json` after the variables of 01 so that their ids don't change; it also goes into `design/tokens.json` and `Theme.Color.scrim`.
- Fixed colors, not variables: the VM console (it is the guest's framebuffer, the same in both modes), the shadows and the icon (an image).
- To try the prototype, open `design/nido.figcraft` in FigCraft, `Prototype` page, flows `F01 · Crea una VM Debian` (create a Debian VM), `F03 · Avvia, metti in pausa, riprendi, arresta` (start, pause, resume, stop; with Suspend), `F04 · Crea e ripristina uno snapshot` (create and restore a snapshot) and `F01 macOS · Crea una VM macOS da un IPSW` (create a macOS VM from an IPSW).
