# Unplug

macOS menu bar app (single file: `Sources/main.swift`) that disconnects external displays via the private `CGSConfigureDisplayEnabled` API. Built with `./build.sh`, no Xcode project.

## Releasing

When asked to release or publish a new version, follow [RELEASING.md](RELEASING.md) step by step. A release is only done when all of these are true:

1. `./release.sh <version>` finished with notarization `Accepted` and `source=Notarized Developer ID`.
2. A GitHub release `v<version>` exists with `Unplug-<version>.zip` attached.
3. `packaging/unplug.rb` was copied to `~/Developer/homebrew-tap/Casks/unplug.rb`, committed and pushed (only after step 2).
4. `brew audit --cask --online iltekin/tap/unplug` passes.

## Rules

- The built-in display must never be switchable off from the menu. It was removed on purpose: with the built-in screen off, unplugging the external display left the Mac with no screen.
- On/off state always comes from the system (`CGDisplayIsActive`), never from saved app state.
- The app icon is drawn in `scripts/make-icon.swift` without SF Symbols (their license forbids them in app icons). SF Symbols are fine inside the menu.
