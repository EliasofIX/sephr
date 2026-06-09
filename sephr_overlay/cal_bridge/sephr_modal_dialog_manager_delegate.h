// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#ifndef CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_MANAGER_DELEGATE_H_
#define CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_MANAGER_DELEGATE_H_

#include <memory>

#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"

namespace content {
class WebContents;
}

namespace sephr {

class SephrModalDialogHost;

// Per-WebContents delegate that answers web_modal's lookup queries and
// owns the matching SephrModalDialogHost.
//
// Stock Chrome's delegate is BrowserView; Sephr has no BrowserView so we
// supply our own. See SephrModalDialogHost for why this is required and
// what stops working without it (every constrained_window modal SIGSEGVs).
//
// Lifetime: owned by SephriumWebContentsHolder via unique_ptr, so the
// delegate dies before the holder's WebContents (and therefore before
// the WebContentsModalDialogManager that holds the raw delegate pointer
// — but the manager is itself owned as user-data on the WebContents and
// destructed during WebContents teardown, after the holder has already
// nulled its delegate pointer in ~SephriumWebContentsHolder).
class SephrModalDialogManagerDelegate
    : public web_modal::WebContentsModalDialogManagerDelegate {
 public:
  explicit SephrModalDialogManagerDelegate(content::WebContents* web_contents);

  SephrModalDialogManagerDelegate(const SephrModalDialogManagerDelegate&) =
      delete;
  SephrModalDialogManagerDelegate& operator=(
      const SephrModalDialogManagerDelegate&) = delete;

  ~SephrModalDialogManagerDelegate() override;

  // web_modal::WebContentsModalDialogManagerDelegate
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(
      content::WebContents* web_contents) override;
  bool IsWebContentsVisible(content::WebContents* web_contents) override;
  void SetWebContentsBlocked(content::WebContents* web_contents,
                             bool blocked) override;

 private:
  std::unique_ptr<SephrModalDialogHost> host_;
};

}  // namespace sephr

#endif  // CHROME_SEPHR_CAL_BRIDGE_SEPHR_MODAL_DIALOG_MANAGER_DELEGATE_H_
