# Sephr for iOS

The iPhone/iPad companion to Sephr — a search-first, one-thumb browser in
the DIGITAL CAVIAR design language. Lives alongside the macOS app in the
Sephr monorepo.

## Shape of the app

- **Search first.** Cold open lands in the search takeover with the
  keyboard already up. The field sits directly above the keyboard;
  favorites above the field; typing swaps favorites for history
  suggestions.
- **Three-glyph bottom bar.** Tabs · `+` · actions chevron, one Liquid
  Glass capsule, no visible URL while browsing. Swipe the bar
  left/right to cycle tabs; swipe up on the tabs glyph for the deck.
- **Tab deck.** Horizontal card gallery (app-switcher style). Tap to
  switch, flick a card up to archive. Settings, new tab, and the
  archive shelf live on the deck's own bar.
- **Auto-archive.** Tabs untouched past the configured horizon
  (12 h – 30 d) slide into a searchable archive instead of piling up.
- **Always-on blocking** of ads, trackers, and cookie banners
  (toggleable in Settings).
- Reader mode, find-in-page, desktop-site toggle, page zoom, incognito
  (the eyes button on the search field), favorites, share — all in the
  chevron menu or search screen.

## Efficiency

Only the active tab plus a 2-deep LRU keep live `WKWebView`s
(`WebViewPool`); every other tab is a metadata struct plus a JPEG
snapshot. Memory warnings trim the pool to the active tab. Persistence
is debounced JSON in Application Support.

## Building

Requires Xcode 26+ (iOS 26 SDK, Liquid Glass APIs).

```sh
cd sephr-ios
xcodegen generate
xcodebuild -project SephrIOS.xcodeproj -scheme Sephr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`SephrIOS.xcodeproj` is generated — edit `project.yml`, not the project.
