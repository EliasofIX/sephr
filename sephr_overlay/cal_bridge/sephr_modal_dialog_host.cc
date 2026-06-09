// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#include "chrome/sephr/cal_bridge/sephr_modal_dialog_host.h"

#include <algorithm>

#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

namespace sephr {

SephrModalDialogHost::SephrModalDialogHost(content::WebContents* web_contents)
    : web_contents_(web_contents) {}

SephrModalDialogHost::~SephrModalDialogHost() {
  // Contract from web_modal::ModalDialogHost: notify every observer before
  // destruction so they can null their host pointer before it goes away.
  for (auto& observer : observers_) {
    observer.OnHostDestroying();
  }
}

gfx::NativeView SephrModalDialogHost::GetHostView() const {
  return web_contents_ ? web_contents_->GetNativeView() : gfx::NativeView();
}

gfx::Point SephrModalDialogHost::GetDialogPosition(const gfx::Size& size) {
  // Top-centered, matching the BrowserView default for tab-modal dialogs.
  // Coordinates are relative to the host view (GetHostView above).
  const gfx::Size container = GetMaximumDialogSize();
  const int x = std::max(0, (container.width() - size.width()) / 2);
  return gfx::Point(x, 0);
}

gfx::Size SephrModalDialogHost::GetMaximumDialogSize() {
  if (!web_contents_) {
    return gfx::Size();
  }
  return web_contents_->GetContainerBounds().size();
}

void SephrModalDialogHost::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.AddObserver(observer);
}

void SephrModalDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.RemoveObserver(observer);
}

}  // namespace sephr
