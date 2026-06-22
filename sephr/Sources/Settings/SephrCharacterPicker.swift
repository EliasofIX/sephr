import SwiftUI

/// In-app picker for the Settings ▸ Profile "character": emoji, SF
/// Symbols, and Unicode symbols in one tabbed grid. (Apple Memoji are
/// deliberately absent — macOS exposes no API for a third-party app to
/// enumerate or render them.) The chosen glyph is stored as a string in
/// `SephrPreferences.profileCharacter` and drawn large in the portrait.

// MARK: — Glyph model

/// A pickable character. `.text` covers emoji and Unicode glyphs (drawn
/// as text); `.symbol` is an SF Symbol (drawn via `Image(systemName:)`).
/// `storageValue` round-trips through the `profile.character` preference —
/// SF Symbols carry an `sf:` prefix so the renderer knows which path to
/// take.
enum SephrGlyph: Hashable {
    case text(String)
    case symbol(String)

    var storageValue: String {
        switch self {
        case .text(let s):   return s
        case .symbol(let n): return "sf:" + n
        }
    }

    init?(storage: String) {
        guard !storage.isEmpty else { return nil }
        if storage.hasPrefix("sf:") {
            self = .symbol(String(storage.dropFirst(3)))
        } else {
            self = .text(storage)
        }
    }
}

/// Draws a `SephrGlyph` at a given point size. SF Symbols and Unicode
/// glyphs take the ink colour; colour emoji ignore it (they keep their
/// own palette — the one splash of colour the monochrome surface allows).
struct SephrGlyphView: View {
    let glyph: SephrGlyph
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        switch glyph {
        case .text(let s):
            Text(s).font(.system(size: size))
        case .symbol(let n):
            Image(systemName: n)
                .font(.system(size: size, weight: weight))
        }
    }
}

// MARK: — Catalog

struct SephrGlyphCategory: Identifiable {
    let name: String
    let symbol: String          // SF Symbol for the category chip
    let glyphs: [SephrGlyph]
    var id: String { name }
}

enum SephrGlyphCatalog {
    private static func text(_ s: String) -> [SephrGlyph] {
        s.split(separator: " ").map { .text(String($0)) }
    }
    private static func symbols(_ names: [String]) -> [SephrGlyph] {
        names.map { .symbol($0) }
    }

