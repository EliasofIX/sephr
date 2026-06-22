import Foundation

extension Notification.Name {
    /// Posted whenever an `SephrTab`'s `isLoading` flips. `object` is
    /// the tab. The window controller listens to it to drive the
    /// top-of-page loading shimmer.
    static let sephrTabLoadingChanged =
        Notification.Name("sephr.tab.loadingChanged")
    static let sephrTabModelChanged = Notification.Name("sephr.tabModel.changed")
    static let sephrSpaceChanged    = Notification.Name("sephr.space.changed")
    static let sephrSpaceListChanged = Notification.Name("sephr.spaceList.changed")
    static let sephrThemeChanged    = Notification.Name("sephr.theme.changed")
    static let sephrBoostsChanged   = Notification.Name("sephr.boosts.changed")
    /// Posted when a page opens a window.open popup (e.g. an OAuth/SSO
    /// sign-in like "Continue with Google"). `object` is the popup's live
    /// `CALWebView` (opener relationship intact); the key window presents it
    /// in a peek overlay.
    static let sephrPresentPopupPeek =
        Notification.Name("sephr.popup.present")

    /// Posted whenever a tab's media session changes (play/pause flips,
    /// Media Session API metadata updates, the session appears/disappears).
    /// `object` is the `SephrTab`. The sidebar's Now Playing pill listens
    /// app-wide — per-tab bus subscriptions can't see a session START on a
    /// tab nobody subscribed to yet.
    static let sephrTabMediaChanged =
        Notification.Name("sephr.tab.mediaChanged")

    /// Note-canvas commands rerouted from the app-wide keyboard shortcut
    /// monitor (which must swallow Cmd+Z/Cmd+Shift+Z/Cmd+V before
    /// Chromium sees them). `object` is the note tab's UUID; the note's
    /// SephrNoteStore/canvas acts only when the ID matches its own.
    static let sephrNoteUndo  = Notification.Name("sephr.note.undo")
    static let sephrNoteRedo  = Notification.Name("sephr.note.redo")
    static let sephrNotePaste = Notification.Name("sephr.note.paste")
}
