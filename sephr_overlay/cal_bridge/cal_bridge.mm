// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// Implements the C ABI declared in cal_bridge.h. Each `SephriumXxx` function
// is the thinnest possible wrapper over a Chromium primitive — see plan
// notes; the goal of Phase 1 is to compile-and-link cleanly and paint
// example.com pixels via CALWebView, not to expose every Chromium feature.

#include "chrome/sephr/cal_bridge/cal_bridge.h"

#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/types/expected.h"
#include "chrome/sephr/cal_bridge/cal_profile_registry.h"
#include "chrome/sephr/cal_bridge/cal_tab_window_controller.h"
#include "chrome/sephr/cal_bridge/sephr_modal_dialog_manager_delegate.h"
#include "chrome/browser/sephr_browser_main_extra_parts.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "extensions/browser/extensions_browser_client.h"
#include "content/public/browser/navigation_controller.h"
#include "ui/base/window_open_disposition.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/session_storage_namespace.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/referrer.h"
#include "content/public/browser/context_menu_params.h"
#include "third_party/blink/public/common/context_menu_data/untrustworthy_context_menu_params.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom-shared.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkImageInfo.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "ui/base/page_transition_types.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

namespace {

char* DupCString(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

}  // namespace

// Helper ObjC class used as the NSMenu items' target. Each menu item we
// build stashes its URL string in `representedObject`; the action
// selectors read it and either copy to the pasteboard, or invoke the
// per-holder "new tab" C callback the embedder registered.
@interface CALContextMenuTarget : NSObject
@property (nonatomic, assign) SephriumNewTabRequestCallback newTabCb;
@property (nonatomic, assign) void* newTabCtx;
@end

@implementation CALContextMenuTarget
- (void)openInNewTab:(NSMenuItem*)item {
    NSString* url = item.representedObject;
    if (self.newTabCb && url.length) {
        self.newTabCb(self.newTabCtx, url.UTF8String);
    }
}
- (void)copyURL:(NSMenuItem*)item {
    NSString* url = item.representedObject;
    if (!url.length) return;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb writeObjects:@[url]];
}
- (void)copyText:(NSMenuItem*)item {
    NSString* text = item.representedObject;
    if (!text.length) return;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb writeObjects:@[text]];
}
@end

