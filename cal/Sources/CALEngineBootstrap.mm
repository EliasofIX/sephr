// Copyright (c) Sephr. All rights reserved.
#import "CALEngineBootstrap.h"
#import "CALInternal.h"

#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

// Chromium ships its helpers in separate process groups and relies on
// Mojo broker channel close-on-host-death to bring them down. On macOS
// that path only fires when the host exits *cleanly* — a raw SIGKILL or
// an unhandled SIGTERM leaves helpers running until they notice on their
// own timer. Install a SIGTERM handler that calls
// `[NSApplication terminate:]` so AppKit drains the run loop, atexit
// handlers run, and the broker's mojo channels close before we exit.
// async-signal-safe path: write a single byte to a self-pipe so the run
// loop can wake up and handle the signal off-thread. Direct AppKit /
// dispatch calls from a signal context are NOT safe per Apple's signal(3).
static int g_signal_pipe[2] = {-1, -1};

static void CALSignalHandler(int signum) {
    // write(2) is one of the few async-signal-safe POSIX calls.
    const char ch = (char)signum;
    ssize_t r = write(g_signal_pipe[1], &ch, 1);
    (void)r;  // best-effort — if the pipe is full something is very wrong.
}

static void CALInstallSignalHandlers(void) {
    if (g_signal_pipe[0] != -1) return;  // idempotent
    if (pipe(g_signal_pipe) != 0) return;
    // Non-blocking on the read end; we'll drain in the dispatch source.
    fcntl(g_signal_pipe[0], F_SETFL, O_NONBLOCK);
    // CLOEXEC on both ends so helpers spawned later don't inherit them.
    fcntl(g_signal_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(g_signal_pipe[1], F_SETFD, FD_CLOEXEC);

    // Wire the read end into GCD so AppKit gets a clean wake-up.
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, g_signal_pipe[0], 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        char buf[16];
        while (read(g_signal_pipe[0], buf, sizeof(buf)) > 0) { /* drain */ }
        NSLog(@"[sephr] SIGTERM/SIGINT received → NSApp terminate");
        [NSApp terminate:nil];
    });
    dispatch_resume(src);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = CALSignalHandler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
}

// Strong reference to the user-supplied UI-boot block. Held at file scope
// because the C trampoline that hands it to SephrBrowserMainExtraParts is
// a bare function pointer — it can't capture an Obj-C block on its own.
// Guarded by @synchronized — the setter is called from a Swift main-thread
// path but PostBrowserStart fires from Chromium's UI thread, and we want
// to be paranoid about the small window where both could race.
static void (^kUiBootBlock)(void) = nil;
static NSObject* kUiBootBlockLock;
static dispatch_once_t kUiBootLockOnce;

static NSObject* CAL_UiBootLock(void) {
    dispatch_once(&kUiBootLockOnce, ^{
        kUiBootBlockLock = [[NSObject alloc] init];
    });
    return kUiBootBlockLock;
}

static void CALInvokeUiBootBlock(void) {
    // PostBrowserStart is the right time to install SIGTERM/SIGINT
    // handlers: Chromium's own signal setup ran during ContentMain, so
    // installing here lets ours take precedence on shutdown without
    // interfering with the crash-handler chain.
    CALInstallSignalHandlers();
    void (^block)(void) = nil;
    @synchronized (CAL_UiBootLock()) {
        block = kUiBootBlock;
    }
    if (block) {
        block();
    }
}

// Strong reference to the external-URL block, held at file scope for the
// same reason as the UI-boot block — the C trampoline handed to the
// Sephrium bridge is a bare function pointer and can't capture a block.
// The bridge invokes the trampoline on the UI (main) thread.
static void (^kOpenExternalURLBlock)(NSString*) = nil;
static NSObject* kOpenExternalURLLock;
static dispatch_once_t kOpenExternalURLLockOnce;

static NSObject* CAL_OpenExternalURLLock(void) {
    dispatch_once(&kOpenExternalURLLockOnce, ^{
        kOpenExternalURLLock = [[NSObject alloc] init];
    });
    return kOpenExternalURLLock;
}

static void CALInvokeOpenExternalURL(void* ctx, const char* url) {
    (void)ctx;  // block is held at file scope; no context needed.
    if (!url) return;
    NSString* str = [NSString stringWithUTF8String:url];
    if (!str.length) return;
    void (^block)(NSString*) = nil;
    @synchronized (CAL_OpenExternalURLLock()) {
        block = kOpenExternalURLBlock;
    }
    if (block) {
        block(str);
    }
}

@implementation CALEngineBootstrap

static BOOL kInitialized = NO;

// `~/Library/Application Support/Sephr/Profiles` — the Chromium user-data
// dir we pin via --user-data-dir. Shared by CALDefaultSwitches (the switch)
// and CALDisableProfilePicker (the Local State path).
static NSString* CALUserDataDir(void) {
    NSArray<NSString*>* roots = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* support = roots.firstObject;
    if (!support.length) {
        NSString* home = NSHomeDirectory() ?: @"/tmp";
        support = [home stringByAppendingPathComponent:
                            @"Library/Application Support"];
    }
    return [support stringByAppendingPathComponent:@"Sephr/Profiles"];
}

