# MACMort — Real-Time Japanese OCR & Translation Overlay for macOS

[![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-blue.svg?style=flat&logo=apple)](https://www.apple.com/macos/)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg?style=flat&logo=swift)](https://swift.org)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)](https://www.apple.com/macos/)

**MACMort** is a transparent, floating macOS overlay designed to detect Japanese text on screen in real time and render English translations directly over the original text. Perfect for games, visual novels, manga readers, and web browsers, MACMort combines low-latency screen capture, native computer vision, and privacy-first on-device translation.

---

## Architecture & Data Flow

```
 ┌──────────────────────┐      ┌─────────────────────────┐
 │   Screen Capture     │ ───► │    Apple Vision OCR     │
 │  (ScreenCaptureKit)  │      │ (VNRecognizeTextRequest)│
 └──────────────────────┘      └────────────┬────────────┘
                                            │ Extracted Bounding Boxes & Text
                                            ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      Tiered Translation Engine                         │
│                                                                        │
│   1. Local SQLite Cache ────► 2. On-Device Translation ────► 3. DeepL  │
│      (Instant / Offline)         (Apple MT - Private)       (Optional) │
└───────────────────────────────────────────┬────────────────────────────┘
                                            │ Translated Text & Coordinates
                                            ▼
                               ┌─────────────────────────┐
                               │ Dynamic HUD Overlay UI  │
                               │  (NSPanel + SwiftUI)    │
                               └─────────────────────────┘
```

---

## Key Features

- **Real-Time High-Framerate Capture:** Powered by `ScreenCaptureKit`, capturing targeted window regions at ~20 FPS with minimal CPU/GPU consumption.
- **On-Device Japanese OCR:** Native character recognition using Apple's `Vision` framework with fast bounding-box tracking.
- **Hybrid Tiered Translation:**
  1. **SQLite Cache:** Zero-latency lookup for previously translated phrases.
  2. **Apple Translation Framework:** On-device, private, offline translation engine (macOS 15+).
  3. **DeepL API Integration:** Optional online fallback for nuanced context and idiomatic expressions.
- **Floating HUD & Click-Through Mode:**
  - **Click-Through (`⌥⌘X`):** Pass mouse clicks directly through the overlay to underlying games or applications.
  - **HUD Mode (`⌥⌘H`):** Toggle frosted-glass backdrop, leaving only floating translation patches.
- **Dynamic Background Color Patching:** Color-samples pixel bounds around detected text to render matching background patches, cleanly obscuring original Japanese text before displaying English overlays.
- **OCR Tuning & Backend Picker:** Configure recognition levels (Fast vs. Accurate) and switch translation providers on the fly in Settings.

---

## Requirements

- **Operating System:** macOS 15.0 (Sequoia) or later (required for Apple's native Translation framework)
- **Developer Tools:** Xcode 16.0+ (to build from source)
- **System Permissions:**
  - **Screen Recording:** Required for `ScreenCaptureKit` frame acquisition.
  - **Accessibility:** Required for global hotkeys (`⌥⌘H`, `⌥⌘X`) while other apps are focused.
- **Language Pack:** Japanese → English translation pack (downloaded automatically via macOS system prompt on first launch).

---

## Keyboard Shortcuts & Controls

### Global Shortcuts (Works when any application is focused)
*Requires Accessibility permission.*

| Shortcut | Action |
| :--- | :--- |
| `⌥⌘H` | **Toggle HUD Mode** — Hides the frosted glass backdrop, leaving floating translated text patches. |
| `⌥⌘X` | **Toggle Click-Through** — Toggles mouse interactivity (ON passes clicks to underlying window, OFF allows repositioning/resizing). |

### Menu Commands (App must be frontmost)

| Menu / Shortcut | Action |
| :--- | :--- |
| **Dictionary → Import…** (`⌥⌘I`) | Import custom `{"Japanese": "English"}` JSON dictionaries into local SQLite cache. |
| **Dictionary → Export…** (`⌥⌘E`) | Export active SQLite translation cache to JSON. |
| **Overlay → Reset Translation Cache…** | Clear all cached translations from SQLite database. |
| **Overlay → Check Accessibility Permission…** | Verify global shortcut status and open System Settings if ungranted. |
| **Overlay → Prepare Translation Pack…** | Trigger system Japanese→English offline translation pack prompt. |
| **Help → Show Help & Hotkeys** (`⌘?`) | Display shortcuts, live permission statuses, and active OCR block sources. |
| **Help → Show Onboarding…** | Open the first-launch setup guide and permissions checklist. |

---

## How It Works

1. **Screen Capture:** `ScreenCaptureKit` samples frame buffer regions directly under the transparent overlay window (~20 FPS) and skips identical frames to conserve energy.
2. **Text Recognition:** Frames are passed to Apple's `Vision` framework (`VNRecognizeTextRequest`). Character bounding boxes and recognized text blocks are returned in normalized vision space.
3. **Translation Routing:**
   - **Step 1:** Look up exact text string in local SQLite database (`Cache`).
   - **Step 2:** If missing, route text to Apple's on-device `Translation` framework.
   - **Step 3 (Optional):** Double-tapping any active patch requests a DeepL refinement pass if an API key is configured.
4. **Rendering & Patching:** SwiftUI renders formatted text patches over AppKit `NSPanel`. Each patch samples surrounding image pixels to fill background bounding boxes before rendering English text on top.

---

## Building from Source

```bash
# 1. Clone the repository
git clone https://github.com/dev-pd-1525/Muro.git
cd Muro

# 2. Configure DeepL API Key (Optional)
cp Secrets.example.swift Overlay/Secrets.swift
# Edit Overlay/Secrets.swift to insert your key, or leave placeholder as-is.

# 3. Open in Xcode and Build
open Overlay.xcodeproj
```

### Automated Release Builds (DMG)

Generate a standalone DMG installer using the build script:

```bash
# Local unsigned DMG build
./scripts/build-dmg.sh

# Custom output DMG build
./scripts/build-dmg.sh --output MACmort-v1.0.0.dmg

# Signed & Notarized build (Developer ID required)
./scripts/build-dmg.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile MACMORT_NOTARY_PROFILE \
  --output MACmort-v1.0.0.dmg
```

---

## Settings & Configuration

Access Settings (`⌘,`) to configure runtime parameters:

- **Translation Provider:** Choose between Apple Translation (On-Device, Offline) or DeepL API.
- **OCR Recognition Level:**
  - **Fast:** Prioritizes low latency (~15–30ms), ideal for action game text and dialogue boxes.
  - **Accurate:** Performs deeper Kanji recognition analysis, ideal for dense manga pages.

---

## Roadmap

- [x] Top-bar menu navigation & cache reset utilities
- [x] In-app Help & permission diagnostic dashboard
- [x] Multi-backend translation architecture (`TranslationProvider` protocol)
- [x] Configurable Vision OCR recognition levels (Fast vs. Accurate)
- [x] Automated release packaging (`build-dmg.sh` & GitHub Actions CI/CD)
- [ ] **Vertical (Tategaki) Japanese Text:** Complete layout reconstruction for vertical text runs in manga/light novels.
- [ ] **Multilingual OCR & Translation:** Simultaneous detection of multiple source languages in the same frame.
- [ ] **On-Device Text-to-Speech (TTS):** Spoken output for translated lines via `AVSpeechSynthesizer`.
- [ ] **Dynamic Overlay Scaling:** Automatic font resizing based on exact detected bounding box dimensions.

---

## Troubleshooting

- **Screen Recording Permission Issues:**
  If macOS re-prompts for Screen Recording permission on every launch, reset permissions using Terminal:
  ```bash
  tccutil reset ScreenCapture <your.bundle.id>
  ```
  Relaunch the app, grant permission, quit completely (`⌘Q`), and relaunch once more.
- **Untranslated Text / Raw Japanese Displays:**
  Open **Overlay → Prepare Translation Pack…** to confirm the system Japanese→English language pack is downloaded and authorized for MACMort.
- **Global Hotkeys Not Responding:**
  Ensure Accessibility permission is granted under **System Settings → Privacy & Security → Accessibility**.

---

## License

This project is licensed under the **Apache License 2.0**. See the [LICENSE](LICENSE) file for details.
