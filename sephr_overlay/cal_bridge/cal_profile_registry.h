// Copyright (c) Sephr. All rights reserved.
#ifndef CHROME_SEPHR_CAL_BRIDGE_CAL_PROFILE_REGISTRY_H_
#define CHROME_SEPHR_CAL_BRIDGE_CAL_PROFILE_REGISTRY_H_

#include <map>
#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/no_destructor.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace sephr {

// Internal-only mapping from CAL profile_id strings to live BrowserContext*
// instances. Resolved against ProfileManager when running inside the full
// chrome browser process. Must only be touched on the UI thread.
class CalProfileRegistry {
 public:
  static CalProfileRegistry& Get();

  content::BrowserContext* GetOrCreate(const std::string& profile_id,
                                       const base::FilePath& disk_path);
  void Release(const std::string& profile_id);

 private:
  friend class base::NoDestructor<CalProfileRegistry>;
  CalProfileRegistry();
  ~CalProfileRegistry();

  std::map<std::string, content::BrowserContext*> contexts_;
};

}  // namespace sephr

#endif  // CHROME_SEPHR_CAL_BRIDGE_CAL_PROFILE_REGISTRY_H_
