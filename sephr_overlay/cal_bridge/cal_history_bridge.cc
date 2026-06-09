// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// Phase 4 — History bridge. Wires the C ABI declared in cal_bridge.h to
// Chromium's `HistoryService`.

#include "chrome/sephr/cal_bridge/cal_bridge.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "url/gurl.h"

namespace {

// Per-process CancelableTaskTracker that owns all in-flight HistoryService
// calls coming through the bridge. Sized for a single embedder; lives for
// the process lifetime (NoDestructor).
base::CancelableTaskTracker& BridgeTracker() {
  static base::NoDestructor<base::CancelableTaskTracker> tracker;
  return *tracker;
}

// Heap-allocated row used to keep the strings alive across the callback
// boundary. The C ABI hands out `const char*` pointers; the callee is
// expected to copy what it needs synchronously.
struct OwnedEntry {
  std::string url;
  std::string title;
  SephriumHistoryEntry view;
};

void OnQueryHistoryComplete(SephriumHistoryCallback callback,
                            void* ctx,
                            int limit,
                            history::QueryResults results) {
  if (!callback) {
    return;
  }
  const int count =
      std::min(static_cast<int>(results.size()), std::max(limit, 0));
  // Coalesce string storage so the SephriumHistoryEntry array we hand out is
  // contiguous.
  std::vector<OwnedEntry> owned(static_cast<size_t>(count));
  std::vector<SephriumHistoryEntry> entries(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    const auto& r = results[static_cast<size_t>(i)];
    owned[i].url = r.url().spec();
    owned[i].title = base::UTF16ToUTF8(r.title());
    auto& e = entries[i];
    e.url = owned[i].url.c_str();
    e.title = owned[i].title.c_str();
    e.visited_at = r.visit_time().InSecondsFSinceUnixEpoch();
    e.visit_count = r.visit_count();
  }
  callback(ctx, entries.empty() ? nullptr : entries.data(), count);
}

content::BrowserContext* AsContext(SephriumProfileRef ref) {
  return reinterpret_cast<content::BrowserContext*>(ref);
}

history::HistoryService* GetHistoryService(SephriumProfileRef ref) {
  if (!ref) return nullptr;
  auto* ctx = AsContext(ref);
  if (!ctx) return nullptr;
  return HistoryServiceFactory::GetForProfile(
      Profile::FromBrowserContext(ctx), ServiceAccessType::EXPLICIT_ACCESS);
}

}  // namespace

extern "C" void SephriumHistoryQuery(SephriumProfileRef profile,
                                    const char* search_text,
                                    int limit,
                                    SephriumHistoryCallback callback,
                                    void* ctx) {
  history::HistoryService* hs = GetHistoryService(profile);
  if (!hs || !callback) {
    if (callback) callback(ctx, nullptr, 0);
    return;
  }
  history::QueryOptions options;
  options.max_count = limit > 0 ? limit : 100;
  // Most-recent first ordering matches the user's mental model and the
  // existing CALHistory contract.
  options.duplicate_policy =
      history::QueryOptions::REMOVE_DUPLICATES_PER_DAY;

  const std::u16string query =
      base::UTF8ToUTF16(search_text ? search_text : "");

  hs->QueryHistory(
      query, options,
      base::BindOnce(&OnQueryHistoryComplete, callback, ctx, options.max_count),
      &BridgeTracker());
}

extern "C" void SephriumHistoryDeleteURL(SephriumProfileRef profile,
                                        const char* url) {
  if (!url) return;
  history::HistoryService* hs = GetHistoryService(profile);
  if (!hs) return;
  GURL gurl(url);
  if (!gurl.is_valid()) return;
  hs->DeleteURLs({gurl});
}

extern "C" void SephriumHistoryClearAll(SephriumProfileRef profile) {
  history::HistoryService* hs = GetHistoryService(profile);
  if (!hs) return;
  // Expire everything; passes empty restrict set + (-inf, now) range.
  hs->ExpireHistoryBetween(/*restrict_urls=*/{},
                           /*restrict_app_id=*/std::nullopt,
                           base::Time(), base::Time::Now(),
                           /*user_initiated=*/true,
                           base::DoNothing(), &BridgeTracker());
}