namespace {

// Wrapper that owns a content::WebContents AND acts as its
// WebContentsDelegate + WebContentsObserver. The delegate role is what
// makes raw `WebContents::Create` actually navigate — without one Chromium
// short-circuits multiple network-routing setup paths and the renderer
// receives nothing. content_shell does exactly the same thing (see
// content/shell/browser/shell.cc:Shell::Shell which calls
// web_contents_->SetDelegate(this)).
class SephriumWebContentsHolder : public content::WebContentsObserver,
                                  public content::WebContentsDelegate {
 public:
  // Variant 1: take ownership of a freestanding WebContents (CAL-created).
  explicit SephriumWebContentsHolder(
      std::unique_ptr<content::WebContents> contents)
      : content::WebContentsObserver(contents.get()),
        owned_contents_(std::move(contents)),
        contents_ptr_(owned_contents_.get()) {
    if (contents_ptr_) contents_ptr_->SetDelegate(this);
  }

  // Variant 2: non-owning. The WebContents lives inside a hidden
  // Chrome Browser TabStripModel set up by chrome::Navigate.
  explicit SephriumWebContentsHolder(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        contents_ptr_(contents) {
    if (contents_ptr_) contents_ptr_->SetDelegate(this);
  }

  ~SephriumWebContentsHolder() override {
    // Unregister from WindowControllerList first (its dtor only touches the
    // list, not the WebContents), so the tabs API stops vending this tab
    // before anything else is torn down.
    tab_window_controller_.reset();
    // Detach the modal-dialog delegate from the manager BEFORE the
    // WebContents (and therefore the manager) is destroyed, so the
    // manager's raw delegate_ pointer doesn't dangle. The manager itself
    // is user-data and will be torn down by ~WebContents shortly after.
    if (contents_ptr_) {
      if (auto* m = web_modal::WebContentsModalDialogManager::FromWebContents(
              contents_ptr_)) {
        if (m->delegate() == modal_dialog_delegate_.get()) {
          m->SetDelegate(nullptr);
        }
      }
      if (contents_ptr_->GetDelegate() == this) {
        contents_ptr_->SetDelegate(nullptr);
      }
    }
  }

  // Install a SephrModalDialogManagerDelegate on the WebContents'
  // WebContentsModalDialogManager. Must be called AFTER
  // TabHelpers::AttachTabHelpers (which creates the manager) and only
  // ever once per holder. Without this, every Chromium modal-dialog
  // flow (WebAuthn picker, permission prompts, etc.) crashes on
  // manager->delegate()->GetWebContentsModalDialogHost(...) — see
  // SephrModalDialogHost for the long-form explanation.
  void InstallModalDialogDelegate() {
    if (!contents_ptr_ || modal_dialog_delegate_) {
      return;
    }
    auto* m = web_modal::WebContentsModalDialogManager::FromWebContents(
        contents_ptr_);
    if (!m) {
      return;
    }
    modal_dialog_delegate_ =
        std::make_unique<sephr::SephrModalDialogManagerDelegate>(contents_ptr_);
    m->SetDelegate(modal_dialog_delegate_.get());
  }

  // Register this tab with the extensions tabs API (via a CalTabWindowController
  // added to WindowControllerList). Must be called AFTER
  // TabHelpers::AttachTabHelpers, which assigns the SessionTabHelper tab id
  // that ExtensionTabUtil::GetTabById matches on. Without this, the
  // raw WebContents lives in no Browser/TabStripModel, so the tabs API can't
  // resolve it — and features that call chrome.tabs.* for their own tab fail
  // (e.g. the PDF viewer's zoom init throws and the viewer never paints).
  void InstallTabApiWindowController() {
    if (!contents_ptr_ || tab_window_controller_) {
      return;
    }
    Profile* profile =
        Profile::FromBrowserContext(contents_ptr_->GetBrowserContext());
    if (!profile) {
      return;
    }
    tab_window_controller_ =
        std::make_unique<sephr::CalTabWindowController>(contents_ptr_, profile);
  }

  content::WebContents* contents() { return contents_ptr_; }

  void SetNavCallback(SephriumNavCallback cb, void* ctx) {
    nav_callback_ = cb;
    nav_ctx_ = ctx;
  }

  void SetFaviconCallback(SephriumFaviconCallback cb, void* ctx) {
    favicon_callback_ = cb;
    favicon_ctx_ = ctx;
  }

  void SetLoadingCallback(SephriumLoadingCallback cb, void* ctx) {
    loading_callback_ = cb;
    loading_ctx_ = ctx;
  }

  void SetNewTabRequestCallback(SephriumNewTabRequestCallback cb, void* ctx) {
    new_tab_callback_ = cb;
    new_tab_ctx_ = ctx;
  }

  void SetTargetURLCallback(SephriumTargetURLCallback cb, void* ctx) {
    target_url_callback_ = cb;
    target_url_ctx_ = ctx;
  }

  void SetPopupRequestCallback(SephriumPopupRequestCallback cb, void* ctx) {
    popup_request_callback_ = cb;
    popup_request_ctx_ = ctx;
  }

  void SetCloseRequestCallback(SephriumCloseRequestCallback cb, void* ctx) {
    close_request_callback_ = cb;
    close_request_ctx_ = ctx;
  }

  // Wrap a WebContents in a holder and run the standard Sephr per-tab setup —
  // tab helpers, the extensions WebContentsObserver, the modal-dialog
  // delegate, and the tabs-API window controller — i.e. everything
  // SephriumWebContentsCreate does to a fresh WebContents, minus the initial
  // navigation. Used both for CAL-created tabs and for Chromium-created
  // popups adopted in AddNewContents. The contents is marked hidden so the
  // first CALWebView attach is a clean hidden->visible transition (see the
  // long note in SephriumWebContentsCreate for why that matters).
  static SephriumWebContentsHolder* AdoptContents(
      std::unique_ptr<content::WebContents> contents) {
    if (!contents) {
      return nullptr;
    }
    TabHelpers::AttachTabHelpers(contents.get());
    if (auto* extensions_client = extensions::ExtensionsBrowserClient::Get()) {
      extensions_client->CreateExtensionWebContentsObserver(contents.get());
    }
    auto* holder = new SephriumWebContentsHolder(std::move(contents));
    holder->InstallModalDialogDelegate();
    holder->InstallTabApiWindowController();
    if (holder->contents_ptr_) {
      holder->contents_ptr_->WasHidden();
    }
    return holder;
  }

  // content::WebContentsObserver:
  void DidStartNavigation(content::NavigationHandle* handle) override {
    VLOG(1) << "[sephr/bridge/obs] DidStartNavigation url="
            << handle->GetURL().spec()
            << " IsRendererInitiated=" << handle->IsRendererInitiated()
            << " IsSameDocument=" << handle->IsSameDocument();
  }
  void ReadyToCommitNavigation(content::NavigationHandle* handle) override {
    VLOG(1) << "[sephr/bridge/obs] ReadyToCommitNavigation url="
            << handle->GetURL().spec();
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    VLOG(1) << "[sephr/bridge/obs] DidFinishNavigation url="
            << handle->GetURL().spec()
            << " HasCommitted=" << handle->HasCommitted()
            << " IsErrorPage=" << handle->IsErrorPage()
            << " NetErrorCode=" << handle->GetNetErrorCode();
    Notify();
  }
  void DidStartLoading() override {
    VLOG(1) << "[sephr/bridge/obs] DidStartLoading";
    if (loading_callback_) loading_callback_(loading_ctx_, 1);
  }
  void DidStopLoading() override {
    VLOG(1) << "[sephr/bridge/obs] DidStopLoading";
    if (loading_callback_) loading_callback_(loading_ctx_, 0);
  }
  void RenderFrameCreated(content::RenderFrameHost* rfh) override {
    VLOG(1) << "[sephr/bridge/obs] RenderFrameCreated rfh=" << rfh
            << " IsLive="
            << (rfh ? rfh->IsRenderFrameLive() : false);
  }
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override {
    // Renderer crash. Keep this at WARNING — it's rare and actionable, and
    // the embedder needs the breadcrumb in stderr to attribute the crash.
    // Until we wire a dedicated "renderer gone" surface in the C ABI we
    // rely on the loading callback flipping to is_loading=0 (DidStopLoading
    // is invoked by content as part of teardown) plus the page sad-tab
    // overlay so the user knows the tab is dead.
    LOG(WARNING) << "[sephr/bridge/obs] PrimaryMainFrameRenderProcessGone "
                 << "status=" << status;
  }
  void TitleWasSet(content::NavigationEntry*) override {
    Notify();
  }
  // Fires when the underlying WebContents is being destroyed — most
  // commonly because the renderer process died or because the embedder
  // explicitly destroyed it via a path that races with our dtor. After
  // this point contents_ptr_ is a dangling pointer; null it out so the
  // C-ABI bridge functions can no-op rather than walk freed memory.
  void WebContentsDestroyed() override {
    VLOG(1) << "[sephr/bridge/obs] WebContentsDestroyed";
    contents_ptr_ = nullptr;
    nav_callback_ = nullptr;
    favicon_callback_ = nullptr;
    loading_callback_ = nullptr;
    new_tab_callback_ = nullptr;
    target_url_callback_ = nullptr;
    popup_request_callback_ = nullptr;
    close_request_callback_ = nullptr;
  }

  // content::WebContentsDelegate:
  //
  // `window.open(...)` / target="_blank" handling. We return false here so
  // Chromium creates the new WebContents ITSELF, which is what wires up the
  // opener relationship: the popup's `window.opener` points back at the page
  // that opened it and the two share a browsing-context group. That linkage
  // is mandatory for popup-based OAuth/SSO (e.g. claude.ai's "Continue with
  // Google"): after consent the callback page runs
  // `window.opener.postMessage(token)` then `window.close()`, and without a
  // live opener neither reaches home — the sign-in silently fails on a blank
  // popup. We then ADOPT the created contents in AddNewContents.
  //
  // The earlier shortcut returned true and dropped the contents to dodge a
  // crash: dropping an off-the-record popup's contents let ProfileDestroyer
  // tear the profile down under a still-spinning renderer, CHECK-failing in
  // BookmarkModel's dtor. That crash was a symptom of *dropping* the
  // contents, not of letting Chromium create it — adopting (keeping it alive
  // in a holder owned by the embedder's host view) removes the cause: the
  // profile keeps a live reference for the whole popup session and the
  // contents is torn down normally when the host goes away.

  bool IsWebContentsCreationOverridden(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      content::mojom::WindowContainerType window_container_type,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url) override {
    return false;
  }

  content::WebContents* CreateCustomWebContents(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      bool is_new_browsing_instance,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      const content::StoragePartitionConfig& partition_config,
      content::SessionStorageNamespace* session_storage_namespace)
      override {
    // Unreachable now that IsWebContentsCreationOverridden returns false
    // (Chromium creates popups itself and we adopt them in AddNewContents).
    // Kept as a defensive fallback: if some path ever overrides creation,
    // route the target URL into the current tab rather than dropping it.
    if (target_url.is_valid() && contents_ptr_) {
      contents_ptr_->GetController().LoadURL(
          target_url, content::Referrer(),
          ui::PAGE_TRANSITION_LINK, std::string());
    }
    return nullptr;
  }

  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override {
    if (!contents_ptr_) return nullptr;
    content::NavigationController::LoadURLParams lp(params.url);
    lp.transition_type = params.transition;
    lp.referrer = params.referrer;
    lp.extra_headers = params.extra_headers;
    lp.is_renderer_initiated = params.is_renderer_initiated;
    lp.initiator_origin = params.initiator_origin;
    lp.source_site_instance = params.source_site_instance;
    lp.has_user_gesture = params.user_gesture;
    auto handle = contents_ptr_->GetController().LoadURLWithParams(lp);
    if (handle && navigation_handle_callback) {
      std::move(navigation_handle_callback).Run(*handle);
    }
    return contents_ptr_;
  }

  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override {
    if (was_blocked) {
      *was_blocked = false;
    }
    LOG(WARNING) << "[sephr/bridge] AddNewContents disposition="
                 << static_cast<int>(disposition)
                 << " target_url=" << target_url.possibly_invalid_spec()
                 << " new_contents=" << new_contents.get()
                 << " popup_cb=" << (popup_request_callback_ ? "set" : "null");

    // NEW_POPUP is window.open() called with window features (width/height/
    // "popup") — the shape OAuth/SSO sign-in flows use. Adopt the
    // Chromium-created contents (it carries the opener link) and hand it to
    // the embedder to host in a peek. The opener's page stays alive in its
    // own tab, so the callback page's window.opener.postMessage(...) lands.
    if (disposition == WindowOpenDisposition::NEW_POPUP && new_contents) {
      SephriumWebContentsHolder* popup =
          SephriumWebContentsHolder::AdoptContents(std::move(new_contents));
      if (!popup) {
        return nullptr;
      }
      content::WebContents* popup_ptr = popup->contents();
      if (popup_request_callback_) {
        popup_request_callback_(
            popup_request_ctx_,
            reinterpret_cast<SephriumWebContentsRef>(popup));
        return popup_ptr;
      }
      // Nobody to host it — don't leak the holder/contents.
      LOG(WARNING) << "[sephr/bridge] NEW_POPUP with no popup callback; "
                      "dropping adopted contents";
      delete popup;
      return nullptr;
    }

    // Non-popup dispositions (target="_blank", window.open without features):
    // preserve existing behaviour — route the URL into the current tab and
    // let the unowned new_contents fall off scope. (These share the opener's
    // regular profile, so dropping them doesn't trip ProfileDestroyer.)
    if (target_url.is_valid() && contents_ptr_) {
      contents_ptr_->GetController().LoadURL(
          target_url, content::Referrer(),
          ui::PAGE_TRANSITION_LINK, std::string());
      return contents_ptr_;
    }
    return nullptr;
  }

  void CloseContents(content::WebContents* source) override {
    // window.close(). Chromium only delivers this for script-closable
    // windows (those the script opened), so for an OAuth popup this is the
    // self-close after it postMessages its result home. Tell the embedder to
    // tear down whatever host shows this contents (Sephr dismisses the peek,
    // which deallocs the adopted view and destroys the contents). The
    // embedder-side callback hops to the main thread, so the actual
    // destruction happens well after this returns — no re-entrant teardown.
    LOG(WARNING) << "[sephr/bridge] CloseContents close_cb="
                 << (close_request_callback_ ? "set" : "null");
    if (close_request_callback_) {
      close_request_callback_(close_request_ctx_);
    }
  }

  // Pointer moved onto / off a link. Chromium calls this with the link's
  // destination while the cursor hovers a link, and with an invalid/empty
  // GURL when the cursor leaves it. We forward the spec up to the embedder
  // so the Shift+hover "peek" gesture knows what to preview. Fires on the
  // UI thread — CAL re-dispatches to main before touching AppKit.
  void UpdateTargetURL(content::WebContents* source,
                       const GURL& url) override {
    if (!target_url_callback_) return;
    const std::string spec = url.is_valid() ? url.spec() : std::string();
    target_url_callback_(target_url_ctx_, spec.c_str());
  }

  // Right-click on the page — Chromium's renderer reports the context
  // via this method. Without an override the menu never appears (the
  // default content::WebContents path is empty for embedders that
  // don't ship a Browser). We build a minimal NSMenu in-place: link
  // actions when params.link_url is set, image actions when src_url
  // is set, copy when there's selected text, plus a navigation
  // footer. Returning true tells Chromium we handled the menu — the
  // default fall-through (which would do nothing for us) is skipped.
  bool HandleContextMenu(
      content::RenderFrameHost& render_frame_host,
      const content::ContextMenuParams& params) override {
    if (!contents_ptr_) return false;
    NSView* host = contents_ptr_->GetNativeView().GetNativeNSView();
    if (!host) return false;

    NSMenu* menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    CALContextMenuTarget* target = [[CALContextMenuTarget alloc] init];
    target.newTabCb = new_tab_callback_;
    target.newTabCtx = new_tab_ctx_;

    auto addItem = ^(NSString* title, SEL selector,
                     NSString* represented) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:selector
                                             keyEquivalent:@""];
      item.target = target;
      item.representedObject = represented;
      [menu addItem:item];
    };

    // Link items
    if (params.link_url.is_valid()) {
      NSString* link = [NSString stringWithUTF8String:
                                     params.link_url.spec().c_str()];
      addItem(@"Open Link in New Tab",
              @selector(openInNewTab:), link);
      addItem(@"Copy Link", @selector(copyURL:), link);
      [menu addItem:[NSMenuItem separatorItem]];
    }

    // Image items
    if (params.src_url.is_valid() &&
        params.media_type ==
            blink::mojom::ContextMenuDataMediaType::kImage) {
      NSString* src = [NSString stringWithUTF8String:
                                     params.src_url.spec().c_str()];
      addItem(@"Open Image in New Tab",
              @selector(openInNewTab:), src);
      addItem(@"Copy Image Address", @selector(copyURL:), src);
      [menu addItem:[NSMenuItem separatorItem]];
    }

    // Video / audio
    if (params.src_url.is_valid() &&
        (params.media_type ==
             blink::mojom::ContextMenuDataMediaType::kVideo ||
         params.media_type ==
             blink::mojom::ContextMenuDataMediaType::kAudio)) {
      NSString* src = [NSString stringWithUTF8String:
                                     params.src_url.spec().c_str()];
      addItem(@"Open Media in New Tab",
              @selector(openInNewTab:), src);
      addItem(@"Copy Media Address", @selector(copyURL:), src);
      [menu addItem:[NSMenuItem separatorItem]];
    }

    // Selected text
    if (!params.selection_text.empty()) {
      NSString* sel = [NSString stringWithUTF8String:
                                     base::UTF16ToUTF8(
                                         params.selection_text).c_str()];
      addItem(@"Copy", @selector(copyText:), sel);
      [menu addItem:[NSMenuItem separatorItem]];
    }

    // Navigation footer — always available.
    NSMenuItem* back = [[NSMenuItem alloc] initWithTitle:@"Back"
                                                  action:nil
                                           keyEquivalent:@""];
    back.enabled = contents_ptr_->GetController().CanGoBack();
    if (back.enabled) {
      back.target = target;
      back.action = @selector(noop:);  // placeholder
    }
    NSMenuItem* fwd = [[NSMenuItem alloc] initWithTitle:@"Forward"
                                                 action:nil
                                          keyEquivalent:@""];
    fwd.enabled = contents_ptr_->GetController().CanGoForward();

    // Defer back/forward/reload to a small inline block target — we
    // keep them visible but disabled when the controller has nothing
    // to navigate.
    [menu addItem:back];
    [menu addItem:fwd];

    NSMenuItem* reload = [[NSMenuItem alloc] initWithTitle:@"Reload"
                                                     action:nil
                                              keyEquivalent:@""];
    [menu addItem:reload];

    // Strong-retain `target` for the lifetime of the menu so the
    // menu items' weak target references stay valid until selection.
    objc_setAssociatedObject(menu, "sephr_target", target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSEvent* event = [NSApp currentEvent];
    if (event) {
      [NSMenu popUpContextMenu:menu withEvent:event forView:host];
    } else {
      // Synthesise from the ContextMenuParams coordinates. They're in
      // the WebContents' viewport coordinate space — Y-down — so flip
      // to NSView's Y-up space before positioning.
      NSPoint location = NSMakePoint(
          params.x,
          host.bounds.size.height - params.y);
      [menu popUpMenuPositioningItem:nil
                          atLocation:location
                              inView:host];
    }
    return true;
  }

  // Favicon discovery. The renderer parses the page's <link rel="icon">
  // tags and posts a list of candidates. We pick the first non-invalid
  // entry and kick off WebContents::DownloadImage; the bitmap comes back
  // on the UI thread through OnFaviconDownloaded.
  void DidUpdateFaviconURL(
      content::RenderFrameHost* render_frame_host,
      const std::vector<blink::mojom::FaviconURLPtr>& candidates) override {
    if (!favicon_callback_ || !contents_ptr_) {
      return;
    }
    for (const auto& candidate : candidates) {
      if (!candidate) continue;
      if (candidate->icon_type ==
          blink::mojom::FaviconIconType::kInvalid) {
        continue;
      }
      if (!candidate->icon_url.is_valid()) continue;
      contents_ptr_->DownloadImage(
          candidate->icon_url,
          /*is_favicon=*/true,
          // Request a high-res favicon: the sidebar's pinned-tab chips can
          // be full sidebar width, so a 32px icon would visibly blur. 128px
          // (and a 256px ceiling for .ico/SVG sources) keeps it crisp.
          gfx::Size(128, 128),
          /*max_bitmap_size=*/256,
          /*bypass_cache=*/false,
          base::BindOnce(&SephriumWebContentsHolder::OnFaviconDownloaded,
                         weak_factory_.GetWeakPtr()));
      return;  // First viable candidate wins.
    }
  }

 private:
  void OnFaviconDownloaded(int /*id*/,
                           int /*http_status_code*/,
                           const GURL& /*image_url*/,
                           const std::vector<SkBitmap>& bitmaps,
                           const std::vector<gfx::Size>& /*sizes*/) {
    if (!favicon_callback_) return;
    if (bitmaps.empty()) {
      favicon_callback_(favicon_ctx_, nullptr, 0, 0, 0);
      return;
    }
    // Pick the bitmap whose width is closest to the 128px target —
    // Chromium returns multiple resolutions when the page provides an .ico,
    // and we want the sharpest one the sidebar chip can use.
    const SkBitmap* best = nullptr;
    int best_score = std::numeric_limits<int>::max();
    for (const SkBitmap& b : bitmaps) {
      if (b.isNull() || !b.getPixels()) continue;
      const int score = std::abs(b.width() - 128);
      if (score < best_score) {
        best = &b;
        best_score = score;
      }
    }
    if (!best) {
      favicon_callback_(favicon_ctx_, nullptr, 0, 0, 0);
      return;
    }
    favicon_callback_(favicon_ctx_,
                      best->getPixels(),
                      best->width(), best->height(),
                      static_cast<int>(best->rowBytes()));
  }


  void Notify() {
    if (!nav_callback_ || !contents_ptr_) {
      return;
    }
    const std::string url = contents_ptr_->GetLastCommittedURL().spec();
    const std::string title = base::UTF16ToUTF8(contents_ptr_->GetTitle());
    nav_callback_(nav_ctx_, url.c_str(), title.c_str());
  }

  std::unique_ptr<content::WebContents> owned_contents_;
  raw_ptr<content::WebContents> contents_ptr_ = nullptr;
  std::unique_ptr<sephr::SephrModalDialogManagerDelegate>
      modal_dialog_delegate_;
  std::unique_ptr<sephr::CalTabWindowController> tab_window_controller_;
  SephriumNavCallback nav_callback_ = nullptr;
  void* nav_ctx_ = nullptr;
  SephriumFaviconCallback favicon_callback_ = nullptr;
  void* favicon_ctx_ = nullptr;
  SephriumLoadingCallback loading_callback_ = nullptr;
  void* loading_ctx_ = nullptr;
  SephriumNewTabRequestCallback new_tab_callback_ = nullptr;
  void* new_tab_ctx_ = nullptr;
  SephriumTargetURLCallback target_url_callback_ = nullptr;
  void* target_url_ctx_ = nullptr;
  SephriumPopupRequestCallback popup_request_callback_ = nullptr;
  void* popup_request_ctx_ = nullptr;
  SephriumCloseRequestCallback close_request_callback_ = nullptr;
  void* close_request_ctx_ = nullptr;
  base::WeakPtrFactory<SephriumWebContentsHolder> weak_factory_{this};
};

inline SephriumWebContentsHolder* AsHolder(SephriumWebContentsRef ref) {
  return reinterpret_cast<SephriumWebContentsHolder*>(ref);
}

inline content::BrowserContext* AsContext(SephriumProfileRef ref) {
  return reinterpret_cast<content::BrowserContext*>(ref);
}

}  // namespace

