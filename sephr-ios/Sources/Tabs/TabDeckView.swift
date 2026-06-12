import SwiftUI

/// The tab deck: a horizontally scrolling gallery of full-page cards,
/// app-switcher style. Tap a card to switch, flick it up to archive it.
/// The deck's own chrome sits at the bottom: settings (left), new tab
/// (center), archive shelf (right).
struct TabDeckView: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onDismiss: () -> Void
    let onNewTab: () -> Void
    let onSettings: () -> Void
    let onArchive: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: DC.Space.l) {
                HStack {
                    Text("\(engine.store.liveTabs.count) open")
                        .font(DC.TypeScale.data)
                        .foregroundStyle(DC.Ink.ink3)
                        .monospacedDigit()
                    Spacer()
                    SephrLogo(size: 15, color: DC.Ink.ink4)
                }
                .padding(.horizontal, DC.Space.margin)
                .padding(.top, DC.Space.s)

                if engine.store.liveTabs.isEmpty {
                    EmptyDeckView()
                        .onTapGesture { onDismiss() }
                } else {
                    cardGallery
                }

                deckBar
            }
        }
    }

    // MARK: — Cards

    private var cardGallery: some View {
        GeometryReader { geo in
            let cardWidth = min(geo.size.width * 0.72, 360)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DC.Space.l) {
                    ForEach(engine.store.liveTabs) { tab in
                        TabCard(tab: tab,
                                isActive: tab.id == engine.store.activeTabID,
                                width: cardWidth,
                                height: geo.size.height) {
                            engine.switchTo(tab.id)
                            onDismiss()
                        } onArchive: {
                            withAnimation(.spring(response: 0.35,
                                                  dampingFraction: 0.85)) {
                                engine.pool.tearDown(tab.id)
                                engine.store.archive(tab.id)
                            }
                        } onPin: {
                            engine.store.togglePin(tab.id)
                        }
                    }
                }
                .padding(.horizontal,
                         max(DC.Space.margin, (geo.size.width - cardWidth) / 2))
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: — Deck chrome

    private var deckBar: some View {
        HStack(spacing: 0) {
            deckButton("gearshape", label: "Settings", action: onSettings)
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DC.Ink.field)
                    .frame(width: 64, height: 48)
                    .background(Capsule(style: .continuous).fill(DC.Ink.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tab")
            .frame(maxWidth: .infinity)
            deckButton("archivebox", label: "Archive", action: onArchive)
        }
        .padding(.vertical, 6)
        .dcGlass(cornerRadius: 28)
        .frame(maxWidth: sizeClass == .regular ? 520 : .infinity)
        .padding(.horizontal, DC.Space.l)
        .padding(.bottom, DC.Space.s)
    }

    private func deckButton(_ symbol: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DC.Ink.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One card in the deck: the page snapshot over a title strip. Flick up
/// to archive — the card follows the finger and fades.
struct TabCard: View {
    let tab: SephrTab
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    let onArchive: () -> Void
    let onPin: () -> Void

    @State private var dragY: CGFloat = 0

    var body: some View {
        VStack(spacing: DC.Space.s) {
            snapshot
                .frame(width: width, height: max(120, height - 56))
                .clipShape(RoundedRectangle(cornerRadius: 24,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(isActive ? DC.Ink.ink2 : DC.Ink.hairline,
                                      lineWidth: isActive ? 1.5 : 1))

            HStack(spacing: 6) {
                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DC.Ink.ink3)
                }
                if tab.isIncognito {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 10))
                        .foregroundStyle(DC.Ink.ink3)
                }
                Text(tab.displayTitle)
                    .font(DC.TypeScale.caption)
                    .foregroundStyle(DC.Ink.ink2)
                    .lineLimit(1)
            }
            .frame(width: width)
        }
        .offset(y: dragY)
        .opacity(1 - min(0.7, abs(dragY) / 300))
        .onTapGesture(perform: onSelect)
        .gesture(flickUp)
        .contextMenu {
            Button(action: onPin) {
                Label(tab.isPinned ? "Unpin" : "Pin",
                      systemImage: tab.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive, action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }
        }
        .accessibilityLabel("\(tab.displayTitle), tab")
        .accessibilityHint("Tap to open, swipe up to archive")
    }

    @ViewBuilder
    private var snapshot: some View {
        if tab.isIncognito {
            ZStack {
                Rectangle().fill(DC.Ink.surface)
                Image(systemName: "eyeglasses")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DC.Ink.ink4)
            }
        } else if let image = TabSnapshotCache.shared.image(for: tab.id) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(DC.Ink.surface)
                Text(String(tab.displayTitle.prefix(1)).uppercased())
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(DC.Ink.ink4)
            }
        }
    }

    private var flickUp: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if value.translation.height < 0
                    || abs(value.translation.height)
                        > abs(value.translation.width) {
                    dragY = min(0, value.translation.height)
                }
            }
            .onEnded { value in
                if value.translation.height < -90
                    || value.predictedEndTranslation.height < -250 {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onArchive()
                } else {
                    withAnimation(.spring(response: 0.3,
                                          dampingFraction: 0.8)) {
                        dragY = 0
                    }
                }
            }
    }
}