    static let categories: [SephrGlyphCategory] = [
        SephrGlyphCategory(
            name: "Smileys", symbol: "face.smiling",
            glyphs: text(
                "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 " +
                "😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 🤥 " +
                "😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 " +
                "🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 " +
                "😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👹 👺 👻 👽 👾 🤖 😺")),
        SephrGlyphCategory(
            name: "People", symbol: "hand.wave.fill",
            glyphs: text(
                "👋 🤚 🖐 ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ " +
                "👊 🤛 🤜 👏 🙌 👐 🤲 🙏 ✍️ 💅 🤳 💪 🦵 🦶 👂 👃 🧠 👀 👁 👅 " +
                "👶 🧒 👦 👧 🧑 👨 👩 🧓 👴 👵 🧔 👲 🧕 🤵 👰 🤰 🦸 🦹 🧙 🧚 " +
                "🧛 🧜 🧝 🧞 🧟 💆 💇 🚶 🏃 💃 🕺 👯 🧖 🧗 🤺 🏇 ⛹️ 🤸 🤼 🤽")),
        SephrGlyphCategory(
            name: "Animals", symbol: "pawprint.fill",
            glyphs: text(
                "🐵 🐒 🦍 🦧 🐶 🐕 🦮 🐩 🐺 🦊 🦝 🐱 🐈 🦁 🐯 🐅 🐆 🐴 🐎 🦄 " +
                "🦓 🦌 🦬 🐮 🐂 🐄 🐷 🐗 🐽 🐏 🐑 🐐 🐪 🐫 🦙 🦒 🐘 🦣 🦏 🦛 " +
                "🐭 🐁 🐀 🐹 🐰 🐇 🐿 🦫 🦔 🦇 🐻 🐨 🐼 🦥 🦦 🦨 🦘 🦡 🐾 🦃 " +
                "🐔 🐓 🐣 🐤 🐥 🐦 🐧 🕊 🦅 🦆 🦢 🦉 🦩 🦚 🦜 🐸 🐊 🐢 🦎 🐍 " +
                "🐲 🐉 🦕 🦖 🐳 🐋 🐬 🦭 🐟 🐠 🐡 🦈 🐙 🐚 🐌 🦋 🐛 🐝 🐞 🦗")),
        SephrGlyphCategory(
            name: "Food", symbol: "fork.knife",
            glyphs: text(
                "🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 " +
                "🥦 🥬 🥒 🌶 🫑 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🥯 🍞 🥖 🥨 🧀 🥚 🍳 🧈 " +
                "🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥙 🧆 🥗 🍝 🍜 🍲 🍣 " +
                "🍱 🍛 🍙 🍘 🍥 🥠 🦪 🍤 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 " +
                "🍫 🍿 🍩 🍪 🌰 🥜 🍯 🥛 🍼 ☕ 🍵 🧃 🥤 🍶 🍺 🍷 🥂 🥃 🍸 🍹")),
        SephrGlyphCategory(
            name: "Activity", symbol: "figure.run",
            glyphs: text(
                "⚽ 🏀 🏈 ⚾ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🥅 ⛳ 🪁 " +
                "🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 🛷 ⛸ 🥌 🎿 ⛷ 🏂 🪂 🏋️ 🤼 🤸 ⛹️ 🤾 " +
                "🏌️ 🧘 🏄 🏊 🤽 🚣 🧗 🚵 🚴 🏆 🥇 🥈 🥉 🏅 🎖 🏵 🎗 🎫 🎟 🎪 " +
                "🤹 🎭 🩰 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🪘 🎷 🎺 🪗 🎸 🪕 🎻 🎲 ♟ 🎯 " +
                "🎳 🎮 🎰 🧩 🎺 🎵 🎶 🪅 🪩 🎊 🎉 🎈 🎀 🎁 🏮 🪔 🎄 🎃 🎇 🎆")),
        SephrGlyphCategory(
            name: "Travel", symbol: "airplane",
            glyphs: text(
                "🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🛻 🚚 🚛 🚜 🦯 🦽 🦼 🛴 🚲 🛵 " +
                "🏍 🛺 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚞 🚝 🚄 🚅 🚈 🚂 🚆 🚇 " +
                "🚊 🚉 ✈️ 🛫 🛬 🛩 💺 🛰 🚀 🛸 🚁 🛶 ⛵ 🚤 🛥 🛳 ⛴ 🚢 ⚓ ⛽ " +
                "🚧 🚦 🚥 🗺 🗿 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲ ⛱ 🏖 🏝 🏜 🌋 ⛰ " +
                "🏔 🗻 🏕 ⛺ 🛖 🏠 🏡 🏘 🏚 🏗 🏭 🏢 🏬 🏣 🏤 🏥 🏦 🏨 🏪 🏫")),
        SephrGlyphCategory(
            name: "Objects", symbol: "lightbulb.fill",
            glyphs: text(
                "⌚ 📱 💻 ⌨️ 🖥 🖨 🖱 🕹 💽 💾 💿 📀 📷 📸 📹 🎥 📺 📻 🎙 ⏰ " +
                "⏱ ⏲ 🕰 ⌛ ⏳ 📡 🔋 🔌 💡 🔦 🕯 🪙 💰 💎 ⚖️ 🪜 🧰 🔧 🔨 ⚒ " +
                "🛠 ⛏ 🔩 ⚙️ 🧱 ⛓ 🧲 🔫 💣 🧨 🔪 🗡 ⚔️ 🛡 🚬 ⚰️ 🪦 🏺 🔮 📿 " +
                "💈 ⚗️ 🔭 🔬 🕳 🩹 🩺 💊 💉 🧬 🦠 🧪 🌡 🧹 🧺 🧻 🚽 🚿 🛁 🧼 " +
                "🪒 🧽 🔑 🗝 🚪 🛋 🪑 🛏 🖼 🛍 🛒 🎈 🧧 🎀 🎁 ✉️ 📦 ✏️ 🖌 🖍")),
        SephrGlyphCategory(
            name: "Symbols", symbol: "heart.fill",
            glyphs: text(
                "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ☮️ " +
                "✝️ ☪️ 🕉 ☸️ ✡️ 🔯 🕎 ☯️ ☦️ 🛐 ⛎ ♈ ♉ ♊ ♋ ♌ ♍ ♎ ♏ ♐ " +
                "♑ ♒ ♓ 🆔 ⚛️ 🉑 ☢️ ☣️ 📴 📳 🈶 🈚 🈸 🈺 🈷️ ✴️ 🆚 💮 🉐 ㊙️ " +
                "㊗️ 🈴 🈵 🈹 🈲 🅰️ 🅱️ 🆎 🆑 🅾️ 🆘 ❌ ⭕ 🛑 ⛔ 📛 🚫 💯 💢 ♨️ " +
                "⭐ 🌟 ✨ ⚡ 🔥 💥 ❄️ 💫 ⬆️ ⬇️ ➡️ ⬅️ ↗️ ↘️ ✅ ☑️ ✔️ ➕ ➖ ➗")),
        SephrGlyphCategory(
            name: "SF Symbols", symbol: "square.grid.2x2.fill",
            glyphs: symbols([
                "star.fill", "sparkles", "heart.fill", "bolt.fill",
                "flame.fill", "moon.stars.fill", "sun.max.fill",
                "cloud.fill", "cloud.bolt.rain.fill", "snowflake",
                "drop.fill", "leaf.fill", "camera.macro", "tree.fill",
                "mountain.2.fill", "globe.americas.fill", "pawprint.fill",
                "hare.fill", "tortoise.fill", "ant.fill", "ladybug.fill",
                "fish.fill", "bird.fill", "lizard.fill", "dog.fill",
                "cat.fill", "teddybear.fill", "crown.fill", "trophy.fill",
                "medal.fill", "rosette", "flag.fill", "bell.fill",
                "tag.fill", "bookmark.fill", "gift.fill", "balloon.fill",
                "party.popper.fill", "gamecontroller.fill", "dpad.fill",
                "headphones", "music.note", "guitars.fill", "pianokeys",
                "paintbrush.pointed.fill", "pencil.and.outline",
                "camera.fill", "photo.fill", "film.fill", "tv.fill",
                "desktopcomputer", "laptopcomputer", "keyboard.fill",
                "gearshape.fill", "lightbulb.fill", "flashlight.on.fill",
                "key.fill", "lock.fill", "wrench.and.screwdriver.fill",
                "hammer.fill", "paperclip", "scissors", "book.fill",
                "graduationcap.fill", "briefcase.fill", "folder.fill",
                "envelope.fill", "paperplane.fill", "cart.fill",
                "creditcard.fill", "bag.fill", "airplane", "car.fill",
                "bus.fill", "tram.fill", "bicycle", "sailboat.fill",
                "fuelpump.fill", "map.fill", "location.fill", "house.fill",
                "building.2.fill", "person.fill", "person.2.fill",
                "face.smiling.inverse", "hand.thumbsup.fill",
                "hand.wave.fill", "figure.walk", "figure.run",
                "brain.head.profile", "eye.fill", "ear.fill",
                "checkmark.seal.fill", "shield.lefthalf.filled",
                "diamond.fill", "hexagon.fill", "suit.heart.fill",
                "suit.club.fill", "suit.spade.fill", "suit.diamond.fill",
                "infinity", "asterisk", "peacesign", "atom",
                "circle.fill", "square.fill", "triangle.fill",
            ])),
        SephrGlyphCategory(
            name: "Unicode", symbol: "textformat",
            glyphs: text(
                "★ ☆ ✦ ✧ ❖ ◆ ◇ ■ □ ▲ △ ▼ ▽ ● ○ ◐ ◑ ◔ ◕ ◢ " +
                "◣ ◤ ◥ ⬟ ⬢ ⬣ ⬡ ❀ ✿ ❁ ❉ ❊ ❋ ✺ ✹ ✸ ✶ ✷ ✵ ✴ " +
                "☯ ☮ ☻ ☺ ♡ ♥ ♠ ♣ ♦ ♢ ♤ ♧ ♪ ♫ ♬ ♭ ♮ ♯ ♩ 𝄞 " +
                "→ ← ↑ ↓ ↔ ↕ ↖ ↗ ↘ ↙ ⇒ ⇐ ⇑ ⇓ ⇔ ↻ ↺ ⟲ ⟳ ➤ " +
                "∞ ≈ ≠ ≤ ≥ ± × ÷ √ ∑ ∏ ∫ ∂ ∇ ∆ Ω Σ Φ Ψ Λ " +
                "π µ λ θ α β γ δ ε φ ψ ω § ¶ † ‡ • ‣ ※ ‰ " +
                "° ′ ″ ‹ › « » ‘ ’ “ ” ⌘ ⌥ ⌃ ⇧ ⏎ ⌫ ⎋ ⇪ ⌽ ⏏ " +
                "✓ ✔ ✗ ✘ ✕ ✚ ✛ ✜ ❄ ❅ ❆ ☀ ☁ ☂ ☃ ☄ ☼ ☽ ☾ ⚘")),
    ]
}