// ---- Lifecycle ------------------------------------------------------------

// ChromeMain is the framework's main entry point — already exported via
// chrome/app/framework.exports. Declare it here so we can forward into it
// without dragging in chrome/app/chrome_main.h.
extern "C" int ChromeMain(int argc, const char** argv);

extern "C" void SephriumInitialize(int argc, const char* const* argv) {
  // Phase 2 Option A: forward to ChromeMain. It takes over the main thread,
  // installs MessagePumpNSApplication, runs init, and only returns at
  // shutdown. Strip outer const to match ChromeMain's signature — argv
  // itself is treated as read-only by ChromeMain.
  (void)ChromeMain(argc, const_cast<const char**>(argv));
}

extern "C" void SephriumPumpOnce(void) {
  // Phase 2 Option A: Chromium's MessagePumpNSApplication drains itself.
  // Kept exported so the ABI stays stable for embedders still calling it
  // from a CFRunLoopSource (Phase 1 development pattern).
}

extern "C" void SephriumSetUiBootCallback(SephriumUiBootCallback callback) {
  // The C function pointer type matches sephr::UiBootCallback by signature;
  // bridge through a reinterpret_cast so we don't need to share a header.
  sephr::SetUiBootCallback(reinterpret_cast<sephr::UiBootCallback>(callback));
}

