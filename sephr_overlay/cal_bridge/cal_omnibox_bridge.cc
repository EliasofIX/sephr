// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// Phase 4 — Omnibox bridge. Wires the C ABI to Chromium's
// `AutocompleteController`. Each call is fire-and-forget: SephriumOmniboxQuery
// starts a controller, waits for its done-notification, then hands a flat
// snapshot of results to the callback and tears the controller down.

#include "chrome/sephr/cal_bridge/cal_bridge.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/profiles/profile.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_match_type.h"
#include "components/omnibox/browser/autocomplete_provider.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "url/gurl.h"

namespace {

content::BrowserContext* AsContext(SephriumProfileRef ref) {
  return reinterpret_cast<content::BrowserContext*>(ref);
}

// One-shot adapter: takes ownership of itself and the controller, fires the
// callback when results are done, then self-destructs.
class OneShotObserver : public AutocompleteController::Observer {
 public:
  OneShotObserver(std::unique_ptr<AutocompleteController> controller,
                  SephriumOmniboxCallback callback,
                  void* ctx)
      : controller_(std::move(controller)),
        callback_(callback),
        ctx_(ctx) {
    controller_->AddObserver(this);
  }
  ~OneShotObserver() override {
    if (controller_) {
      controller_->RemoveObserver(this);
    }
  }

  void OnResultChanged(AutocompleteController* controller,
                       bool default_match_changed) override {
    if (!controller || !controller->done()) {
      return;
    }
    // Guard against re-entrant fire — Chromium has been known to call
    // OnResultChanged twice with done=true under some provider stacks; a
    // second `delete this` is UAF.
    if (done_fired_) return;
    done_fired_ = true;
    Emit(controller->result());
    // DeleteSoon rather than `delete this` — Start() can synchronously
    // call OnResultChanged when all providers return cached results,
    // which would tear down the controller mid-call and leave the
    // outer Start frame walking freed memory. Posting unwinds the stack
    // first.
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                this);
  }

  AutocompleteController* controller() { return controller_.get(); }

 private:
  struct OwnedResult {
    std::string type, contents, description, url;
    SephriumOmniboxResult view;
  };

  void Emit(const AutocompleteResult& result) {
    std::vector<OwnedResult> owned(result.size());
    std::vector<SephriumOmniboxResult> entries(result.size());
    for (size_t i = 0; i < result.size(); ++i) {
      const AutocompleteMatch& m = result.match_at(i);
      owned[i].type        = AutocompleteMatchType::ToString(m.type);
      owned[i].contents    = base::UTF16ToUTF8(m.contents);
      owned[i].description = base::UTF16ToUTF8(m.description);
      owned[i].url         = m.destination_url.spec();
      auto& e = entries[i];
      e.type            = owned[i].type.c_str();
      e.contents        = owned[i].contents.c_str();
      e.description     = owned[i].description.c_str();
      e.destination_url = owned[i].url.c_str();
    }
    if (callback_) {
      callback_(ctx_,
                entries.empty() ? nullptr : entries.data(),
                static_cast<int>(entries.size()));
    }
  }

  std::unique_ptr<AutocompleteController> controller_;
  SephriumOmniboxCallback callback_;
  void* ctx_;
  bool done_fired_ = false;
};

}  // namespace

extern "C" void SephriumOmniboxQuery(SephriumProfileRef profile_ref,
                                    const char* input_text,
                                    SephriumOmniboxCallback callback,
                                    void* ctx) {
  // Phase 4 short-circuit: ChromeAutocompleteProviderClient depends on a
  // graph of KeyedServices (HistoryService, TemplateURLService,
  // ShortcutsBackend, BookmarkModel) that only get fully wired when a
  // Chrome `Browser` is alive. In Sephr we run with raw WebContents and
  // no Browser, so `AutocompleteController::Start` crashes deep inside
  // one of those providers as soon as the user types.
  //
  // Until we either bring up the missing services manually or wire a
  // hidden, headless Browser, return an empty result synchronously and
  // let the Swift side fall back to local tab matching + the default
  // search URL. The Swift command bar already does both.
  (void)profile_ref;
  (void)input_text;
  if (callback) callback(ctx, nullptr, 0);
}

// Original Browser-dependent implementation, kept here for reference so
// the next pass can re-enable it once we wire the KeyedServices we need.
[[maybe_unused]] static void SephriumOmniboxQuery_DEPRECATED(
    SephriumProfileRef profile_ref,
    const char* input_text,
    SephriumOmniboxCallback callback,
    void* ctx) {
  if (!profile_ref || !callback) {
    if (callback) callback(ctx, nullptr, 0);
    return;
  }
  Profile* profile = Profile::FromBrowserContext(AsContext(profile_ref));
  if (!profile) {
    callback(ctx, nullptr, 0);
    return;
  }
  auto provider_client =
      std::make_unique<ChromeAutocompleteProviderClient>(profile);
  AutocompleteControllerConfig config;
  config.provider_types = AutocompleteClassifier::DefaultOmniboxProviders();
  auto controller = std::make_unique<AutocompleteController>(
      std::move(provider_client), config);
  AutocompleteInput input(base::UTF8ToUTF16(input_text ? input_text : ""),
                          metrics::OmniboxEventProto::OTHER,
                          ChromeAutocompleteSchemeClassifier(profile));
  auto* observer = new OneShotObserver(std::move(controller), callback, ctx);
  observer->controller()->Start(input);
  // If Start fired the done callback synchronously, the observer
  // self-deletes via DeleteSoon — safe to return now either way.
}
