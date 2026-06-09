// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.

#ifndef CHROME_SEPHR_CAL_BRIDGE_CAL_TAB_WINDOW_CONTROLLER_H_
#define CHROME_SEPHR_CAL_BRIDGE_CAL_TAB_WINDOW_CONTROLLER_H_

#include <string>

#include "base/memory/raw_ptr.h"
#include "base/values.h"
#include "chrome/browser/extensions/window_controller.h"
#include "components/sessions/core/session_id.h"
#include "extensions/common/mojom/context_type.mojom-forward.h"

class GURL;
class Profile;

namespace content {
class WebContents;
}

namespace extensions {
class Extension;
}

namespace sephr {

// An extensions::WindowController that exposes a single CAL-created
// WebContents as a one-tab "window" to the chrome.tabs / chrome.windows
// extension APIs.
//
// CAL embeds raw content::WebContents that never live inside a Chrome
// Browser/TabStripModel, so extensions::ExtensionTabUtil::GetTabById — which
// only walks WindowControllerList — cannot find them. Any feature that calls
// the tabs API for its own tab then fails. Most visibly the bundled PDF
// viewer: its browser_api.js calls chrome.tabs.getZoomSettings()/get() during
// startup and, when the lookup yields nothing, throws on the undefined result
// and never finishes initializing — the PDF paints blank.
//
// Registering one controller per holder makes each CAL tab resolvable. One
// controller == one tab == one window: a simplification (a real CAL window
// holds many tabs, tracked Swift-side) but sufficient for the per-tab APIs
// (zoom, tabs.get, messaging) that actually need a resolvable tab id.
//
// The base ui::BaseWindow* is intentionally null. Only window-level APIs
// (e.g. chrome.windows.get/update targeting this synthetic window id) would
// dereference it, and CAL never drives those against these controllers;
// per-tab lookups use GetWindowId()/GetWebContentsAt() only.
class CalTabWindowController : public extensions::WindowController {
 public:
  CalTabWindowController(content::WebContents* contents, Profile* profile);
  CalTabWindowController(const CalTabWindowController&) = delete;
  CalTabWindowController& operator=(const CalTabWindowController&) = delete;
  ~CalTabWindowController() override;

  // extensions::WindowController:
  int GetWindowId() const override;
  std::string GetWindowTypeText() const override;
  void SetFullscreenMode(bool is_fullscreen,
                         const GURL& extension_url) const override;
  content::WebContents* GetActiveTab() const override;
  int GetTabCount() const override;
  content::WebContents* GetWebContentsAt(int i) const override;
  bool IsVisibleToTabsAPIForExtension(
      const extensions::Extension* extension,
      bool include_dev_tools_windows) const override;
  base::DictValue CreateWindowValueForExtension(
      const extensions::Extension* extension,
      PopulateTabBehavior populate_tab_behavior,
      extensions::mojom::ContextType context) const override;
  base::ListValue CreateTabList(
      const extensions::Extension* extension,
      extensions::mojom::ContextType context) const override;
  bool OpenOptionsPage(const extensions::Extension* extension,
                       const GURL& url,
                       bool open_in_tab) override;

 private:
  const raw_ptr<content::WebContents> contents_;
  const SessionID window_id_;
};

}  // namespace sephr

#endif  // CHROME_SEPHR_CAL_BRIDGE_CAL_TAB_WINDOW_CONTROLLER_H_
