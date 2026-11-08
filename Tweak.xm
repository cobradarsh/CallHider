// CallHider — hide incoming calls (cellular + VoIP) from selected contacts.
//
// v1.2.0 (all mechanisms confirmed firing on-device via diagnostics):
//   * Ringtone silenced via -shouldSuppressRingtone (safe getter/setter).
//   * Screen wake blocked via SBBacklightController while a hidden call rings.
//   * On-screen call UI suppressed by swallowing the SBInCallPresentationManager
//     presentation request (PRES-HOOK, proven to fire) — completion is still
//     called so the client isn't left hanging. Gated by "Hide on-screen call UI".
//   * Missed-call lockscreen notification dropped at BBServer for hidden callers
//     (matched by the bulletin's BBContact cnContactIdentifier / handle).
//   * Small red phone glyph indicator that PERSISTS after a missed hidden call
//     (with a count badge) until cleared; tap clears it (or answers while ringing).

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#import "CHPrefs.h"

#pragma mark - Private interfaces

@interface TUHandle : NSObject
@property (nonatomic, readonly, copy) NSString *value;
@end
@interface TUCall : NSObject
@property (nonatomic, readonly) int callStatus;
@property (getter=isIncoming, nonatomic, readonly) BOOL incoming;
@property (nonatomic, readonly) TUHandle *handle;
@property (nonatomic, readonly, copy) NSString *contactIdentifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *callUUID;
- (void)setShouldSuppressRingtone:(BOOL)v;
- (void)setRingtoneSuppressedRemotely:(BOOL)v;   // Continuity "silenced from another device"; reaches the ringtone server
@end
@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (void)answerCall:(TUCall *)call;
@end
@interface SBBacklightController : NSObject
- (void)turnOnScreenFullyWithBacklightSource:(long long)source;
@end
@interface SpringBoard : UIApplication
- (void)_updateRingerState:(int)arg1 withVisuals:(BOOL)arg2 updatePreferenceRegister:(BOOL)arg3;
@end

// BacklightServices: the system's own way to disable Always-On (used face-down,
// in Sleep Focus, etc.). Holding an assertion with this attribute drops the
// display to fully black; invalidating it restores AOD.
@interface BLSAttribute : NSObject @end
@interface BLSDisableAlwaysOnAttribute : BLSAttribute
+ (id)disableAlwaysOn;
@end
@interface BLSAssertion : NSObject
+ (id)acquireWithExplanation:(NSString *)explanation observer:(id)observer attributes:(NSArray *)attributes;
- (void)invalidate;
- (BOOL)isAcquired;
- (BOOL)isActive;
@end
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

// ToneLibrary. The ringtone AND its vibration are played inside callservicesd by
// a TLAlert, which asks TLVibrationManager whether to vibrate and asks again
// whenever the ring-/silent-vibrate "changed" notifications fire (the ones the
// Sounds settings pane posts). We answer NO for a hidden ring and post those
// notifications so an alert that is already buzzing re-evaluates and stops.
@interface TLVibrationManager : NSObject
+ (instancetype)sharedVibrationManager;
- (BOOL)shouldVibrateOnRing;
- (BOOL)shouldVibrateOnSilent;
- (BOOL)shouldVibrateForCurrentRingerSwitchState;
@end
#define kVibRingChanged   "com.apple.springboard.ring-vibrate.changed"
#define kVibSilentChanged "com.apple.springboard.silent-vibrate.changed"

// Private AudioToolbox exports: patterned (call) vibration playback and the stop
// call. Neither is in the SDK link stubs, so both are bound with dlsym at load.
extern void AudioServicesPlaySystemSoundWithVibration(SystemSoundID inSystemSoundID, id arg, NSDictionary *vibratePattern);
// The incoming-call banner; on Dynamic Island devices this is what renders the
// call pill. We can't stop its creation, but we can keep its view off screen.
@interface SBInCallBannerPresentableViewController : UIViewController
@end

// BulletinBoard (for dropping the missed-call notification)
@interface BBContact : NSObject
@property (nonatomic, readonly, copy) NSString *cnContactIdentifier;
@property (nonatomic, readonly, copy) NSString *handle;
@property (nonatomic, readonly, copy) NSString *displayName;
@end
@interface BBCommunicationContext : NSObject
@property (nonatomic, readonly, copy) BBContact *sender;
@end
@interface BBBulletinRequest : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, retain) BBCommunicationContext *communicationContext;
@end

// CallHistory (the Phone app's Recents). callservicesd writes entries via
// -addToCallHistory:; SpringBoard can read them back and delete.
@interface CHRecentCall : NSObject
@property (nonatomic, copy) NSString *callerId;
@property (nonatomic, retain) NSDate *date;
@end
@interface CHManager : NSObject
- (instancetype)init;
- (void)addToCallHistory:(id)call;
- (void)addMultipleCallsToCallHistory:(id)calls;
- (id)fetchRecentCallsSyncWithCoalescing:(BOOL)coalesce;
- (void)deleteCall:(id)call;
@end

