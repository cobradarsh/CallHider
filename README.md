# CallHider

A roothide / Theos tweak for **iOS 16.x** (built and tuned for iPhone 14 Pro Max on 16.5) that **silently hides incoming calls from contacts you choose** — cellular *and* VoIP (FaceTime, and CallKit apps like WhatsApp).

When a hidden caller rings:

- the screen **does not wake**;
- if you're already using the phone, **no banner or full-screen call UI appears**;
- the ring/vibration is **silenced**;
- a small **red phone icon** appears (top-right by default) that you can **drag anywhere**.

The call is **not blocked** — it still rings through at the system level and can go to voicemail. CallHider only changes how (and whether) *your* device alerts *you*.

## How it works

CallHider hooks Apple's private `TelephonyUtilities` call object (`TUCall`), which drives both cellular and VoIP calls:

| What | Mechanism |
|------|-----------|
| Hide banner / full-screen UI | override `-[TUCall shouldSuppressInCallUI]` → `YES` for hidden callers (iOS's own UI-suppression lever) |
| Silence ring & vibration | `-[TUCall shouldSuppressRingtone]` + `-suppressRingtone` |
| Prevent screen wake | guard `-[SBBacklightController turnOnScreenFullyWithBacklightSource:]`, **only while a hidden call is actively ringing** |
| Indicator | a high-level, draggable `UIWindow` in SpringBoard |

**Matching** is by Contacts identifier *and* by normalized phone number, so a VoIP call that doesn't carry a contact id still matches a saved contact's number.

> ⚠️ `TUCall`, `TUCallCenter` and the ringtone APIs are verified against public iOS 16 runtime-header dumps. The `SBBacklightController` wake-guard method name is the historically stable one; if a future point release renames it, that single layer simply no-ops (nothing crashes) — turn on **Debug logging** in settings and check `Console`/`oslog` for `[CallHider]` lines to confirm.

## Build the `.deb`

### Option A — GitHub Actions (no Mac needed)

This repo includes `.github/workflows/build.yml`. On every push to `main` it builds the package and uploads it as a workflow **artifact** (`CallHider-deb`). Push a tag like `v1.0.0` and it also attaches the `.deb` to a GitHub **Release**.

```bash
# in your clone
git tag v1.0.0
git push origin v1.0.0
```

Then grab the `.deb` from the Actions run (Artifacts) or the Releases page.

### Option B — locally on macOS with roothide Theos

```bash
export THEOS=~/theos
git clone --recursive https://github.com/roothide/theos.git $THEOS
# add an SDK into $THEOS/sdks (e.g. iPhoneOS16.5.sdk from https://github.com/theos/sdks)
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
# -> packages/com.cobradarsh.callhider_1.0.0_iphoneos-arm64.deb
```

## Install

Copy the `.deb` to the device and install it with the roothide **Bootstrap** app (or `Sileo`/`Zebra` configured for roothide), then **respring**.

## Use

Open **Settings → CallHider**:

1. Make sure **Enable CallHider** is on.
2. **Manage hidden contacts → +** to pick the contacts to hide.
3. Toggle *Silence ring*, *Keep screen from waking*, *Hide on-screen call UI* as you like.
4. Optionally enable *Tap red icon to answer*.
5. When a hidden call comes in, **drag the red icon** to reposition it — the spot is saved.

## Project layout

```
Tweak.xm                     SpringBoard / callservicesd hooks + red indicator
CHPrefs.h                    shared preference keys + number normalization
CallHider.plist              injection filter
control, Makefile            roothide packaging
callhiderprefs/              Settings bundle (toggles + contact picker)
.github/workflows/build.yml  CI that produces the .deb
```

## Disclaimer

For your own jailbroken device. Uses private APIs that can change between iOS versions; test on your own build.
