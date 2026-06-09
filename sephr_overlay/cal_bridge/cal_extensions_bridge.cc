// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// Extensions bridge. Wires the C ABI declared in cal_bridge.h to Chromium's
// extensions system: ExtensionRegistry for the installed list + change
// notifications, ExtensionRegistrar for enable / disable / uninstall.
// Subscribe pattern mirrors the downloads bridge: one observer per
// BrowserContext, rebuilding a flat snapshot on every registry change.

#include "chrome/sephr/cal_bridge/cal_bridge.h"

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/no_destructor.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_id.h"
#include "extensions/common/extension_set.h"
#include "extensions/common/mojom/manifest.mojom.h"

namespace {

content::BrowserContext* AsContext(SephriumProfileRef ref) {
  return reinterpret_cast<content::BrowserContext*>(ref);
}

// String storage that outlives the C-struct view handed to the embedder.
struct OwnedExt {
  std::string id, name, version;
  int enabled;
};

// One bridge observer per BrowserContext. Owns the ExtensionRegistry
// observation and pushes a full snapshot whenever the installed set changes
// (loaded / unloaded / installed / uninstalled).
class ExtBridgeObserver : public extensions::ExtensionRegistryObserver {
 public:
  ExtBridgeObserver(content::BrowserContext* context,
                    SephriumExtensionsCallback callback,
                    void* ctx)
      : context_(context), callback_(callback), ctx_(ctx) {
    registry_ = extensions::ExtensionRegistry::Get(context_);
    if (registry_) {
      registry_->AddObserver(this);
    }
    Snapshot();  // initial snapshot is always immediate
  }
  ~ExtBridgeObserver() override {
    if (registry_) {
      registry_->RemoveObserver(this);
    }
  }

  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext*,
                         const extensions::Extension*) override {
    Snapshot();
  }
  void OnExtensionUnloaded(content::BrowserContext*,
                           const extensions::Extension*,
                           extensions::UnloadedExtensionReason) override {
    Snapshot();
  }
  void OnExtensionInstalled(content::BrowserContext*,
                            const extensions::Extension*,
                            bool /*is_update*/) override {
    Snapshot();
  }
  void OnExtensionUninstalled(content::BrowserContext*,
                              const extensions::Extension*,
                              extensions::UninstallReason) override {
    Snapshot();
  }
  void OnShutdown(extensions::ExtensionRegistry* registry) override {
    if (registry_ == registry) {
      registry_->RemoveObserver(this);
      registry_ = nullptr;
    }
  }

 private:
  void Snapshot() {
    if (!registry_ || !callback_) return;

    std::vector<OwnedExt> owned;
    auto append = [&owned](const extensions::ExtensionSet& set, int enabled) {
      for (const auto& ext : set) {
        owned.push_back({ext->id(), ext->name(), ext->VersionString(),
                         enabled});
      }
    };
    append(registry_->enabled_extensions(), 1);
    append(registry_->disabled_extensions(), 0);

    std::vector<SephriumExtensionEntry> entries(owned.size());
    for (size_t i = 0; i < owned.size(); ++i) {
      entries[i].identifier = owned[i].id.c_str();
      entries[i].name = owned[i].name.c_str();
      entries[i].version = owned[i].version.c_str();
      entries[i].enabled = owned[i].enabled;
    }
    callback_(ctx_, entries.empty() ? nullptr : entries.data(),
              static_cast<int>(entries.size()));
  }

  raw_ptr<content::BrowserContext> context_;
  raw_ptr<extensions::ExtensionRegistry> registry_ = nullptr;
  SephriumExtensionsCallback callback_;
  void* ctx_;
};

std::map<content::BrowserContext*, std::unique_ptr<ExtBridgeObserver>>&
GlobalExtSubscribers() {
  static base::NoDestructor<
      std::map<content::BrowserContext*, std::unique_ptr<ExtBridgeObserver>>>
      m;
  return *m;
}

}  // namespace

extern "C" void SephriumExtensionsSubscribe(
    SephriumProfileRef profile,
    SephriumExtensionsCallback callback,
    void* ctx) {
  content::BrowserContext* context = AsContext(profile);
  if (!context) {
    if (callback) callback(ctx, nullptr, 0);
    return;
  }
  auto& subs = GlobalExtSubscribers();
  subs.erase(context);
  if (callback) {
    subs[context] =
        std::make_unique<ExtBridgeObserver>(context, callback, ctx);
  }
}

extern "C" void SephriumExtensionsSetEnabled(SephriumProfileRef profile,
                                             const char* identifier,
                                             int enabled) {
  content::BrowserContext* context = AsContext(profile);
  if (!context || !identifier) return;
  auto* registrar = extensions::ExtensionRegistrar::Get(context);
  if (!registrar) return;
  if (enabled) {
    registrar->EnableExtension(identifier);
  } else {
    registrar->DisableExtension(
        identifier, {extensions::disable_reason::DISABLE_USER_ACTION});
  }
}

extern "C" void SephriumExtensionsUninstall(SephriumProfileRef profile,
                                            const char* identifier) {
  content::BrowserContext* context = AsContext(profile);
  if (!context || !identifier) return;
  auto* registrar = extensions::ExtensionRegistrar::Get(context);
  if (!registrar) return;
  std::u16string error;
  registrar->UninstallExtension(
      identifier, extensions::UNINSTALL_REASON_USER_INITIATED, &error);
}

extern "C" void SephriumExtensionsInstallCRX(SephriumProfileRef profile,
                                             const char* path) {
  content::BrowserContext* context = AsContext(profile);
  if (!context || !path) return;
  // Silent, user-initiated local install of a CRX3 package. The package
  // carries no Web Store publisher proof, so off-store install must be
  // explicitly allowed. CrxInstaller is ref-counted and keeps itself alive
  // across the async unpack/verify/install; the registry observer pushes a
  // fresh snapshot once it lands.
  scoped_refptr<extensions::CrxInstaller> installer =
      extensions::CrxInstaller::CreateSilent(context);
  installer->set_install_source(extensions::mojom::ManifestLocation::kInternal);
  installer->set_off_store_install_allow_reason(
      extensions::CrxInstaller::OffStoreInstallAllowedFromSettingsPage);
  installer->set_allow_silent_install(true);
  installer->InstallCrx(base::FilePath::FromUTF8Unsafe(path));
}
