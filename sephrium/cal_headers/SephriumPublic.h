// Sephrium public header — the only surface CAL is allowed to include.
// Everything else stays private to the framework.
#ifndef SEPHRIUM_PUBLIC_H_
#define SEPHRIUM_PUBLIC_H_

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the Sephrium content process and event loop. Must be called on
// the main thread before any other Sephrium entry point. Idempotent.
void SephriumInitialize(int argc, const char* const* argv);

// Drive a single pass of the Sephrium message loop (used when the host app
// runs its own NSApplication run loop and pumps tasks cooperatively).
void SephriumPumpOnce(void);

// Opaque profile handle. Obtain via SephriumGetProfile; released with
// SephriumReleaseProfile.
typedef struct SephriumProfileOpaque* SephriumProfileRef;
SephriumProfileRef SephriumGetProfile(const char* profile_id);
void              SephriumReleaseProfile(SephriumProfileRef);

#ifdef __cplusplus
}
#endif

#endif  // SEPHRIUM_PUBLIC_H_