// ---- Profile --------------------------------------------------------------

extern "C" SephriumProfileRef SephriumProfileGet(const char* profile_id,
                                               const char* disk_path) {
  if (!profile_id || !disk_path) {
    return nullptr;
  }
  content::BrowserContext* ctx =
      sephr::CalProfileRegistry::Get().GetOrCreate(
          profile_id, base::FilePath(disk_path));
  return reinterpret_cast<SephriumProfileRef>(ctx);
}

extern "C" void SephriumProfileRelease(SephriumProfileRef profile) {
  // Phase 1: registry holds non-owning pointers; nothing to free here.
  (void)profile;
}

// ---- WebContents ----------------------------------------------------------

extern "C" SephriumWebContentsRef
SephriumWebContentsCreate(SephriumProfileRef profile, const char* initial_url) {
  content::BrowserContext* ctx = AsContext(profile);
  LOG(WARNING) << "[sephr/bridge] WebContentsCreate ctx=" << ctx
               << " url=" << (initial_url ? initial_url : "(null)");
  if (!ctx) {
    return nullptr;
  }
  Profile* p = Profile::FromBrowserContext(ctx);
  if (!p) {
    return nullptr;
  }

  // Raw WebContents — no Chrome Browser, no fake NSWindow.
  // content_shell does the same thing and successfully navigates; the key
  // is (a) AttachTabHelpers for chrome:// scheme handling + URLLoaderFactory
  // binding via Profile, (b) SetDelegate so navigation requests have a
  // delegate to consult, and (c) WasShown so the renderer doesn't park its
  // paint loop. The WebContents view (a WebContentsViewCocoa) is added to
  // the embedder's NSView via SephriumWebContentsGetNativeView →
  // CALWebView addSubview; the renderer's BrowserCompositorMac picks up the
  // new host NSWindow via viewDidMoveToWindow.
  content::WebContents::CreateParams params(ctx);
  std::unique_ptr<content::WebContents> contents =
      content::WebContents::Create(params);
  LOG(WARNING) << "[sephr/bridge] WebContents=" << contents.get();
  if (!contents) {
    return nullptr;
  }
  // Tab helpers configure SiteInstance + URLLoaderFactory + history +
  // chrome:// URL handlers. Without these the navigation request is
  // created (is_loading=1) but the renderer never receives the load IPC.
  TabHelpers::AttachTabHelpers(contents.get());

  // AttachTabHelpers wires the extension *tab* helpers but NOT the extensions
  // WebContentsObserver. The bundled PDF viewer is a component extension whose
  // MimeHandlerView frames need that observer to initialize — without it the
  // PDF extension loads (the tab even picks up the filename as its title) but
  // the OOPIF plugin frame never comes up, so PDFium never paints and the
  // viewport stays blank. Routing through ExtensionsBrowserClient::Get()
  // reaches ChromeExtensionWebContentsObserver::CreateForWebContents, which
  // no-ops if one is already attached.
  if (auto* extensions_client = extensions::ExtensionsBrowserClient::Get()) {
    extensions_client->CreateExtensionWebContentsObserver(contents.get());
  }

  auto* holder = new SephriumWebContentsHolder(std::move(contents));

  // Install Sephr's modal-dialog manager delegate. Required after
  // TabHelpers::AttachTabHelpers so the WebContentsModalDialogManager
  // exists. Without this, ANY Chromium modal-dialog flow on this
  // WebContents (WebAuthn picker, permission prompts, certificate
  // viewer, save-password bubble, …) SIGSEGVs inside
  // constrained_window::CreateWebModalDialogViews because the manager's
  // delegate_ pointer is nullptr. See sephr_modal_dialog_host.h.
  holder->InstallModalDialogDelegate();
  // Make this tab resolvable by the chrome.tabs API (see CalTabWindowController).
  // Required for the bundled PDF viewer to finish initializing, among other
  // extension features that look up their own tab.
  holder->InstallTabApiWindowController();
  content::WebContents* contents_ptr = holder->contents();

  // Create HIDDEN. The view is detached (no NSWindow) at this point, so
  // marking it visible here used to leave the browser-side compositor
  // pre-set to "visible" with no real surface; when the view later
  // attached to a window there was no hidden->visible transition, so the
  // renderer never produced a frame for the newly-attached surface and the
  // tab painted blank until a switch-away/back cycle forced the transition.
  // Starting hidden makes the first real attach (CALWebView drives
  // SephriumWebContentsSetVisible from viewDidMoveToWindow) the
  // hidden->visible transition that requests a frame. Loading proceeds
  // while hidden — visibility is independent of navigation — and
  // background-warmed tabs no longer paint until they're actually shown.
  contents_ptr->WasHidden();

  if (initial_url && *initial_url) {
    GURL url(initial_url);
    if (url.is_valid()) {
      content::NavigationController::LoadURLParams lp(url);
      lp.transition_type = ui::PageTransitionFromInt(
          ui::PAGE_TRANSITION_TYPED |
          ui::PAGE_TRANSITION_FROM_ADDRESS_BAR);
      auto handle = contents_ptr->GetController().LoadURLWithParams(lp);
      LOG(WARNING) << "[sephr/bridge] LoadURLWithParams handle=" << handle.get()
                   << " entries=" << contents_ptr->GetController().GetEntryCount()
                   << " is_loading=" << contents_ptr->IsLoading()
                   << " RFLive="
                   << contents_ptr->GetPrimaryMainFrame()->IsRenderFrameLive();
    }
  }
  return reinterpret_cast<SephriumWebContentsRef>(holder);
}

