// Copyright (c) Sephr. All rights reserved.
#ifndef CHROME_SEPHR_BUILTIN_EXTENSIONS_UBLOCK_INSTALLER_H_
#define CHROME_SEPHR_BUILTIN_EXTENSIONS_UBLOCK_INSTALLER_H_

class Profile;

namespace sephr {

// uBlock Origin — the same extension users install from the store, shipped
// as a built-in component extension. Not user-removable.
inline constexpr char kUBlockOriginExtensionId[] =
    "cjpalhdlnbpafiamejdnhcphjbkeiagm";

// Chrome Web Store signing key for uBlock Origin. ComponentLoader requires
// this in the manifest to derive the stable extension id; release zips omit it.
inline constexpr char kUBlockOriginPublicKey[] =
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmJNzUNVjS6Q1qe0NRqpmfX/"
    "oSJdgauSZNdfeb5RV1Hji21vX0TivpP5gq0fadwmvmVCtUpOaNUopgejiUFm/iKHPs0o"
    "3x7hyKk/eX0t2QT3OZGdXkPiYpTEC0f0p86SQaLoA2eHaOG4uCGi7sxLJmAXc6IsxGKV"
    "klh7cCoLUgWEMnj8ZNG2Y8UKG3gBdrpES5hk7QyFDMraO79NmSlWRNgoJHX6XRoY66o"
    "YThFQad8KL8q3pf3Oe8uBLKywohU0ZrDPViWHIszXoE9HEvPTFAbHZ1umINni4W/YVs+"
    "fhqHtzRJcaKJtsTaYy+cholu5mAYeTZqtHf6bcwJ8t9i2afwIDAQAB";

// Loads the bundled unpacked extension from the framework Resources folder
// into `profile` via ComponentLoader. Safe to call once per profile at
// PostBrowserStart; no-ops when extensions are disabled or the bundle is
// missing.
void InstallBuiltinUBlockOrigin(Profile* profile);

}  // namespace sephr

#endif  // CHROME_SEPHR_BUILTIN_EXTENSIONS_UBLOCK_INSTALLER_H_
