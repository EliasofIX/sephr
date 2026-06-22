// Copyright (c) Sephr. All rights reserved.

#include "chrome/sephr/builtin_extensions/ublock_installer.h"

#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "build/buildflag.h"
#include "chrome/browser/extensions/component_loader.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_paths.h"
#include "extensions/buildflags/buildflags.h"
#include "extensions/common/file_util.h"
#include "extensions/common/manifest_constants.h"

#if BUILDFLAG(ENABLE_EXTENSIONS)

namespace sephr {
namespace {

void EnsureUBlockPublicKey(base::DictValue& manifest) {
  if (manifest.FindString(extensions::manifest_keys::kPublicKey)) {
    return;
  }
  manifest.Set(extensions::manifest_keys::kPublicKey, kUBlockOriginPublicKey);
}

}  // namespace

void InstallBuiltinUBlockOrigin(Profile* profile) {
  if (!profile) {
    return;
  }

  base::FilePath resources_dir;
  if (!base::PathService::Get(chrome::DIR_RESOURCES, &resources_dir)) {
    LOG(WARNING) << "[sephr/ublock] DIR_RESOURCES unavailable";
    return;
  }

  const base::FilePath ext_dir =
      resources_dir.Append(FILE_PATH_LITERAL("ublock_origin"));
  if (!base::PathExists(ext_dir.Append(FILE_PATH_LITERAL("manifest.json")))) {
    LOG(WARNING) << "[sephr/ublock] bundled extension missing at "
                 << ext_dir;
    return;
  }

  extensions::ComponentLoader* loader =
      extensions::ComponentLoader::Get(profile);
  if (!loader) {
    LOG(WARNING) << "[sephr/ublock] ComponentLoader unavailable";
    return;
  }

  if (loader->Exists(kUBlockOriginExtensionId)) {
    loader->Remove(kUBlockOriginExtensionId);
  }

  std::string error;
  std::optional<base::DictValue> manifest =
      extensions::file_util::LoadManifest(ext_dir, &error);
  if (!manifest) {
    LOG(ERROR) << "[sephr/ublock] failed to load manifest: " << error;
    return;
  }

  EnsureUBlockPublicKey(*manifest);
  loader->Add(std::move(*manifest), ext_dir);
  VLOG(1) << "[sephr/ublock] registered component extension from "
          << ext_dir;
}

}  // namespace sephr

#else  // !BUILDFLAG(ENABLE_EXTENSIONS)

namespace sephr {

void InstallBuiltinUBlockOrigin(Profile* profile) {}

}  // namespace sephr

#endif  // BUILDFLAG(ENABLE_EXTENSIONS)