// MARK: — Picker view

/// Tabbed grid of glyphs. Picking one fires `onPick` with the chosen
/// `SephrGlyph`; the caller persists it and dismisses.
struct SephrCharacterPicker: View {
    let onPick: (SephrGlyph) -> Void
    @State private var category = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = Array(
        repeating: GridItem(.fixed(38), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Iterate by index — Array(enumerated()) would
                    // materialise a fresh tuple array on every body
                    // invocation. Categories are a constant 10-element
                    // static let, so the indices are stable.
                    ForEach(SephrGlyphCatalog.categories.indices,
                            id: \.self) { idx in
                        let cat = SephrGlyphCatalog.categories[idx]
                        CategoryChip(category: cat,
                                     isSelected: category == idx,
                                     reduceMotion: reduceMotion) {
                            withAnimation(reduceMotion ? nil
                                          : DC.Motion.spring) {
                                category = idx
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider().overlay(DC.Ink.hairline)

            // Glyph grid — keyed by category so the LazyVGrid identity
            // flips on every category switch and the transition fires.
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(SephrGlyphCatalog.categories[category].glyphs,
                            id: \.self) { glyph in
                        Button { onPick(glyph) } label: {
                            SephrGlyphView(glyph: glyph, size: 23)
                                .foregroundStyle(DC.Ink.ink)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(GlyphCellButtonStyle())
                    }
                }
                .padding(8)
                .id(category)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity))
            }
            .animation(reduceMotion ? nil : DC.Motion.easeOutPane,
                       value: category)
        }
        .frame(width: 300, height: 360)
    }
}

