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
}
