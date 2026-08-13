Implements the "Now" section of `Future additions to MACmort.md` (far-off items deliberately excluded — the doc itself scopes them out).

## 1. Top-bar menu additions (`Overlay.swift`)

Add a new `CommandMenu("Overlay")` (or extend "Scan Mode") with:

- **Reset Translation Cache…** — `NSAlert` confirmation → new `TranslationManager.clearCache()` (`DELETE FROM translations`).
- **Check Accessibility Permission** — calls `AXIsProcessTrustedWithOptions` (no prompt), shows result in an alert; if denied, opens System Settings → Privacy & Security → Accessibility via `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- **Prepare Translation Pack** — bumps a new `@Published var translationPrepToken: Int` on `PanelData`; `ContentView` switches to `.translationTask(id: dataManager.translationPrepToken, …)` so changing the token re-runs `prepareTranslation()` and re-shows the system download prompt (this needs a live view — documented in ContentView.swift:73-80).
- HUD / click-through state: keep the existing `Toggle`s (they already render as checkmarks) and add a small read-only status caption reflecting current state.

## 2. In-app Help + onboarding

- **New `HelpView.swift`** — window (managed by `AppDelegate` via `NSWindow` + `NSHostingView`, since the app has no standard windows) containing:
  - Hotkey cheatsheet (⌥⌘H, ⌥⌘X, ⌥⌘I, ⌥⌘E + double-tap improve)
  - Permissions checklist with **live status** (Screen Recording via `CGPreflightScreenCaptureAccess()`, Accessibility via `AXIsProcessTrusted`, translation pack via `LanguageAvailability`)
  - **Per-active-block OCR/translation source** — live list from `PanelData.textBlocks`
  - "View README on GitHub" button → opens https://github.com/AnsgenixD/RTOCRForMac
- New `CommandMenu("Help")` with "Show Help & Hotkeys" (⌘?) item.
- **Onboarding**: new `OnboardingView.swift` shown on first launch (UserDefaults flag `hasCompletedOnboarding`) with the permission checklist + hotkey cheatsheet and a "Get Started" button. Reopenable from the Help menu.

## 3. Selectable backends + OCR tuning

- **New `TranslationProviders.swift`**:
  - `protocol TranslationProvider { var name: String; func translate(_ text: String) async -> (text: String, source: String) }`
  - `AppleTranslationProvider` — moves the existing macOS 15 `TranslationSession` logic out of `TranslationManager`
  - `DeepLTranslationProvider` — wraps existing `callDeepL` (fixes bug at `TranslationManager.swift:22`: use the `deepLAPIKeyValue` global from `Secrets.swift` instead of the string literal, and guard against the placeholder properly; creates a local gitignored `Secrets.swift` from `secrets.example.swift` so the project compiles)
  - `enum TranslationBackend: String, CaseIterable` — `.appleMT` (default) / `.deepl`, persisted in UserDefaults
- `TranslationManager.translate(japaneseText:)` keeps its cache lookup + in-flight dedup, then routes to the selected provider — call sites unchanged.
- **OCR**: `usesFastOCR` toggle persisted in UserDefaults; `OCRManager` sets `request.recognitionLevel = usesFastOCR ? .fast : .accurate`.
- **New `SettingsView.swift`** replacing `Settings { EmptyView() }`: translation backend picker (DeepL row disabled with "requires API key in Secrets.swift" footnote when unconfigured) + OCR speed/accuracy toggle, both via `@AppStorage`.
- **Per-block source tracking**: add `var source: String` to `RecognizedTextBlock`; `updateBlockText` gains a source parameter; `OCRManager` stores the previously-discarded `result.source` — feeds the Help window display.

## 4. Packaging prep

- **`Overlay/Info.plist`**: fill in the (currently empty) Screen Recording usage string.
- **`project.pbxproj`**: `ENABLE_APP_SANDBOX = NO` (both configs), per your answer — sandbox conflicts with Accessibility/global-hotkey needs and Developer ID releases don't require it. Hardened runtime stays (notarization requires it).
- **New `.github/workflows/release.yml`**: on `v*` tag push — import Developer ID cert from repo secrets, `xcodebuild archive`, notarize via `notarytool`, build drag-to-Applications DMG, attach to a GitHub Release. Secrets (`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`/`APPLE_TEAM_ID` etc.) must be configured by you later; workflow documents this.
- **New `scripts/build-dmg.sh`**: local Release build + `hdiutil` DMG with app + `/Applications` symlink.
- **New `RELEASE_NOTES.md` template** documenting required permissions (Screen Recording, Accessibility, translation-pack first-run download — none pre-bundled).
- **Update `readme.md`**: new menus, Settings window, onboarding, release process.

## Verification

- `xcodebuild -project Overlay.xcodeproj -scheme Overlay build` to confirm everything compiles (note: `Secrets.swift` will exist locally but stays gitignored).
- Manual/runtime behaviors (permissions prompts, translation pack flow) can't be exercised headlessly — I'll flag anything unverifiable.

No git commits will be made unless you ask.