// Suppress Chromium's "Who's using Chromium?" multi-profile picker.
//
// Sephr assigns each isolated Space its own Chromium profile (see
// SephrSpace.profileID → "space-<UUID>"). The moment a second profile is
// registered in Local State, Chromium's ProfilePicker::GetStartupMode()
// returns kProfilePicker and the chooser pops up at launch. Profiles are
// an implementation detail of Spaces here, never a user-facing concept, so
// Sephr never wants that screen.
//
// We disable it by writing profile.picker_availability_on_startup = 1
// (ProfilePicker::AvailabilityOnStartup::kDisabled) into Local State BEFORE
// ChromeMain loads it. kDisabled short-circuits GetStartupMode() to
// kBrowserWindow at its very first check, regardless of how many profiles
// exist — so isolated-profile Spaces keep working. (show_picker_on_startup
// is set false too for belt-and-suspenders / clarity when inspecting the
// file.) Neither pref is a hash-tracked pref, so an external write is
// honoured rather than reset.
//
// Browser process only — helpers must not race on the shared Local State.
static void CALDisableProfilePicker(NSString* userDataDir) {
    if (!userDataDir.length) return;
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:userDataDir withIntermediateDirectories:YES
                   attributes:nil error:nil];
    NSString* localState =
        [userDataDir stringByAppendingPathComponent:@"Local State"];

    NSMutableDictionary* root = nil;
    if ([fm fileExistsAtPath:localState]) {
        NSData* data = [NSData dataWithContentsOfFile:localState];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil]
                          : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            root = [parsed mutableCopy];
        }
    }
    if (!root) root = [NSMutableDictionary dictionary];

    id profileObj = root[@"profile"];
    NSMutableDictionary* profile =
        [profileObj isKindOfClass:[NSDictionary class]]
            ? [profileObj mutableCopy]
            : [NSMutableDictionary dictionary];

    // Idempotent: nothing to do if both prefs are already where we want them.
    if ([profile[@"picker_availability_on_startup"] isEqual:@1] &&
        [profile[@"show_picker_on_startup"] isEqual:@NO]) {
        return;
    }

    profile[@"picker_availability_on_startup"] = @1;  // kDisabled
    profile[@"show_picker_on_startup"] = @NO;
    root[@"profile"] = profile;

    NSData* out = [NSJSONSerialization dataWithJSONObject:root
                                                  options:0
                                                    error:nil];
    if (out) {
        [out writeToFile:localState atomically:YES];
    }
}

// Default switches Sephr always wants in the browser process. Critical
// ones today:
//
//   --password-store=basic
//     Stops Chromium's OSCrypt from prompting the user for a Keychain
//     password ("Sephr Safe Storage") on first launch. With `basic`,
//     OSCrypt falls back to a plaintext-on-disk key, no Keychain prompt.
//     This is fine for development; production will use our own at-rest
//     encryption via CAL rather than Chromium's OSCrypt.
//
//   --no-first-run, --disable-default-apps
//     Skip Chromium's first-run UI (we have our own onboarding) and the
//     bundled-default-apps dance.
//
//   --user-data-dir=~/Library/Application Support/Sephr/Profiles
//     Pin the profile root somewhere we control. Without this Chromium
//     uses "~/Library/Application Support/Chromium" by default.
static NSArray<NSString*>* CALDefaultSwitches(void) {
    NSString* userDataDir = CALUserDataDir();
    // crashDir is a sibling of Profiles under .../Sephr.
    NSString* crashDir = [[userDataDir stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"Crashes"];
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:userDataDir withIntermediateDirectories:YES
                   attributes:nil error:nil];
    [fm createDirectoryAtPath:crashDir withIntermediateDirectories:YES
                   attributes:nil error:nil];
    return @[
        // We replace OSCrypt's Keychain path with our own file-backed
        // key (see 013-disable-keychain-prompt-mac.patch); this switch
        // also tells Chromium not to try the libsecret/kwallet/Keychain
        // password store backend.
        @"--password-store=basic",
        @"--no-first-run",
        @"--disable-default-apps",
        // Sephr owns the UI entirely. Chromium contributes ONLY the
        // rendering engine (content::WebContents + helpers). Suppress
        // every Chrome browser surface that would create an NSWindow:
        @"--no-startup-window",
        @"--silent-launch",
        // Disable Chromium's Cmd+S "Save Page As" handler so it doesn't
        // collide with Sephr's Cmd+S = toggle sidebar. The shortcut is
        // also swallowed at the AppKit layer in
        // SephrKeyboardShortcutMonitor, but turning the feature off
        // means the renderer never surfaces a dialog at all.
        @"--save-page-as-mhtml=0",
        @"--disable-save-page-as",
        // Skip welcome / Sync / migration prompts that pop up in the
        // first launch path of the stock browser.
        @"--no-default-browser-check",
        @"--disable-sync",
        // Surface LOG(WARNING)+ to stderr. To trace CAL/ExtraParts
        // wiring (VLOG(1) messages) pass --vmodule=sephr_browser_main_extra_parts=1
        // or --v=1 on the command line.
        @"--enable-logging=stderr",
        @"--log-level=1",
        // Coalesce two disable-features sets into one switch — Chromium
        // only honours the last --disable-features value on the command
        // line, so splitting them across multiple flags silently drops
        // earlier ones.
        //
        // WebAuthn: as of the 2026-06-05 Chromium rebuild with the new
        // BRANDING (MAC_TEAM_ID=U2UY24TMGG, MAC_BUNDLE_ID=com.sephr.framework
        // via patch 014), the framework bakes
        // U2UY24TMGG.com.sephr.framework.webauthn as its platform-
        // authenticator keychain access group, and Sephr.entitlements
        // claims that group. Under a real Developer ID signature for
        // team U2UY24TMGG, Apple Keychain / Touch ID lights up as a
        // passkey method; under ad-hoc signing the entitlement is
        // ignored and TouchIdContext::TouchIdAvailableImpl safely
        // returns false (no platform authenticator offered, no crash).
        // USB / NFC / BLE security keys and hybrid (phone QR / caBLE)
        // passkeys work regardless of signing tier.
        @"--disable-features=DefaultBrowserPromptRefresh,SavePageAsMHTML,SpareRendererForSitePerProcess,FedCm,FedCmAutoSelectedFlag,FedCmIdAssertionEndpoint",
        // Crashpad — Chromium's built-in crash reporter. Point it at our
        // own crashes/ dir so we don't dump into ~/Library/Application
        // Support/Chromium. To enable upload to a real collection
        // endpoint, replace `--crash-server-url=` below with the actual
        // backend URL once we have one; until then crashes stay local.
        @"--enable-crash-reporter",
        [NSString stringWithFormat:@"--crashpad-handler-pid-file=%@",
            [crashDir stringByAppendingPathComponent:@".pid"]],
        [NSString stringWithFormat:@"--user-data-dir=%@", userDataDir],
    ];
}