#pragma mark - State

static BOOL gIsSpringBoard = NO;
static NSString *gProc = nil;
static NSDictionary *gPrefs = nil;
static NSSet<NSString *> *gRevealed;
static NSString *gLoggedUUID = nil;       // last hidden call written to the log (once per call)
static volatile BOOL gHiddenRinging = NO;
static NSInteger gMissedCount = 0;        // persistent "you had a hidden call" count
static BOOL gSystemRingerOn = YES;        // last ringer state the SYSTEM set
static BOOL gWeMutedRinger = NO;          // we lowered the ringer for a hidden call
static BOOL gInOurRinger = NO;            // guard so our own calls don't self-record

static void CHMuteRinger(void);           // defined below; used from the icon tap handler
static void CHRestoreRinger(void);
static void CHRestoreDisplay(void);

// AudioServicesStopSystemSound, resolved at load (NULL if absent).
static void (*gStopSystemSound)(SystemSoundID) = NULL;
// Always-On-Display disable assertion held while a hidden call rings (locked only).
static id   gAODAssertion = nil;

#pragma mark - Diagnostics

static void CHDiag(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args]; va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@  [%@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle],
        gProc ?: @"?", msg];
    NSLog(@"[CallHider] %@", msg);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kCHDiagDir]) [fm createDirectoryAtPath:kCHDiagDir withIntermediateDirectories:YES attributes:nil error:nil];
        if ([[fm attributesOfItemAtPath:kCHDiagPath error:nil] fileSize] > 64*1024) [fm removeItemAtPath:kCHDiagPath error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kCHDiagPath];
        if (!fh) { [line writeToFile:kCHDiagPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
    } @catch (__unused NSException *e) {}
}

#pragma mark - Preferences

static BOOL CHBool(NSString *k, BOOL d) { id v = gPrefs[k]; return (v==nil)?d:[v boolValue]; }
static CGFloat CHFloat(NSString *k, CGFloat d) { id v = gPrefs[k]; return (v==nil)?d:[v doubleValue]; }
#define CHEnabled()        CHBool(kCHEnabled, YES)
#define CHSilenceRinger()  CHBool(kCHSilenceRinger, YES)
#define CHSuppressWake()   CHBool(kCHSuppressWake, YES)
#define CHSuppressUI()     CHBool(kCHSuppressUI, YES)
#define CHTapToAnswer()    CHBool(kCHTapToAnswer, NO)
#define CHHideMissed()     CHBool(kCHHideMissedNotif, YES)

