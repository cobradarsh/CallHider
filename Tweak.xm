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
#import <notify.h>
#import <objc/runtime.h>
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

#pragma mark - State

static BOOL gIsSpringBoard = NO;
static NSString *gProc = nil;
static NSDictionary *gPrefs = nil;
static NSSet<NSString *> *gRevealed;
static volatile BOOL gHiddenRinging = NO;
static NSInteger gMissedCount = 0;        // persistent "you had a hidden call" count
static BOOL gSystemRingerOn = YES;        // last ringer state the SYSTEM set
static BOOL gWeMutedRinger = NO;          // we lowered the ringer for a hidden call
static BOOL gInOurRinger = NO;            // guard so our own calls don't self-record

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

static void CHReload(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    NSArray *keys = @[kCHEnabled, kCHSilenceRinger, kCHSuppressWake, kCHSuppressUI, kCHTapToAnswer,
                      kCHHideMissedNotif, kCHIconX, kCHIconY, kCHIconSize, kCHMissedCount, kCHHiddenContacts];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        id v = (__bridge_transfer id)CFPreferencesCopyValue((__bridge CFStringRef)k, (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) d[k] = v;
    }
    gPrefs = [d copy];
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
            gHiddenRinging = NO; CHRestoreRinger();   // bring the ringer back now
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

// The call ringtone (and vibration) is produced by the ringtone SERVER, where
// our shouldSuppressRingtone hook has no effect — so for a hidden call we
// temporarily drop the system ringer (proven CallKiller technique) and restore
// it when the call ends. We only touch it if the ringer was actually on, so we
// never un-silence a phone that was already silent.
static void CHMuteRinger(void) {
    if (!gIsSpringBoard || gWeMutedRinger || !gSystemRingerOn) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SpringBoard *sb = (SpringBoard *)[UIApplication sharedApplication];
            if (![sb respondsToSelector:@selector(_updateRingerState:withVisuals:updatePreferenceRegister:)]) return;
            gInOurRinger = YES;
            [sb _updateRingerState:0 withVisuals:NO updatePreferenceRegister:NO];
            gInOurRinger = NO;
            gWeMutedRinger = YES;
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
            [sb _updateRingerState:1 withVisuals:NO updatePreferenceRegister:NO];
            gInOurRinger = NO;
            gWeMutedRinger = NO;
            CHDiag(@"ringer restored");
        } @catch (__unused NSException *e) { gInOurRinger = NO; }
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

%hook TUCall

- (BOOL)shouldSuppressRingtone {
    @try { if (CHSilenceRinger() && CHObjHidden(self)) return YES; } @catch (__unused NSException *e) {}
    return %orig;
}

- (void)_handleStatusChange {
    %orig;
    @try {
        if (![self respondsToSelector:@selector(isIncoming)] || !self.isIncoming) return;
        BOOL hidden = CHObjHidden(self);
        int st = [self respondsToSelector:@selector(callStatus)] ? self.callStatus : -1;
        NSString *uuid = [self respondsToSelector:@selector(callUUID)] ? self.callUUID : nil;
        CHDiag(@"status=%d incoming=1 handle=%@ -> hidden=%d", st,
               ([self.handle respondsToSelector:@selector(value)]?self.handle.value:@"(nil)") ?: @"(nil)", hidden);
        if (!hidden) return;

        BOOL ringing = (st == 4);
        gHiddenRinging = ringing;
        if (CHSilenceRinger() && [self respondsToSelector:@selector(setShouldSuppressRingtone:)]) [(id)self setShouldSuppressRingtone:YES];
        if (ringing) {
            if (CHSilenceRinger()) CHMuteRinger();     // kills ringtone + ring-mode vibration
            CHUpdateIcon(self);
            // safety net: never leave the ringer muted beyond a normal ring
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (!gHiddenRinging) CHRestoreRinger(); });
        }

        if (st == 5 || st == 6) {                 // disconnecting / disconnected
            gHiddenRinging = NO;
            CHRestoreRinger();
            BOOL answered = (uuid && [gRevealed containsObject:uuid]);
            if (!answered) {                      // a MISSED hidden call -> persistent indicator
                gMissedCount++; CHPersistMissed();
                CHDiag(@"missed hidden call -> count=%ld", (long)gMissedCount);
            }
            CHUpdateIcon(nil);
        }
    } @catch (__unused NSException *e) { CHDiag(@"EXCEPTION in _handleStatusChange (caught)"); }
}

%end

#pragma mark - Init

%ctor {
    @autoreleasepool {
        gProc = NSProcessInfo.processInfo.processName;
        gIsSpringBoard = [gProc isEqualToString:@"SpringBoard"];
        gRevealed = [NSSet set];
        CHReload();
        CHDiag(@"CallHider v1.2.2 loaded in %@ (springboard=%d, missed=%ld)", gProc, gIsSpringBoard, (long)gMissedCount);

        %init(_ungrouped);
        if (gIsSpringBoard) %init(SpringBoardGroup);

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