extern "C" void SephriumWebContentsDestroy(SephriumWebContentsRef ref) {
  if (!ref) return;
  delete AsHolder(ref);
}

extern "C" void* SephriumWebContentsGetNativeView(
    SephriumWebContentsRef ref) {
  if (!ref) return nullptr;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return nullptr;
  gfx::NativeView view = c->GetNativeView();
  return (__bridge void*)view.GetNativeNSView();
}

extern "C" void SephriumWebContentsLoadURL(SephriumWebContentsRef ref,
                                          const char* url) {
  if (!ref || !url) return;
  GURL gurl(url);
  if (!gurl.is_valid()) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  c->GetController().LoadURL(
      gurl, content::Referrer(),
      ui::PageTransitionFromInt(ui::PAGE_TRANSITION_TYPED |
                                ui::PAGE_TRANSITION_FROM_ADDRESS_BAR),
      std::string());
}

extern "C" void SephriumWebContentsGoBack(SephriumWebContentsRef ref) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  auto& controller = c->GetController();
  if (controller.CanGoBack()) controller.GoBack();
}

extern "C" void SephriumWebContentsGoForward(SephriumWebContentsRef ref) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  auto& controller = c->GetController();
  if (controller.CanGoForward()) controller.GoForward();
}

extern "C" void SephriumWebContentsReload(SephriumWebContentsRef ref) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  // Reload() on a controller with no committed entry crashes inside
  // NavigationControllerImpl::Reload (DCHECK on last_committed_entry).
  // Bail early if the page never loaded.
  if (c->GetController().GetEntryCount() == 0) return;
  c->GetController().Reload(
      content::ReloadType::NORMAL, /*check_for_repost=*/false);
}