static void CHPersistMissed(void) {
    CFPreferencesSetValue((__bridge CFStringRef)kCHMissedCount, (__bridge CFNumberRef)@(gMissedCount),
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
}

// --- callservicesd -> SpringBoard report ---------------------------------------
// callservicesd can't write our diagnostics file, so it publishes a status word
// over a Darwin notify state that SpringBoard logs. Bits: 0 = loaded,
// 8..23 = hidden-list count it could read, 24 = last incoming call matched a
// hidden caller, 25 = ring-suppression flags were applied to that call.
#define kCHReportNotify "com.cobradarsh.callhider/csreport"
static int gReportToken = -1;
static uint64_t gReport = 0;

static void CHReportPublish(void) {
    if (gIsSpringBoard) return;
    if (gReportToken == -1 && notify_register_check(kCHReportNotify, &gReportToken) != NOTIFY_STATUS_OK) return;
    notify_set_state(gReportToken, gReport);
    notify_post(kCHReportNotify);
}
static void CHReportLogFromSpringBoard(void) {
    if (!gIsSpringBoard) return;
    int t; uint64_t s = 0;
    if (notify_register_check(kCHReportNotify, &t) != NOTIFY_STATUS_OK) return;
    notify_get_state(t, &s); notify_cancel(t);
    CHDiag(@"callservicesd report: loaded=%llu hidden=%llu matched=%llu suppressed=%llu",
           s & 1ULL, (s >> 8) & 0xffffULL, (s >> 24) & 1ULL, (s >> 25) & 1ULL);
}

static void CHReload(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    NSArray *keys = @[kCHEnabled, kCHSilenceRinger, kCHSuppressWake, kCHSuppressUI, kCHTapToAnswer,
                      kCHHideMissedNotif, kCHHideFromRecents, kCHIconX, kCHIconY, kCHIconSize,
                      kCHMissedCount, kCHHiddenContacts];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        id v = (__bridge_transfer id)CFPreferencesCopyValue((__bridge CFStringRef)k, (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) d[k] = v;
    }
    gPrefs = [d copy];
    // Outside SpringBoard (e.g. callservicesd) the prefs API may be sandboxed
    // off; read the plist file directly so the hidden list is still available
    // where the ring is actually produced.
    if (!gIsSpringBoard && [gPrefs[kCHHiddenContacts] count] == 0) {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.cobradarsh.callhider.plist"];
        if ([file isKindOfClass:[NSDictionary class]] && [file[kCHHiddenContacts] isKindOfClass:[NSArray class]]) {
            NSMutableDictionary *m = [gPrefs mutableCopy];
            [m addEntriesFromDictionary:file];
            gPrefs = [m copy];
        }
    }
    if (!gIsSpringBoard) {
        gReport = (gReport & ~0xffff00ULL) | ((uint64_t)MIN([gPrefs[kCHHiddenContacts] count], (NSUInteger)0xffff) << 8);
        CHReportPublish();
    }
    gMissedCount = [gPrefs[kCHMissedCount] integerValue];
    CHDiag(@"prefs reloaded: enabled=%d hidden=%lu missed=%ld", CHEnabled(), (unsigned long)[gPrefs[kCHHiddenContacts] count], (long)gMissedCount);
}

#pragma mark - Matching

static BOOL CHMatchNumbersOrId(NSString *cid, NSString *num) {
    NSArray *hidden = gPrefs[kCHHiddenContacts];
    if (![hidden isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *e in hidden) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *eid = e[kCHEntryID];
        if (cid.length && [eid isKindOfClass:[NSString class]] && [eid isEqualToString:cid]) return YES;
        if (num.length) for (NSString *n in e[kCHEntryNumbers])
            if ([n isKindOfClass:[NSString class]] && n.length && ([num hasSuffix:n] || [n hasSuffix:num])) return YES;
    }
    return NO;
}

static BOOL CHObjHidden(id call) {
    if (!CHEnabled() || !call) return NO;
    @try {
        NSString *uuid = nil, *cid = nil, *num = nil;
        if ([call respondsToSelector:@selector(callUUID)]) uuid = [call callUUID];
        if (uuid && [gRevealed containsObject:uuid]) return NO;
        if ([call respondsToSelector:@selector(contactIdentifier)]) cid = [call contactIdentifier];
        if ([call respondsToSelector:@selector(handle)]) {
            TUHandle *h = (TUHandle *)[call handle];
            if ([h respondsToSelector:@selector(value)]) num = CHNormalizeNumber(h.value);
        }
        return CHMatchNumbersOrId(cid, num);
    } @catch (__unused NSException *e) { return NO; }
}

// Name-string match for a bulletin whose fields are plain text.
static BOOL CHTextMatchesHidden(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSArray *hidden = gPrefs[kCHHiddenContacts];
    if (![hidden isKindOfClass:[NSArray class]]) return NO;
    NSString *numInText = CHNormalizeNumber(text);
    for (NSDictionary *e in hidden) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = e[kCHEntryName];
        if ([name isKindOfClass:[NSString class]] && name.length &&
            [text rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if (numInText.length) for (NSString *n in e[kCHEntryNumbers])
            if ([n isKindOfClass:[NSString class]] && n.length && ([numInText hasSuffix:n] || [n hasSuffix:numInText])) return YES;
    }
    return NO;
}

#pragma mark - Red indicator window (SpringBoard only)

@interface CHIndicatorWindow : UIWindow
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, weak)   id call;
@end

@implementation CHIndicatorWindow
+ (instancetype)shared {
    static CHIndicatorWindow *w = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [[CHIndicatorWindow alloc] init]; });
    return w;
}
- (instancetype)init {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    if (scene) self = [super initWithWindowScene:scene]; else self = [super initWithFrame:UIScreen.mainScreen.bounds];
    if (!self) return nil;
    self.windowLevel = UIWindowLevelAlert + 2000;
    self.backgroundColor = UIColor.clearColor; self.hidden = YES;
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;

    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [_button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
    [self.rootViewController.view addSubview:_button];

    _badge = [[UILabel alloc] init];
    _badge.backgroundColor = [UIColor colorWithRed:0.80 green:0.12 blue:0.12 alpha:1.0];
    _badge.textColor = UIColor.whiteColor;
    _badge.font = [UIFont boldSystemFontOfSize:11];
    _badge.textAlignment = NSTextAlignmentCenter;
    _badge.clipsToBounds = YES; _badge.hidden = YES;
    [_button addSubview:_badge];

    [self styleButton];
    [self restorePosition];
    return self;
}
- (void)styleButton {
    CGFloat size = CHFloat(kCHIconSize, 30);
    _button.bounds = CGRectMake(0,0,size,size);
    // A small white dot so the red glyph stays visible on any wallpaper.
    _button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _button.layer.cornerRadius = size/2.0;
    _button.layer.shadowColor = UIColor.blackColor.CGColor; _button.layer.shadowOpacity = 0.35;
    _button.layer.shadowRadius = 3; _button.layer.shadowOffset = CGSizeMake(0,1);
    _button.tintColor = [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1.0]; // red phone glyph
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size*0.52 weight:UIImageSymbolWeightSemibold];
    [_button setImage:[UIImage systemImageNamed:@"phone.fill" withConfiguration:cfg] forState:UIControlStateNormal];
    CGFloat b = 17;
    _badge.frame = CGRectMake(size-b+2, -4, b, b);
    _badge.layer.cornerRadius = b/2.0;
}
- (void)refreshBadge {
    if (gMissedCount > 0 && !gHiddenRinging) { _badge.text = (gMissedCount>99)?@"99+":[NSString stringWithFormat:@"%ld",(long)gMissedCount]; _badge.hidden = NO; }
    else _badge.hidden = YES;
}
- (void)restorePosition {
    CGRect scr = UIScreen.mainScreen.bounds; CGFloat size = _button.bounds.size.width;
    CGFloat x = CHFloat(kCHIconX, scr.size.width-size-14), y = CHFloat(kCHIconY, 72);
    x = MAX(0,MIN(x,scr.size.width-size)); y = MAX(0,MIN(y,scr.size.height-size));
    _button.frame = CGRectMake(x,y,size,size);
}
- (void)savePosition {
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconX,(__bridge CFNumberRef)@(_button.frame.origin.x),(__bridge CFStringRef)kCHAppID,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconY,(__bridge CFNumberRef)@(_button.frame.origin.y),(__bridge CFStringRef)kCHAppID,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
}
- (void)panned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self]; CGRect f = _button.frame; CGRect b = self.bounds;
    f.origin.x = MAX(0,MIN(f.origin.x+t.x,b.size.width-f.size.width));
    f.origin.y = MAX(0,MIN(f.origin.y+t.y,b.size.height-f.size.height));
    _button.frame = f; [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) [self savePosition];
}
- (void)tapped {
    @try {
        if (gHiddenRinging && CHTapToAnswer() && self.call) {
            if ([self.call respondsToSelector:@selector(callUUID)]) {
                NSString *u = [self.call callUUID];
                if (u) { NSMutableSet *s = [gRevealed mutableCopy]; [s addObject:u]; gRevealed = s; }
            }
            id cc = [objc_getClass("TUCallCenter") sharedInstance];
            if ([cc respondsToSelector:@selector(answerCall:)]) [cc answerCall:self.call];
            gHiddenRinging = NO; CHRestoreRinger(); CHRestoreDisplay();   // bring ringer + display back now
            return;
        }
        // Otherwise: clear the "you had a hidden call" indicator.
        gMissedCount = 0; CHPersistMissed();
        [self refreshBadge]; self.hidden = YES;
        CHDiag(@"missed indicator cleared by tap");
    } @catch (__unused NSException *e) {}
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    return CGRectContainsPoint(_button.frame, point) ? [super hitTest:point withEvent:event] : nil;
}
- (void)showForCall:(id)call {
    self.call = call; [self styleButton]; [self restorePosition]; [self refreshBadge]; self.hidden = NO;
}
@end

