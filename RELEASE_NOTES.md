# Release Notes Template — MACmort

Copy this into the body of each GitHub Release (the release workflow's
`--generate-notes` only produces the auto-commit summary). **Every release
must document the permissions below** — none of them can be pre-bundled into
the DMG, and all three are required for the app to work.

---

## MACmort vX.Y.Z

Real-time Japanese OCR & translation overlay for macOS.

### Requirements

- macOS 15 or later (Apple's on-device `Translation` framework).

### First launch — three permissions (cannot be bundled, must be granted by the user)

1. **Screen Recording** — prompted on first launch. MACmort only captures the
   region of the screen directly under its overlay panel. If the permission
   doesn't stick: `tccutil reset ScreenCapture Ansgenix.overlay`, relaunch,
   grant, restart the app.
2. **Accessibility** — prompted on first launch; required for the global
   hotkeys (⌥⌘H / ⌥⌘X) to work while a game or browser is frontmost. Add it
   under System Settings → Privacy & Security → Accessibility. Check status
   any time via **Overlay → Check Accessibility Permission**.
3. **Japanese→English translation pack** — a one-time, per-app download
   managed by macOS, triggered by a system prompt on first run. If it was
   dismissed: **Overlay → Prepare Translation Pack** re-shows the prompt.

The first-launch onboarding window walks through all three with live status;
reopen it any time via **Help → Show Onboarding**.

### What's in the DMG

- `Overlay.app` — signed with a Developer ID Application certificate,
  notarized and stapled, so Gatekeeper opens it normally after download.
- Drag `Overlay.app` onto the `Applications` folder shortcut, then launch
  from /Applications (launching from the mounted DMG can confuse the
  Screen Recording permission grant).

### Known limitations

See the [README](https://github.com/AnsgenixD/RTOCRForMac#known-limitations):
no image inpainting (solid color patches), no vertical (tategaki) text yet.

### Verifying the download (optional)

```
spctl -a -vv /Applications/Overlay.app
xcrun stapler validate /Applications/Overlay.app
```