extern "C" void SephriumWebContentsStop(SephriumWebContentsRef ref) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  c->Stop();
}

extern "C" void SephriumWebContentsSetSize(SephriumWebContentsRef ref,
                                          int w,
                                          int h) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  // Clamp to non-negative; very-large is OK because gfx::Rect uses int.
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  c->Resize(gfx::Rect(0, 0, w, h));
}

extern "C" void SephriumWebContentsFocus(SephriumWebContentsRef ref) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  c->Focus();
}

extern "C" void SephriumWebContentsSetFrozen(SephriumWebContentsRef ref,
                                            int frozen) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  if (frozen) {
    // Pair Hidden + SetPageFrozen so the renderer's paint+raf loop is
    // actually paused, not just marked frozen at the page lifecycle layer.
    c->WasHidden();
    c->SetPageFrozen(true);
  } else {
    c->SetPageFrozen(false);
    // Without WasShown the renderer keeps its paint loop parked even after
    // the page lifecycle flag flips back. Symptom: animations + WebGL stay
    // stalled on the first frame after unfreeze.
    c->WasShown();
  }
}

extern "C" void SephriumWebContentsSetVisible(SephriumWebContentsRef ref,
                                             int visible) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  // Visibility ONLY — no SetPageFrozen, no Focus. Safe before the initial
  // navigation commits (WasShown/WasHidden never DCHECK pre-nav, unlike
  // SetFrozen/Focus). Driven by CALWebView window membership: a tab's view
  // entering a window flips this to visible, which gives the browser-side
  // compositor the hidden->visible transition it needs to request a fresh
  // frame for the now-attached surface. This is the embedder's half of the
  // foreground/background-tab contract that content::WebContents expects.
  if (visible) {
    c->WasShown();
  } else {
    c->WasHidden();
  }
}

