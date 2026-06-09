// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#include "chrome/sephr/cal_bridge/sephr_modal_dialog_manager_delegate.h"

#include "chrome/sephr/cal_bridge/sephr_modal_dialog_host.h"
#include "content/public/browser/web_contents.h"

namespace sephr {

SephrModalDialogManagerDelegate::SephrModalDialogManagerDelegate(
    content::WebContents* web_contents)
    : host_(std::make_unique<SephrModalDialogHost>(web_contents)) {}

SephrModalDialogManagerDelegate::~SephrModalDialogManagerDelegate() = default;

web_modal::WebContentsModalDialogHost*
SephrModalDialogManagerDelegate::GetWebContentsModalDialogHost(
    content::WebContents* /*web_contents*/) {
  return host_.get();
}

bool SephrModalDialogManagerDelegate::IsWebContentsVisible(
    content::WebContents* /*web_contents*/) {
  // CAL only spawns a WebContents to host inside an on-screen CALWebView,
  // so we treat every Sephr-owned WebContents as visible. Off-screen
  // background-tab semantics are a Phase 3 concern.
  return true;
}

void SephrModalDialogManagerDelegate::SetWebContentsBlocked(
    content::WebContents* /*web_contents*/,
    bool /*blocked*/) {
  // No-op for now. Future: surface a `setRendererBlocked` C ABI so CAL/
  // Swift can grey out the WebView while a modal sheet is displayed.
}

}  // namespace sephr
