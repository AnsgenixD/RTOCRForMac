

## MACmort — Roadmap for AI Agent

### Now

**1. Fill out top-bar menu**
- Add "Reset Translation Cache" (clears SQLite table, confirm via alert)
- Add "Check Accessibility Permission" (calls `AXIsProcessTrustedWithOptions`, opens System Settings pane if not granted)
- Add "Prepare Translation Pack" (manually re-triggers the `.translationTask` download flow, for users who dismissed the first-run prompt)
- Surface current click-through / HUD state in the menu (checkmark, not just toggle)

**2. In-app Help**
- New `CommandMenu("Help")` with a window/sheet listing: all hotkeys, permission requirements, current OCR/translation source per active block, link to README
- Consider a first-launch onboarding sheet (permissions checklist + hotkey cheatsheet) rather than relying on users reading GitHub

**3. Selectable OCR / translation backends**
- Translation: user-facing picker between Apple MT (default, offline) / DeepL (if key configured) / (future) Google Cloud Translation — persist choice in `UserDefaults`
- OCR: exposed tuning, not full backend swap (Vision is the only realistic on-device option) — expose `recognitionLevel` (.fast vs .accurate) as a user toggle for speed/accuracy tradeoff, since project priority is speed for game text
- Architecture: define a `TranslationProvider` protocol now so adding backends later doesn't require touching call sites

**4. Proper packaged release**
- Signed build (Developer ID or Personal Team for now)
- Notarize + staple when a paid account is available
- `.dmg` with drag-to-Applications layout
- Attach to GitHub Release; document required permissions in release notes (Screen Recording, Accessibility, translation pack first-run download — none of this can be pre-bundled)
- Optional: GitHub Actions workflow to automate archive/notarize/dmg on tag push

### Far off

**1. Manga-style (tategaki) vertical JP text**
- Requires actual redraw/layout logic for vertical text blocks (rotate capture region, rotate result back, vertical text rendering in `ContentView`) — previously removed from menu because OCR orientation existed with no corresponding display logic. Don't re-expose the toggle until both halves are implemented.

**2. Simultaneous multilingual OCR/translation**
- Not "pick one language" but detect + translate multiple languages present in the same frame concurrently (e.g. JP + KO text both on screen). Vision's `recognitionLanguages` already accepts multiple codes — the gap is per-block language *detection* (which language is *this* observation) and routing each block to the correct translation pair, since `translate(japaneseText:)` currently hardcodes ja→en.

**3. Read-aloud (TTS, not STT)**
- Correction: STT (speech-to-text) would transcribe audio — what's wanted here is **TTS (text-to-speech)**, reading the *translated* text aloud. Use `AVSpeechSynthesizer` (built-in, on-device, free) rather than a separate STT model — no third-party model needed for this feature.

**4. Novel speaker attribution**
- Use a small on-device LLM (Apple's on-device Foundation Models framework, if targeting a recent-enough macOS, or a bundled small local model) with a rolling context window of recent OCR'd lines to infer speaker identity (MC vs. side character) for visual-novel-style text. Genuinely research-y — scope as an experiment, not a committed feature, until feasibility is validated on-device.