/// One category chip in the picker's horizontal tab strip. Lifted out so
/// each chip can hold its own `@State` hover (a ButtonStyle's @State is
/// fragile inside a ForEach), and so the selection swap animates instead
/// of snapping. Pill widens slightly on hover; ink-rest brightens to
/// `DC.Ink.ink2` so the chip reads as live.
private struct CategoryChip: View {
    let category: SephrGlyphCategory
    let isSelected: Bool
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: category.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 26)
                .foregroundStyle(isSelected ? DC.Ink.ink
                                 : (hovering ? DC.Ink.ink2 : DC.Ink.ink3))
                .background(
                    chipFill,
                    in: RoundedRectangle(cornerRadius: 7,
                                         style: .continuous))
                .scaleEffect(isSelected ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .help(category.name)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DC.Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : DC.Motion.spring, value: isSelected)
    }

    private var chipFill: Color {
        if isSelected { return DC.Ink.surface }
        if hovering   { return DC.Ink.hairline.opacity(0.6) }
        return Color.clear
    }
}

/// Subtle press fill for glyph cells — monochrome, no hue.
/// Press-only feedback (no hover wash): the previous design wired
/// `@State private var hovering` inside a ButtonStyle (a value type
/// re-created every render, so the @State was fragile) and installed an
/// NSTrackingArea + onHover-driven animation per cell. With ~100 cells
/// per visible category, scrubbing the mouse across the grid produced a
/// style-recompute storm. The fill on `configuration.isPressed` keeps
/// the affordance that matters (tactile press feedback) without the
/// per-cell tracking-area churn.
private struct GlyphCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed
                          ? DC.Ink.surface : Color.clear))
    }
}
