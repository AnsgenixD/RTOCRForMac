# Overlay — Real-Time Japanese OCR & Translation Overlay for macOS

A transparent, resizable panel you place over any window (games, manga readers,
visual novels) that detects Japanese text on screen and overlays an English
translation directly on top of it, in place.

## Screenshots

*(In-game screenshots coming soon)*

## How it works

- **Screen capture:** `ScreenCaptureKit` grabs just the region under the panel, ~20 times/sec, skipping frames that haven't visibly changed.
- **OCR:** Apple's `Vision` framework detects Japanese (and English) text in each captured frame.
- **Translation:** checked in this order —
  1. Local SQLite cache (instant, free, works offline)
  2. Apple's on-device `Translation` framework (free, private, no network)
  3. Manual DeepL "improve translation" on double-tap, if you've configured a DeepL key (optional, better quality on short/idiomatic lines)
- **Display:** each detected line gets a small patch drawn over it (color-sampled from the surrounding pixels) with the translated text rendered on top.

## Requirements

- macOS 15 or later (the on-device `Translation` framework requires it)
- Xcode 16+ to build from source
- **Screen Recording permission** — you'll be prompted on first launch. If it doesn't stick, see Troubleshooting below.
- **Accessibility permission** — required for global keyboard shortcuts to work while another app (a game, a browser) is frontmost. You'll be prompted on first launch; if not, add the app manually in System Settings → Privacy & Security → Accessibility.
- **Japanese→English translation pack** — downloaded automatically via a system prompt the first time you run the app (this is a one-time, per-app download managed by macOS itself, not something bundled in the app).

## Building

1. Clone the repo.
2. Copy `Secrets.example.swift` → `Secrets.swift`, add it to the Xcode target, and (optionally) fill in a real DeepL API key from https://www.deepl.com/pro-api if you want the "improve translation" feature. Leave the placeholder as-is if you don't want DeepL — everything else works fine without it.
3. Open the `.xcodeproj`, select your signing team, build & run.

## Keyboard shortcuts

These are **global** — they work even while a different app is frontmost (requires Accessibility permission, see above):

| Shortcut | Action |
|---|---|
| `⌥⌘H` | Toggle HUD mode — hides the frosted glass backdrop, leaving only the translated text patches floating |
| `⌥⌘X` | Toggle click-through — when ON (default), clicks pass through the panel to whatever's underneath (e.g. a manga reader's next-page button). Turn OFF briefly to drag or resize the panel itself |

These are **menu-only** (app must be frontmost) — under the *Dictionary* menu:

| Shortcut | Action |
|---|---|
| `⌥⌘I` | Import a JSON dictionary of `{"Japanese": "English"}` pairs into the local cache |
| `⌥⌘E` | Export the current local translation cache to a JSON file |

**Double-tap** any translated text patch to request a DeepL "improve this translation" pass (requires a DeepL key in `Secrets.swift`).

## Known limitations

- **No image inpainting/redrawing.** Text patches are covered with a solid color sampled from the surrounding pixels (works well on flat UI/dialogue boxes, less well on busy manga backgrounds). True content-aware inpainting was considered and deliberately descoped in favor of speed and on-device performance.
- **Vertical (tategaki) Japanese is not supported yet.** There's no corresponding text-redraw/layout logic for vertical runs, so this was removed from the menu rather than shipped half-working.
- **Click-through defaults to ON**, meaning the panel doesn't grab keyboard focus or block mouse clicks — turn it off (`⌥⌘X`) to reposition/resize it.

## Roadmap

- [ ] **Vertical (Tategaki) Text Support:** Full layout and rendering support for vertical manga-style Japanese text.
- [ ] **Expanded OCR & Translation Engines:** More options for OCR and translation backends beyond Apple Vision OCR and Apple Translation.
- [ ] **Dynamic Text Scaling:** Dynamically scale overlay font sizes to fit the exact bounds of the original detected text.
- [ ] **In-Game Screenshots & Demos:** Adding showcase screenshots and recordings of the overlay in action with games and visual novels.

## Troubleshooting

**Screen Recording permission keeps re-prompting every launch:** almost always a stale/inconsistent code signature. Try:
```
tccutil reset ScreenCapture <your.bundle.id>
```
then fully quit (Cmd+Q, not just Xcode's Stop button), relaunch, grant permission, fully quit again, relaunch once more.

**Translation shows raw Japanese, never switches to English:** check Console.app (or Xcode's debug console) for `LanguageAvailability status`. If it reports `supported` rather than `installed`, the ja→en pack is registered system-wide (via System Settings) but not yet approved for this specific app — relaunch and accept the in-app download prompt if you see one.

**Global shortcuts don't do anything while another app is focused:** almost always missing Accessibility permission — check System Settings → Privacy & Security → Accessibility.

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.