// Central icon visibility: show while ringing OR while there are unseen misses.
static void CHUpdateIcon(id ringingCall) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            CHIndicatorWindow *w = [CHIndicatorWindow shared];
            if (gHiddenRinging || gMissedCount > 0) [w showForCall:ringingCall];
            else { w.hidden = YES; }
        } @catch (__unused NSException *e) {}
    });
}

// The call ringtone (and its vibration) is produced in callservicesd by a
// ToneLibrary alert. For a hidden call we (a) temporarily drop the system ringer
// (proven CallKiller technique; restored when the call ends), (b) answer NO from
// TLVibrationManager's should-vibrate getters in every process, and (c) post the
// vibrate-settings-changed notifications so an alert that is already buzzing
// re-evaluates against (b) and stops. Nothing in the user's settings is written.

static void CHNudgeVibrationManagers(void) {
    notify_post(kVibRingChanged);
    notify_post(kVibSilentChanged);
}
// Stop a vibration pattern that is already playing (the ring may have started
// a beat before our flag was raised).
static void CHStopVibrationNow(void) {
    if (!gStopSystemSound) return;
    @try { gStopSystemSound(kSystemSoundID_Vibrate); CHDiag(@"stopped in-progress vibration"); } @catch (__unused NSException *e) {}
}

static void CHMuteRinger(void) {
    // Always mute (the old "only if the ringer was observed on" gate skipped
    // itself after resprings); restore goes back to the last observed state.
    if (!gIsSpringBoard || gWeMutedRinger) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
            if (![sb respondsToSelector:@selector(_updateRingerState:withVisuals:updatePreferenceRegister:)]) return;
            gInOurRinger = YES;
            [sb _updateRingerState:0 withVisuals:NO updatePreferenceRegister:NO];
            gInOurRinger = NO;
            gWeMutedRinger = YES;
            CHNudgeVibrationManagers();              // re-evaluate vibration against our NO
            CHDiag(@"ringer muted for hidden call");
        } @catch (__unused NSException *e) { gInOurRinger = NO; }
    });
}
static void CHRestoreRinger(void) {
    if (!gIsSpringBoard || !gWeMutedRinger) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
            gInOurRinger = YES;
            [sb _updateRingerState:(gSystemRingerOn ? 1 : 0) withVisuals:NO updatePreferenceRegister:NO];
            gInOurRinger = NO;
            gWeMutedRinger = NO;
            CHNudgeVibrationManagers();              // back to the user's real settings
            CHDiag(@"ringer restored");
        } @catch (__unused NSException *e) { gInOurRinger = NO; }
    });
}