extern "C" char* SephriumWebContentsCopyURL(SephriumWebContentsRef ref) {
  if (!ref) return DupCString(std::string());
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return DupCString(std::string());
  return DupCString(c->GetLastCommittedURL().spec());
}

extern "C" char* SephriumWebContentsCopyTitle(SephriumWebContentsRef ref) {
  if (!ref) return DupCString(std::string());
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return DupCString(std::string());
  return DupCString(base::UTF16ToUTF8(c->GetTitle()));
}

extern "C" void SephriumWebContentsSetNavCallback(SephriumWebContentsRef ref,
                                                 SephriumNavCallback cb,
                                                 void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetNavCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetFaviconCallback(
    SephriumWebContentsRef ref,
    SephriumFaviconCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetFaviconCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetLoadingCallback(
    SephriumWebContentsRef ref,
    SephriumLoadingCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetLoadingCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetNewTabRequestCallback(
    SephriumWebContentsRef ref,
    SephriumNewTabRequestCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetNewTabRequestCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetTargetURLCallback(
    SephriumWebContentsRef ref,
    SephriumTargetURLCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetTargetURLCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetPopupRequestCallback(
    SephriumWebContentsRef ref,
    SephriumPopupRequestCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetPopupRequestCallback(cb, ctx);
}

extern "C" void SephriumWebContentsSetCloseRequestCallback(
    SephriumWebContentsRef ref,
    SephriumCloseRequestCallback cb,
    void* ctx) {
  if (!ref) return;
  AsHolder(ref)->SetCloseRequestCallback(cb, ctx);
}

extern "C" void SephriumWebContentsCaptureSnapshot(
    SephriumWebContentsRef ref,
    int w,
    int h,
    SephriumSnapshotCallback callback,
    void* ctx) {
  if (!callback) return;
  if (!ref || w <= 0 || h <= 0) {
    callback(ctx, nullptr, 0, 0, 0);
    return;
  }
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) {
    callback(ctx, nullptr, 0, 0, 0);
    return;
  }
  content::RenderWidgetHostView* rwhv = c->GetRenderWidgetHostView();
  if (!rwhv) {
    callback(ctx, nullptr, 0, 0, 0);
    return;
  }
  // Wrap callback in a scoped guard so that if CopyFromSurface drops the
  // base::OnceCallback without invoking it (the surface tear-down path),
  // we still fire the embedder's callback with an empty bitmap. Otherwise
  // the embedder's completion block sits in a leaked SnapshotCtx forever.
  struct SnapshotGuard {
    SephriumSnapshotCallback cb;
    void* ctx;
    bool fired = false;
    ~SnapshotGuard() {
      if (!fired && cb) cb(ctx, nullptr, 0, 0, 0);
    }
  };
  auto guard = std::make_unique<SnapshotGuard>();
  guard->cb = callback;
  guard->ctx = ctx;
  rwhv->CopyFromSurface(
      gfx::Rect(), gfx::Size(w, h), base::Seconds(5),
      base::BindOnce(
          [](std::unique_ptr<SnapshotGuard> guard,
             const content::CopyFromSurfaceResult& result) {
            guard->fired = true;
            if (!result.has_value()) {
              guard->cb(guard->ctx, nullptr, 0, 0, 0);
              return;
            }
            const SkBitmap& bitmap = result->bitmap;
            if (bitmap.isNull() || !bitmap.getPixels()) {
              guard->cb(guard->ctx, nullptr, 0, 0, 0);
              return;
            }
            guard->cb(guard->ctx, bitmap.getPixels(),
                      bitmap.width(), bitmap.height(),
                      static_cast<int>(bitmap.rowBytes()));
          },
          std::move(guard)));
}

// ---- String helper --------------------------------------------------------

extern "C" void SephriumStringFree(char* s) {
  std::free(s);
}
