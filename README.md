# Sephr

A privacy-first, design-led browser for macOS and iOS — native chrome around a
custom Chromium engine (**Sephrium**), built in the DIGITAL CAVIAR design language.

Sephr is built for people who want a thoughtful alternative to the default
browser experience: spaces, a command bar, reader mode, on-device
intelligence, and built-in blocking — without the usual Chromium baggage.

| Platform | Stack | Status |
|----------|-------|--------|
| **macOS** | Swift/AppKit + Sephrium (Chromium) | Active development |
| **iOS** | SwiftUI + WebKit | Active development |

## License

**This repository is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE).**

Copyright **EliasofIX**. All rights reserved.

You may read, study, fork, and contribute to this code for **noncommercial**
purposes — personal use, research, education, hobby projects, and use by
nonprofit or public institutions.

**Commercial use is not permitted** without a separate written agreement from
the copyright holder. That includes operating a competing browser product,
offering Sephr (or a derivative) as a paid or ad-supported service, or
incorporating this code into a commercial product.

If you redistribute copies or derivatives, you must include the full
[LICENSE](LICENSE) file and the `Required Notice` line it contains.

## Repository layout

```
sephr/           macOS application (Swift/AppKit)
sephr-ios/       iOS companion (SwiftUI) — see sephr-ios/README.md
sephrium/        Chromium patches, flags, and build configuration
sephr_overlay/   Chromium overlay sources (CAL bridge, built-in extensions)
cal/             ObjC++ bridge between Sephr and Sephrium.framework
sephrkit/        Shared Swift library (TabEventBus, etc.)
scripts/         Bootstrap and build pipeline
smoke/           Low-level Sephrium link smoke test
```

## Building (macOS)

**Requirements:** Apple Silicon Mac (arm64), macOS 14+, Xcode with a recent
command-line tools install, ~40 GB free disk for the Chromium tree, and a
reliable network connection for the first bootstrap.

The Chromium source tree (`.chromium-src/`, ~9 GB extracted) is downloaded and
patched locally — it is **not** checked into git.

```sh
# Full pipeline: bootstrap (first run only) → Sephrium → CAL → Sephr → Sephr.app
./scripts/build_all.sh

# Fast incremental rebuild after the tree exists
./scripts/build_all.sh --fast

# Release build (LTO, suitable for distribution)
./scripts/build_all.sh --release --sign 'Developer ID Application: Your Name'
```

Launch the result:

```sh
open build/Sephr.app
```

See [sephrium/PHASE2-PLAN.md](sephrium/PHASE2-PLAN.md) for architecture notes on
how Sephr embeds Chromium.

## Building (iOS)

See [sephr-ios/README.md](sephr-ios/README.md). Requires Xcode 26+ (iOS 26 SDK).

## Contributing

Pull requests and issue reports are welcome for **noncommercial** use. By
contributing, you agree that your contributions will be licensed under the same
[PolyForm Noncommercial License](LICENSE) terms as the rest of the project.

For commercial licensing inquiries, contact the copyright holder (EliasofIX).

## Third-party components

Sephr builds on Chromium (BSD-style license), [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium)
patches, and various open-source Swift packages declared in `Package.swift`.
Built-in ad blocking bundles [uBlock Origin](https://github.com/gorhill/uBlock)
filter lists. See individual dependency licenses for their terms — they are
separate from Sephr's own license.