#pragma mark - Always-On Display

static BOOL CHLocked(void) {
    @try {
        Class c = objc_getClass("SBLockScreenManager");
        id m = [c respondsToSelector:@selector(sharedInstance)] ? [c sharedInstance] : nil;
        return [m respondsToSelector:@selector(isUILocked)] ? [m isUILocked] : NO;
    } @catch (__unused NSException *e) { return NO; }
}

// While a hidden call rings and the phone is LOCKED, hold the system's
// "disable Always-On" assertion so the display goes fully black (no AOD).
// Never touches the display while you're actively using the phone.
static void CHForceDisplayOff(void) {
    if (!gIsSpringBoard || !CHSuppressWake() || gAODAssertion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!CHLocked()) { CHDiag(@"AOD: phone unlocked/in use; not blanking display"); return; }
            Class A = objc_getClass("BLSAssertion"), D = objc_getClass("BLSDisableAlwaysOnAttribute");
            if (!A || !D || ![D respondsToSelector:@selector(disableAlwaysOn)] ||
                ![A respondsToSelector:@selector(acquireWithExplanation:observer:attributes:)]) {
                CHDiag(@"AOD: BLS disable-always-on API unavailable"); return;
            }
            id attr = [D disableAlwaysOn];
            if (!attr) { CHDiag(@"AOD: no attribute"); return; }
            gAODAssertion = [A acquireWithExplanation:@"CallHider: hidden call" observer:nil attributes:@[attr]];
            CHDiag(@"AOD disable assertion %@", gAODAssertion ? @"requested (display -> off)" : @"FAILED");
            // Acquisition is asynchronous (XPC to the backlight host); report the outcome.
            id a = gAODAssertion;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    if (!a || a != gAODAssertion) return;
                    CHDiag(@"AOD assertion state: acquired=%d active=%d",
                           [a respondsToSelector:@selector(isAcquired)] ? (int)[a isAcquired] : -1,
                           [a respondsToSelector:@selector(isActive)]   ? (int)[a isActive]   : -1);
                } @catch (__unused NSException *e) {}
            });
        } @catch (__unused NSException *e) { CHDiag(@"EXCEPTION forcing display off (caught)"); }
    });
}
static void CHRestoreDisplay(void) {
    if (!gIsSpringBoard || !gAODAssertion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id a = gAODAssertion; gAODAssertion = nil;
            if ([a respondsToSelector:@selector(invalidate)]) [a invalidate];
            CHDiag(@"AOD disable assertion released");
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Phone Recents + hidden-call log

#define CHHideFromRecents() CHBool(kCHHideFromRecents, YES)

// Does a CallHistory entry belong to a hidden caller? (matched by number)
static BOOL CHRecentCallHidden(id rc) {
    @try {
        if (![rc respondsToSelector:@selector(callerId)]) return NO;
        NSString *num = CHNormalizeNumber([rc callerId]);
        return num.length > 0 && CHMatchNumbersOrId(nil, num);
    } @catch (__unused NSException *e) { return NO; }
}

// Append a hidden call to the persisted log shown in Settings (capped).
static void CHRecordHiddenCall(NSString *name, NSString *number) {
    @try {
        NSArray *cur = (__bridge_transfer NSArray *)CFPreferencesCopyValue((__bridge CFStringRef)kCHCallLog,
            (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        NSMutableArray *log = [cur isKindOfClass:[NSArray class]] ? [cur mutableCopy] : [NSMutableArray array];
        [log addObject:@{ kCHLogName: name ?: @"", kCHLogNumber: number ?: @"",
                          kCHLogDate: @([[NSDate date] timeIntervalSince1970]) }];
        while (log.count > kCHCallLogMax) [log removeObjectAtIndex:0];
        CFPreferencesSetValue((__bridge CFStringRef)kCHCallLog, (__bridge CFArrayRef)log,
            (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
        CHDiag(@"logged hidden call %@ %@", name ?: @"", number ?: @"");
    } @catch (__unused NSException *e) {}
}

// Belt-and-suspenders for Recents: a few seconds after a hidden call ends,
// delete any entry callservicesd wrote for it. SpringBoard reads our prefs
// reliably (callservicesd may be sandboxed from them), so this always runs.
static void CHPurgeFromRecents(NSString *number) {
    if (!gIsSpringBoard || !CHHideFromRecents()) return;
    NSString *want = CHNormalizeNumber(number);
    if (!want.length) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            Class M = objc_getClass("CHManager");
            if (!M) { CHDiag(@"CHManager not available; cannot purge Recents"); return; }
            CHManager *mgr = [[M alloc] init];
            NSArray *recent = [mgr fetchRecentCallsSyncWithCoalescing:NO];
            NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-180];
            int n = 0;
            for (CHRecentCall *rc in recent) {
                if (![rc respondsToSelector:@selector(callerId)]) continue;
                NSString *num = CHNormalizeNumber(rc.callerId);
                if (!num.length || !([num hasSuffix:want] || [want hasSuffix:num])) continue;
                if (rc.date && [rc.date compare:since] == NSOrderedAscending) continue;   // only the recent one(s)
                [mgr deleteCall:rc]; n++;
            }
            CHDiag(@"purged %d Recents entr%@ for hidden caller", n, n == 1 ? @"y" : @"ies");
        } @catch (__unused NSException *e) { CHDiag(@"EXCEPTION purging Recents (caught)"); }
    });
}

#pragma mark - Hooks

%group SpringBoardGroup

%hook SBInCallPresentationManager
- (void)inCallPresentationRequestServer:(id)server clientWithIdentifier:(id)ident
       requestsPresentationWithConfiguration:(id)config completion:(void (^)(id))completion {
    if (CHSuppressUI() && gHiddenRinging) {
        CHDiag(@"PRES-HOOK suppressed (hiddenRinging=1)");
        @try { if (completion) completion(nil); } @catch (__unused NSException *e) {}
        return;                       // don't present the call UI
    }
    CHDiag(@"PRES-HOOK passthrough");
    %orig;
}
%end

%hook SBBacklightController
- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    if (CHSuppressWake() && gHiddenRinging) { CHDiag(@"wake blocked src=%lld", source); return; }
    %orig;
}
%end

%hook BBServer
- (void)publishBulletinRequest:(BBBulletinRequest *)req destinations:(unsigned long long)dest {
    @try {
        if (CHEnabled() && CHHideMissed() && [req isKindOfClass:objc_getClass("BBBulletinRequest")]) {
            NSString *sec = req.sectionID ?: @"";
            BOOL callSection = ([sec rangeOfString:@"mobilephone"].location != NSNotFound ||
                                [sec rangeOfString:@"facetime"].location   != NSNotFound ||
                                [sec rangeOfString:@"InCall"].location      != NSNotFound);
            if (callSection) {
                BOOL hit = NO;
                BBContact *sender = req.communicationContext.sender;
                if (sender) {
                    NSString *cid = [sender respondsToSelector:@selector(cnContactIdentifier)] ? sender.cnContactIdentifier : nil;
                    NSString *num = [sender respondsToSelector:@selector(handle)] ? CHNormalizeNumber(sender.handle) : nil;
                    if (CHMatchNumbersOrId(cid, num)) hit = YES;
                }
                if (!hit && (CHTextMatchesHidden(req.title) || CHTextMatchesHidden(req.subtitle) || CHTextMatchesHidden(req.message))) hit = YES;
                if (hit) { CHDiag(@"dropped call bulletin sec=%@ title=%@", sec, req.title ?: @"(nil)"); return; }
            }
        }
    } @catch (__unused NSException *e) { CHDiag(@"EXCEPTION in BBServer hook (caught)"); }
    %orig;
}
%end

%hook SpringBoard
// Track the ringer state the system sets, so CHMuteRinger only acts when the
// ringer was actually on (and knows what to restore to).
- (void)_updateRingerState:(int)state withVisuals:(BOOL)v updatePreferenceRegister:(BOOL)p {
    if (!gInOurRinger) gSystemRingerOn = (state != 0);
    %orig;
}
%end

%hook SBInCallBannerPresentableViewController
// The Dynamic Island call pill: PRES-HOOK doesn't stop it, so keep this banner's
// view off screen while a hidden call is ringing. %orig runs first (safe), then
// we hide; re-applied on layout in case the system un-hides it.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        if (CHSuppressUI() && gHiddenRinging) {
            CHDiag(@"hiding in-call banner VC (Dynamic Island) for hidden call");
            self.view.hidden = YES; self.view.alpha = 0.0;
        }
    } @catch (__unused NSException *e) {}
}
- (void)viewWillLayoutSubviews {
    %orig;
    @try { if (CHSuppressUI() && gHiddenRinging) { self.view.hidden = YES; self.view.alpha = 0.0; } } @catch (__unused NSException *e) {}
}
%end

