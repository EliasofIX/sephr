// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// Phase 4 — Downloads bridge. Wires the C ABI declared in cal_bridge.h to
// Chromium's `DownloadManager`. Subscribe pattern: one observer per
// browser_context; the observer rebuilds a flat snapshot and hands it to
// the embedder callback whenever an item changes.

#include "chrome/sephr/cal_bridge/cal_bridge.h"

#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "url/gurl.h"

namespace {

content::BrowserContext* AsContext(SephriumProfileRef ref) {
  return reinterpret_cast<content::BrowserContext*>(ref);
}

content::DownloadManager* GetDownloadManager(SephriumProfileRef ref) {
  if (!ref) return nullptr;
  return AsContext(ref)->GetDownloadManager();
}

struct OwnedDownload {
  std::string id, url, target, mime;
  SephriumDownloadEntry view;
};

int MapState(download::DownloadItem::DownloadState s) {
  switch (s) {
    case download::DownloadItem::IN_PROGRESS: return 0;
    case download::DownloadItem::COMPLETE:    return 1;
    case download::DownloadItem::CANCELLED:   return 2;
    case download::DownloadItem::INTERRUPTED: return 3;
    case download::DownloadItem::MAX_DOWNLOAD_STATE: return 0;
  }
  return 0;
}

// One bridge observer per BrowserContext. It owns the DownloadManager
// observation, plus a per-item observation so the subscriber sees update
// pulses on bytes_received changes too.
//
// Snapshot() is throttled — an active download fires OnDownloadUpdated
// roughly every 50ms (the Chromium DownloadStats sampling cadence). Each
// snapshot allocates O(N) strings and crosses the C ABI, so without
// throttling a single download saturates the UI thread with allocator
// noise. We coalesce updates inside a 100ms window: the first event
// fires immediately, subsequent events within the window are merged
// into a single trailing-edge snapshot.
class BridgeObserver : public content::DownloadManager::Observer,
                       public download::DownloadItem::Observer {
 public:
  BridgeObserver(content::DownloadManager* manager,
                 SephriumDownloadsCallback callback,
                 void* ctx)
      : manager_(manager), callback_(callback), ctx_(ctx) {
    manager_->AddObserver(this);
    std::vector<raw_ptr<download::DownloadItem, VectorExperimental>> items;
    manager_->GetAllDownloads(&items);
    for (auto& it : items) {
      it->AddObserver(this);
    }
    Snapshot();  // initial snapshot is always immediate
  }
  ~BridgeObserver() override {
    if (!manager_) return;
    std::vector<raw_ptr<download::DownloadItem, VectorExperimental>> items;
    manager_->GetAllDownloads(&items);
    for (auto& it : items) {
      it->RemoveObserver(this);
    }
    manager_->RemoveObserver(this);
  }

  // content::DownloadManager::Observer:
  void OnDownloadCreated(content::DownloadManager*,
                         download::DownloadItem* item) override {
    item->AddObserver(this);
    Snapshot();  // structural change — fire immediately
  }
  void OnManagerInitialized() override { Snapshot(); }
  void ManagerGoingDown(content::DownloadManager* manager) override {
    manager_ = nullptr;
  }

  // download::DownloadItem::Observer:
  // Byte-update events: throttled so the embedder doesn't get blasted at
  // 20Hz per download.
  void OnDownloadUpdated(download::DownloadItem*) override {
    ScheduleSnapshot();
  }
  void OnDownloadOpened(download::DownloadItem*) override { Snapshot(); }
  void OnDownloadRemoved(download::DownloadItem* item) override {
    item->RemoveObserver(this);
    Snapshot();  // structural change — fire immediately
  }
  void OnDownloadDestroyed(download::DownloadItem* item) override {
    item->RemoveObserver(this);
  }

 private:
  void Snapshot() {
    snapshot_scheduled_ = false;
    if (!manager_ || !callback_) return;
    std::vector<raw_ptr<download::DownloadItem, VectorExperimental>> items;
    manager_->GetAllDownloads(&items);
    std::vector<OwnedDownload> owned(items.size());
    std::vector<SephriumDownloadEntry> entries(items.size());
    for (size_t i = 0; i < items.size(); ++i) {
      download::DownloadItem* it = items[i];
      owned[i].id = std::to_string(it->GetId());
      owned[i].url = it->GetURL().spec();
      owned[i].target = it->GetTargetFilePath().AsUTF8Unsafe();
      owned[i].mime = it->GetMimeType();
      auto& v = entries[i];
      v.identifier    = owned[i].id.c_str();
      v.url           = owned[i].url.c_str();
      v.target_path   = owned[i].target.c_str();
      v.mime_type     = owned[i].mime.c_str();
      v.total_bytes   = it->GetTotalBytes();
      v.received_bytes = it->GetReceivedBytes();
      v.state = it->IsPaused() ? 4 : MapState(it->GetState());
    }
    callback_(ctx_,
              entries.empty() ? nullptr : entries.data(),
              static_cast<int>(entries.size()));
  }

  // Coalesces snapshots inside a 100ms window. The first scheduled event
  // posts a delayed task; subsequent calls before the task fires are
  // dropped (snapshot_scheduled_=true). Net effect: <= 10 snapshots/sec
  // per download regardless of update frequency.
  void ScheduleSnapshot() {
    if (snapshot_scheduled_) return;
    snapshot_scheduled_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&BridgeObserver::Snapshot,
                       weak_factory_.GetWeakPtr()),
        base::Milliseconds(100));
  }

  raw_ptr<content::DownloadManager> manager_;
  SephriumDownloadsCallback callback_;
  void* ctx_;
  bool snapshot_scheduled_ = false;
  base::WeakPtrFactory<BridgeObserver> weak_factory_{this};
};

// Subscribers keyed by BrowserContext pointer.
std::map<content::BrowserContext*, std::unique_ptr<BridgeObserver>>&
GlobalSubscribers() {
  static base::NoDestructor<
      std::map<content::BrowserContext*, std::unique_ptr<BridgeObserver>>>
      m;
  return *m;
}

download::DownloadItem* FindItem(SephriumProfileRef ref,
                                 const char* identifier) {
  content::DownloadManager* m = GetDownloadManager(ref);
  if (!m || !identifier) return nullptr;
  std::vector<raw_ptr<download::DownloadItem, VectorExperimental>> items;
  m->GetAllDownloads(&items);
  for (auto& it : items) {
    if (std::to_string(it->GetId()) == identifier) {
      return it.get();
    }
  }
  return nullptr;
}

}  // namespace

extern "C" void SephriumDownloadsSubscribe(SephriumProfileRef profile,
                                          SephriumDownloadsCallback callback,
                                          void* ctx) {
  content::DownloadManager* m = GetDownloadManager(profile);
  if (!m) {
    if (callback) callback(ctx, nullptr, 0);
    return;
  }
  auto& subs = GlobalSubscribers();
  subs.erase(AsContext(profile));
  if (callback) {
    subs[AsContext(profile)] =
        std::make_unique<BridgeObserver>(m, callback, ctx);
  }
}

extern "C" void SephriumDownloadPause(SephriumProfileRef p, const char* id) {
  if (auto* it = FindItem(p, id)) it->Pause();
}
extern "C" void SephriumDownloadResume(SephriumProfileRef p, const char* id) {
  if (auto* it = FindItem(p, id)) it->Resume(/*user_resume=*/true);
}
extern "C" void SephriumDownloadCancel(SephriumProfileRef p, const char* id) {
  if (auto* it = FindItem(p, id)) it->Cancel(/*user_cancel=*/true);
}