+ (void)bootChromium {
    if (kInitialized) return;
    kInitialized = YES;

    NSArray<NSString*>* processArgs = [NSProcessInfo processInfo].arguments;
    NSArray<NSString*>* defaults = CALDefaultSwitches();

    // Helper processes get re-invoked by the browser with --type=… plus
    // an explicit switch set; injecting browser-side defaults into a
    // helper would corrupt its command line. Skip defaults if --type is
    // already present in the inherited argv.
    BOOL isHelper = NO;
    for (NSString* a in processArgs) {
        if ([a hasPrefix:@"--type="]) { isHelper = YES; break; }
    }
    NSArray<NSString*>* finalArgs = isHelper
        ? processArgs
        : [processArgs arrayByAddingObjectsFromArray:defaults];

    // Browser process only: keep Chromium's multi-profile picker from
    // appearing at launch. Must run before SephriumInitialize → ChromeMain
    // reads Local State.
    if (!isHelper) {
        CALDisableProfilePicker(CALUserDataDir());
    }

    // strdup(NULL) is undefined behaviour. -UTF8String can return NULL for
    // a string that does not round-trip through UTF-8 — rare for argv but
    // we'd rather skip the arg than UB.
    const char** argv = (const char**)malloc(sizeof(char*) * (finalArgs.count + 1));
    if (!argv) {
        NSLog(@"[sephr] CALEngineBootstrap: argv allocation failed; aborting boot");
        return;
    }
    int n = 0;
    for (NSUInteger i = 0; i < finalArgs.count; i++) {
        const char* utf = [finalArgs[i] UTF8String];
        if (!utf) {
            NSLog(@"[sephr] dropping non-UTF8 argv[%lu]: %@",
                  (unsigned long)i, finalArgs[i]);
            continue;
        }
        char* dup = strdup(utf);
        if (!dup) continue;  // mid-boot OOM — skip arg, keep going
        argv[n++] = dup;
    }
    argv[n] = NULL;
    SephriumInitialize(n, argv);
    // argv is intentionally leaked — Sephrium retains it for the process
    // lifetime (matches content::ContentMainParams semantics).
}

+ (void)setUiBootCallback:(void (^)(void))callback {
    @synchronized (CAL_UiBootLock()) {
        kUiBootBlock = [callback copy];
    }
    SephriumSetUiBootCallback(callback ? CALInvokeUiBootBlock : NULL);
}

+ (void)setOpenExternalURLCallback:(void (^)(NSString*))callback {
    @synchronized (CAL_OpenExternalURLLock()) {
        kOpenExternalURLBlock = [callback copy];
    }
    SephriumSetOpenExternalURLCallback(
        callback ? CALInvokeOpenExternalURL : NULL, NULL);
}


+ (void)pumpOnce {
    SephriumPumpOnce();
}

@end