%end // SpringBoardGroup

// Block system sounds / simple vibration while a hidden call rings — in EVERY
// process we load into (callservicesd is where the ring is produced). Scoped to
// the hidden ring only; these calls have no completion to leave hanging.
%hookf(void, AudioServicesPlaySystemSound, SystemSoundID sound) {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"blocked system sound %u (hidden ring)", (unsigned)sound); return; }
    %orig;
}
%hookf(void, AudioServicesPlayAlertSound, SystemSoundID sound) {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"blocked alert sound %u (hidden ring)", (unsigned)sound); return; }
    %orig;
}

// Patterned (call) vibration goes through this private AudioToolbox export, not
// the two public calls above. It is NOT in the SDK's link stubs, so it lives in
// its own group and is bound at runtime via dlsym in %ctor — never referenced
// at link time, and simply skipped if the symbol isn't present.
%group VibHook
%hookf(void, AudioServicesPlaySystemSoundWithVibration, SystemSoundID sound, id arg, NSDictionary *pattern) {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"blocked patterned vibration %u (hidden ring)", (unsigned)sound); return; }
    %orig;
}
%end

// The decision point itself: the ringtone alert asks these before (and while)
// vibrating. Installed wherever ToneLibrary is loaded (callservicesd + SpringBoard).
%group ToneGroup
%hook TLVibrationManager
- (BOOL)shouldVibrateOnRing {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"vibration manager asked (ring) -> NO"); return NO; }
    return %orig;
}
- (BOOL)shouldVibrateOnSilent {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"vibration manager asked (silent) -> NO"); return NO; }
    return %orig;
}
- (BOOL)shouldVibrateForCurrentRingerSwitchState {
    if (gHiddenRinging && CHSilenceRinger()) { CHDiag(@"vibration manager asked (switch) -> NO"); return NO; }
    return %orig;
}
%end
%end

