// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#include "chrome/sephr/cal_bridge/cal_tab_window_controller.h"

#include "chrome/browser/extensions/window_controller_list.h"
#include "chrome/common/extensions/api/tabs.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace sephr {

CalTabWindowController::CalTabWindowController(content::WebContents* contents,
                                              Profile* profile)
    : extensions::WindowController(/*window=*/nullptr, profile),
      contents_(contents),
      window_id_(SessionID::NewUnique()) {
  extensions::WindowControllerList::GetInstance()->AddExtensionWindow(this);
}

CalTabWindowController::~CalTabWindowController() {
  extensions::WindowControllerList::GetInstance()->RemoveExtensionWindow(this);
}

int CalTabWindowController::GetWindowId() const {
  return window_id_.id();
}

std::string CalTabWindowController::GetWindowTypeText() const {
  return extensions::api::tabs::ToString(
      extensions::api::tabs::WindowType::kNormal);
}

void CalTabWindowController::SetFullscreenMode(
    bool is_fullscreen,
    const GURL& extension_url) const {
  // CAL drives fullscreen on the Swift side; nothing to do here.
}

content::WebContents* CalTabWindowController::GetActiveTab() const {
  return contents_;
}

int CalTabWindowController::GetTabCount() const {
  return 1;
}

content::WebContents* CalTabWindowController::GetWebContentsAt(int i) const {
  return i == 0 ? contents_.get() : nullptr;
}

bool CalTabWindowController::IsVisibleToTabsAPIForExtension(
    const extensions::Extension* extension,
    bool include_dev_tools_windows) const {
  // A CAL tab is an ordinary web tab — visible to any extension; the API layer
  // enforces the relevant tabs permission separately.
  return true;
}

base::DictValue CalTabWindowController::CreateWindowValueForExtension(
    const extensions::Extension* extension,
    PopulateTabBehavior populate_tab_behavior,
    extensions::mojom::ContextType context) const {
  // Window-level enumeration is not modeled for CAL tabs; the per-tab APIs
  // that matter (zoom, tabs.get) don't consult this. Mirror AppWindowController
  // and return an empty value rather than fabricate window geometry.
  return base::DictValue();
}

base::ListValue CalTabWindowController::CreateTabList(
    const extensions::Extension* extension,
    extensions::mojom::ContextType context) const {
  return base::ListValue();
}

bool CalTabWindowController::OpenOptionsPage(
    const extensions::Extension* extension,
    const GURL& url,
    bool open_in_tab) {
  return false;
}

}  // namespace sephr
