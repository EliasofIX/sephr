// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#ifndef CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_HOST_H_
#define CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_HOST_H_

#include "base/memory/raw_ptr.h"
#include "base/observer_list.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "ui/gfx/native_ui_types.h"

namespace content {
class WebContents;
}

namespace sephr {

// Per-WebContents modal dialog host for Sephr.
//
// Stock Chrome routes modal dialogs (WebAuthn picker, permission prompts,
// certificate viewer, save-password bubble, …) through BrowserView, which
// acts as both WebContentsModalDialogManagerDelegate AND ModalDialogHost.
// Sephr has no Browser/BrowserView — it hosts a bare WebContents inside a
// CALWebView NSView — so without our own delegate/host, every
// `constrained_window::CreateWebModalDialogViews` call dereferences a null
// `manager->delegate()` and SIGSEGVs.
//
// This host returns the WebContents' native NSView as the parent for
// the modal sheet. Positioning is top-centered within the WebContents
// bounds, matching the BrowserView default.
class SephrModalDialogHost : public web_modal::WebContentsModalDialogHost {
 public:
  explicit SephrModalDialogHost(content::WebContents* web_contents);

  SephrModalDialogHost(const SephrModalDialogHost&) = delete;
  SephrModalDialogHost& operator=(const SephrModalDialogHost&) = delete;

  ~SephrModalDialogHost() override;

  // web_modal::ModalDialogHost
  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;

  // web_modal::WebContentsModalDialogHost
  gfx::Size GetMaximumDialogSize() override;

 private:
  raw_ptr<content::WebContents> web_contents_;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
};

}  // namespace sephr

#endif  // CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_HOST_H_
