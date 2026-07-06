#!/usr/bin/env bash
# LeapSDK ships nested dylibs (libinference_engine, etc.) adhoc-signed inside
# LeapSDK.framework/Frameworks/. Device installs reject them unless they are
# re-signed with the app’s development/distribution identity before the final
# bundle codesign. Simulator builds skip this (adhoc "-" is fine).
set -euo pipefail

framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/LeapSDK.framework"
if [[ ! -d "${framework}" ]]; then
    exit 0
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "${identity}" || "${identity}" == "-" ]]; then
    exit 0
fi

nested="${framework}/Frameworks"
if [[ -d "${nested}" ]]; then
    for lib in "${nested}"/*.dylib; do
        [[ -e "${lib}" ]] || continue
        /usr/bin/codesign --force --sign "${identity}" --timestamp=none "${lib}"
    done
fi

/usr/bin/codesign --force --sign "${identity}" --timestamp=none "${framework}"