%hook TUCall

- (BOOL)shouldSuppressRingtone {
    @try { if (CHSilenceRinger() && CHObjHidden(self)) return YES; } @catch (__unused NSException *e) {}
    return %orig;
}

- (void)_handleStatusChange {
    // Raise the flag BEFORE the system reacts to the change, so the first
    // "should we vibrate?" question for a hidden ring already gets NO.
    @try {
        if ([self respondsToSelector:@selector(isIncoming)] && self.isIncoming &&
            [self respondsToSelector:@selector(callStatus)] && self.callStatus == 4 && CHObjHidden(self))
            gHiddenRinging = YES;
    } @catch (__unused NSException *e) {}
    %orig;
    @try {
        if (![self respondsToSelector:@selector(isIncoming)] || !self.isIncoming) return;
        BOOL hidden = CHObjHidden(self);
        int st = [self respondsToSelector:@selector(callStatus)] ? self.callStatus : -1;
        NSString *uuid = [self respondsToSelector:@selector(callUUID)] ? self.callUUID : nil;
        CHDiag(@"status=%d incoming=1 handle=%@ -> hidden=%d", st,
               ([self.handle respondsToSelector:@selector(value)]?self.handle.value:@"(nil)") ?: @"(nil)", hidden);
        if (!gIsSpringBoard) {                    // tell SpringBoard what this process saw
            gReport = (gReport & ~(3ULL << 24)) | (hidden ? (1ULL << 24) : 0);
            CHReportPublish();
        }
        if (!hidden) return;

        BOOL ringing = (st == 4);
        gHiddenRinging = ringing;
        if (CHSilenceRinger()) {
            // Flag the call itself (this runs in every process that holds the
            // call, including callservicesd, the source of truth) and raise the
            // Continuity "silenced remotely" flag, which reaches the ringtone server.
            BOOL applied = NO;
            if ([self respondsToSelector:@selector(setShouldSuppressRingtone:)])    { [(id)self setShouldSuppressRingtone:YES];    applied = YES; }
            if ([self respondsToSelector:@selector(setRingtoneSuppressedRemotely:)]) { [(id)self setRingtoneSuppressedRemotely:YES]; applied = YES; }
            if (!gIsSpringBoard) { if (applied) gReport |= (1ULL << 25); CHReportPublish(); }
            else CHDiag(@"ring-suppression flags set on call (remote=%d)", [self respondsToSelector:@selector(setRingtoneSuppressedRemotely:)]);
        }
        if (ringing) {
            if (CHSilenceRinger()) {
                CHMuteRinger();                        // SpringBoard: drop the ringer
                CHStopVibrationNow();                  // kill a pattern already buzzing
                CHNudgeVibrationManagers();            // make the alert re-ask (-> NO)
            }
            CHReportLogFromSpringBoard();              // what did callservicesd see/do?
            CHForceDisplayOff();                       // locked: fully black, no Always-On
            CHUpdateIcon(self);
            // safety net: never leave the ringer muted beyond a normal ring
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (!gHiddenRinging) { CHRestoreRinger(); CHRestoreDisplay(); } });
        }

        if (st == 5 || st == 6) {                 // disconnecting / disconnected
            gHiddenRinging = NO;
            CHRestoreRinger();
            CHRestoreDisplay();
            CHNudgeVibrationManagers();           // vibration decisions back to the user's settings
            BOOL answered = (uuid && [gRevealed containsObject:uuid]);
            // Record once per call (status 5 and 6 both arrive): log it, purge it
            // from Phone Recents, and bump the red-glyph counter if it was missed.
            if (gIsSpringBoard && uuid && ![gLoggedUUID isEqualToString:uuid]) {
                gLoggedUUID = uuid;
                NSString *num  = [self.handle respondsToSelector:@selector(value)] ? self.handle.value : nil;
                NSString *name = [self respondsToSelector:@selector(displayName)] ? self.displayName : nil;
                CHRecordHiddenCall(name, num);
                CHPurgeFromRecents(num);
                if (!answered) {                  // a MISSED hidden call -> persistent indicator
                    gMissedCount++; CHPersistMissed();
                    CHDiag(@"missed hidden call -> count=%ld", (long)gMissedCount);
                }
            }
            CHUpdateIcon(nil);
        }
    } @catch (__unused NSException *e) { CHDiag(@"EXCEPTION in _handleStatusChange (caught)"); }
}

