// Copyright (c) Sephr. All rights reserved.
#include "chrome/sephr/cal_bridge/cal_profile_registry.h"

#include "base/no_destructor.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"

namespace sephr {

// static
CalProfileRegistry& CalProfileRegistry::Get() {
  static base::NoDestructor<CalProfileRegistry> instance;
  return *instance;
}

CalProfileRegistry::CalProfileRegistry() = default;
CalProfileRegistry::~CalProfileRegistry() = default;

content::BrowserContext* CalProfileRegistry::GetOrCreate(
    const std::string& profile_id,
    const base::FilePath& disk_path) {
  auto it = contexts_.find(profile_id);
  if (it != contexts_.end()) {
    return it->second;
  }

  // Phase 4 update: route through Chromium's "active user" path rather
  // than the lower-level GetProfile(path). For the non-isolated default
  // profile this returns the same profile Chrome's PostBrowserStart
  // already booted — fully wired into Network Service, StoragePartition,
  // KeyedService graph etc. Using GetProfile(path) directly can return a
  // Profile that's missing the Network Service binding the browser
  // process set up at startup, which leaves WebContents with a
  // never-resolving URLLoaderFactory and the page never commits.
  if (!g_browser_process || !g_browser_process->profile_manager()) {
    return nullptr;
  }
  ProfileManager* pm = g_browser_process->profile_manager();

  Profile* profile = nullptr;
  if (profile_id == "Default" || profile_id == "default") {
    // GetLastUsedProfile is a static helper that resolves via the global
    // ProfileManager. It returns the profile Chromium booted into (or
    // creates one if first launch). Crucially, the returned Profile has
    // already been routed through the full PostProfileInit flow so its
    // Network Service binding is live — which the lower-level
    // GetProfile(path) call does NOT guarantee.
    profile = ProfileManager::GetLastUsedProfile();
  } else {
    // Isolated space — get-or-create at the requested disk path.
    profile = pm->GetProfile(disk_path);
  }
  if (!profile) {
    return nullptr;
  }

  contexts_.emplace(profile_id, profile);
  return profile;
}

void CalProfileRegistry::Release(const std::string& profile_id) {
  // Phase 1: registry holds non-owning pointers (ProfileManager owns the
  // Profile). Release simply forgets the mapping; the BrowserContext is
  // torn down by ProfileManager at shutdown.
  contexts_.erase(profile_id);
}

}  // namespace sephr

