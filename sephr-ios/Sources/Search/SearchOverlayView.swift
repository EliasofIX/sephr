import SwiftUI

/// Full-screen search takeover. Everything is bottom-anchored for the
/// thumb: the field sits directly above the keyboard, the favorites row
/// above the field, and typing swaps favorites for a scrollable
/// suggestion list. Keyboard comes up immediately.
struct SearchOverlayView: View {
    @Environment(BrowserEngine.self) private var engine
    @Environment(FavoritesStore.self) private var favorites
    @Environment(\.horizontalSizeClass) private var sizeClass

    let intent: BrowserShell.SearchIntent
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var incognito = false
    @FocusState private var focused: Bool

    private var suggestions: [HistoryStore.Visit] {
        incognito ? [] : engine.history.suggestions(for: query)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim — tap anywhere above the controls to dismiss.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: DC.Space.m) {
                if incognito {
                    Text("Incognito")
                        .dcLabel()
                        .padding(.horizontal, DC.Space.m)
                        .padding(.vertical, 6)
                        .dcGlass(cornerRadius: 12)
                }

                if query.isEmpty {
                    if !incognito && !favorites.favorites.isEmpty {
                        favoritesRow
                    }
                } else {
                    suggestionList
                }

                searchField
            }
            .frame(maxWidth: sizeClass == .regular ? 560 : .infinity)
            .padding(.horizontal, DC.Space.l)
            .padding(.bottom, DC.Space.s)
        }
        .onAppear {
            incognito = intent == .newIncognitoTab
                || (intent == .editCurrent
                    && engine.store.activeTab?.isIncognito == true)
            if intent == .editCurrent,
               let url = engine.currentURL {
                query = url.absoluteString
            }
            focused = true
        }
    }

    // MARK: — Field

    private var searchField: some View {
        HStack(spacing: DC.Space.m) {
            Button {
                withAnimation(.spring(response: 0.3,
                                      dampingFraction: 0.85)) {
                    incognito.toggle()
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(incognito ? DC.Ink.field : DC.Ink.ink3)
                    .frame(width: 36, height: 36)
                    .background {
                        if incognito {
                            Circle().fill(DC.Ink.ink)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(incognito ? "Leave Incognito" : "Go Incognito")

            TextField("Search or enter address", text: $query)
                .font(DC.TypeScale.body)
                .foregroundStyle(DC.Ink.ink)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit { submit(query) }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(DC.Ink.ink4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DC.Space.m)
        .frame(minHeight: 56)
        .dcGlass(cornerRadius: 28)
    }

    // MARK: — Favorites

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DC.Space.l) {
                ForEach(favorites.favorites) { favorite in
                    Button {
                        submit(favorite.url.absoluteString)
                    } label: {
                        VStack(spacing: 6) {
                            Text(String(favorite.label.prefix(1)).uppercased())
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(DC.Ink.ink)
                                .frame(width: 52, height: 52)
                                .dcSurface(cornerRadius: 16)
                            Text(favorite.label)
                                .font(DC.TypeScale.caption)
                                .foregroundStyle(DC.Ink.ink3)
                                .lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            favorites.remove(favorite.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, DC.Space.xs)
        }
        .padding(.vertical, DC.Space.m)
        .padding(.horizontal, DC.Space.m)
        .dcGlass(cornerRadius: 24)
    }

    // MARK: — Suggestions

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { visit in
                Button {
                    submit(visit.url.absoluteString)
                } label: {
                    HStack(spacing: DC.Space.m) {
                        Image(systemName: "clock")
                            .font(.system(size: 14))
                            .foregroundStyle(DC.Ink.ink4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.title.isEmpty
                                 ? visit.url.absoluteString : visit.title)
                                .font(DC.TypeScale.callout)
                                .foregroundStyle(DC.Ink.ink)
                                .lineLimit(1)
                            Text(visit.url.host() ?? "")
                                .font(DC.TypeScale.caption)
                                .foregroundStyle(DC.Ink.ink3)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 12))
                            .foregroundStyle(DC.Ink.ink4)
                    }
                    .padding(.horizontal, DC.Space.l)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if visit.id != suggestions.last?.id {
                    Divider().overlay(DC.Ink.hairline)
                        .padding(.leading, DC.Space.huge)
                }
            }

            // The query itself, as a search row.
            Divider().overlay(DC.Ink.hairline)
            Button {
                submit(query)
            } label: {
                HStack(spacing: DC.Space.m) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(DC.Ink.ink2)
                    Text("Search for “\(query)”")
                        .font(DC.TypeScale.callout)
                        .foregroundStyle(DC.Ink.ink)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, DC.Space.l)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .dcGlass(cornerRadius: 24)
    }

    // MARK: — Actions

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URLBuilder.url(from: trimmed)
        else { return }

        switch intent {
        case .editCurrent where !incognitoChanged:
            engine.open(url)
        default:
            engine.openInNewTab(url, incognito: incognito)
        }
        dismiss()
    }

    /// Flipping the eyes toggle mid-edit converts the submission into a
    /// fresh tab in the other mode.
    private var incognitoChanged: Bool {
        (engine.store.activeTab?.isIncognito ?? false) != incognito
    }

    private func dismiss() {
        focused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            onDismiss()
        }
    }
}