%end

// Phone-app Recents: stop hidden callers being written to the call history.
// callservicesd performs the write; this runs there if it can read our prefs.
// (SpringBoard's CHPurgeFromRecents covers the case where it can't.)
%hook CHManager
- (void)addToCallHistory:(id)call {
    @try {
        if (CHEnabled() && CHHideFromRecents() && CHRecentCallHidden(call)) {
            CHDiag(@"blocked Recents write for hidden caller"); return;
        }
    } @catch (__unused NSException *e) {}
    %orig;
}
- (void)addMultipleCallsToCallHistory:(id)calls {
    @try {
        if (CHEnabled() && CHHideFromRecents() && [calls isKindOfClass:[NSArray class]]) {
            NSMutableArray *keep = [NSMutableArray array];
            for (id c in calls) if (!CHRecentCallHidden(c)) [keep addObject:c];
            if (keep.count != [(NSArray *)calls count]) {
                CHDiag(@"filtered %lu hidden caller(s) from a Recents batch", (unsigned long)([(NSArray *)calls count] - keep.count));
                %orig(keep); return;
            }
        }
    } @catch (__unused NSException *e) {}
    %orig;
}
%end

#pragma mark - Init

%ctor {
    @autoreleasepool {
        gProc = NSProcessInfo.processInfo.processName;
        gIsSpringBoard = [gProc isEqualToString:@"SpringBoard"];
        gRevealed = [NSSet set];
        CHReload();
        if (!gIsSpringBoard) { gReport |= 1ULL; CHReportPublish(); }   // "loaded" bit for the report
        CHDiag(@"CallHider v1.6.2 loaded in %@ (springboard=%d, missed=%ld)", gProc, gIsSpringBoard, (long)gMissedCount);

        %init(_ungrouped);
        if (gIsSpringBoard) %init(SpringBoardGroup);
        // Vibration levers go wherever the ring can be produced (callservicesd first).
        if (objc_getClass("TLVibrationManager")) { %init(ToneGroup); CHDiag(@"ToneLibrary vibration hooks installed"); }
        else CHDiag(@"ToneLibrary not loaded here; vibration-manager hooks skipped");
        // Bind the private AudioToolbox exports at runtime (they can't be linked).
        void *vib = dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSoundWithVibration");
        if (vib) { %init(VibHook, AudioServicesPlaySystemSoundWithVibration = vib); CHDiag(@"patterned-vibration hook installed"); }
        else CHDiag(@"patterned-vibration symbol not found; hook skipped");
        gStopSystemSound = (void (*)(SystemSoundID))dlsym(RTLD_DEFAULT, "AudioServicesStopSystemSound");

        int t1; notify_register_dispatch(kCHReloadNotify, &t1, dispatch_get_main_queue(), ^(int t){ CHReload(); CHUpdateIcon(nil); });
        if (gIsSpringBoard) {
            // restore persistent indicator after SpringBoard launch
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ CHUpdateIcon(nil); });

            int t2; notify_register_dispatch(kCHTestIconNotify, &t2, dispatch_get_main_queue(), ^(int t){
                CHDiag(@"test icon requested");
                [[CHIndicatorWindow shared] showForCall:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!gHiddenRinging && gMissedCount == 0) [CHIndicatorWindow shared].hidden = YES;
                });
            });
            int t3; notify_register_dispatch(kCHClearLogNotify, &t3, dispatch_get_main_queue(), ^(int t){
                [[NSFileManager defaultManager] removeItemAtPath:kCHDiagPath error:nil]; CHDiag(@"log cleared");
            });
            int t4; notify_register_dispatch(kCHClearMissedNotify, &t4, dispatch_get_main_queue(), ^(int t){
                gMissedCount = 0; CHPersistMissed(); CHDiag(@"missed indicator cleared from settings"); CHUpdateIcon(nil);
            });
        }
    }
}
