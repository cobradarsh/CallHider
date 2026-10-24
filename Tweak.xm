// CallHider — hide incoming calls (cellular + VoIP) from selected contacts.
//
// v1.1.1 notes (from on-device diagnostics of v1.1.0):
//   * Contact matching works (handle/contactIdentifier -> hidden=1). Good.
//   * SpringBoard crashed into safe mode at call status 4 (actively ringing).
//     The only call that does anything during a live ring is -suppressRingtone,
//     so that is removed. Ringtone is now silenced ONLY via the writable
//     -shouldSuppressRingtone property (getter forced + setter), which is safe.
//   * The presentation hook never logged, i.e. the guessed selector never fired.
//     It now logs the moment it runs and does NOT swallow the request this build
//     (so it can't destabilise SpringBoard) — purely to confirm whether/when it
//     fires, so the next build can target the real presentation path.
//   * Every suppression step is individually logged; if anything still trips,
//     the LAST line in Diagnostics names the exact step.
//   * The screen-wake block now keys off a cached flag (no call-center query on
//     the backlight path) and logs before it acts.

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import "CHPrefs.h"

#pragma mark - Private interfaces (iOS 16 runtime headers)

@interface TUHandle : NSObject
@property (nonatomic, readonly, copy) NSString *value;
@end

@interface TUCall : NSObject
@property (nonatomic, readonly) int callStatus;
@property (getter=isIncoming, nonatomic, readonly) BOOL incoming;
@property (getter=isVoIPCall, nonatomic, readonly) BOOL voipCall;
@property (nonatomic, readonly) TUHandle *handle;
@property (nonatomic, readonly, copy) NSString *contactIdentifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *callUUID;
@end

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly, copy) NSArray *currentCalls;
- (void)answerCall:(TUCall *)call;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
- (void)turnOnScreenFullyWithBacklightSource:(long long)source;
@end

#pragma mark - State

static BOOL gIsSpringBoard = NO;
static NSString *gProc = nil;
static NSDictionary *gPrefs = nil;
static NSSet<NSString *> *gRevealed;        // call UUIDs the user chose to reveal
static volatile BOOL gHiddenRinging = NO;   // a hidden call is ringing right now

#pragma mark - Diagnostics (file shared with the Settings bundle)

static void CHDiag(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@  [%@] %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle],
        gProc ?: @"?", msg];
    NSLog(@"[CallHider] %@", msg);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kCHDiagDir])
            [fm createDirectoryAtPath:kCHDiagDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *at = [fm attributesOfItemAtPath:kCHDiagPath error:nil];
        if ([at fileSize] > 64*1024) [fm removeItemAtPath:kCHDiagPath error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kCHDiagPath];
        if (!fh) { [line writeToFile:kCHDiagPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

#pragma mark - Preferences

static BOOL CHBool(NSString *key, BOOL def) { id v = gPrefs[key]; return (v==nil)?def:[v boolValue]; }
static CGFloat CHFloat(NSString *key, CGFloat def) { id v = gPrefs[key]; return (v==nil)?def:[v doubleValue]; }
#define CHEnabled()       CHBool(kCHEnabled, YES)
#define CHSilenceRinger() CHBool(kCHSilenceRinger, YES)
#define CHSuppressWake()  CHBool(kCHSuppressWake, YES)
#define CHSuppressUI()    CHBool(kCHSuppressUI, YES)
#define CHTapToAnswer()   CHBool(kCHTapToAnswer, NO)

static void CHReload(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    NSArray *keys = @[kCHEnabled, kCHSilenceRinger, kCHSuppressWake, kCHSuppressUI,
                      kCHTapToAnswer, kCHIconX, kCHIconY, kCHIconSize, kCHHiddenContacts];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        id v = (__bridge_transfer id)CFPreferencesCopyValue(
            (__bridge CFStringRef)k, (__bridge CFStringRef)kCHAppID,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) d[k] = v;
    }
    gPrefs = [d copy];
    CHDiag(@"prefs reloaded: enabled=%d hidden=%lu", CHEnabled(),
           (unsigned long)[gPrefs[kCHHiddenContacts] count]);
}

#pragma mark - Matching (fully guarded: call-center arrays may hold proxy objects)

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
        if ([call respondsToSelector:@selector(callUUID)])          uuid = [call callUUID];
        if (uuid && [gRevealed containsObject:uuid]) return NO;
        if ([call respondsToSelector:@selector(contactIdentifier)]) cid  = [call contactIdentifier];
        if ([call respondsToSelector:@selector(handle)]) {
            id h = [call handle];
            if ([h respondsToSelector:@selector(value)]) num = CHNormalizeNumber([h value]);
        }
        return CHMatchNumbersOrId(cid, num);
    } @catch (__unused NSException *e) { return NO; }
}

#pragma mark - Red indicator window (SpringBoard only)

@interface CHIndicatorWindow : UIWindow
@property (nonatomic, strong) UIButton *button;
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
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    if (scene) self = [super initWithWindowScene:scene];
    else       self = [super initWithFrame:UIScreen.mainScreen.bounds];
    if (!self) return nil;
    self.windowLevel = UIWindowLevelAlert + 2000;
    self.backgroundColor = UIColor.clearColor; self.hidden = YES;
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;
    CGFloat size = CHFloat(kCHIconSize, 44);
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = CGRectMake(0,0,size,size);
    _button.backgroundColor = [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1.0];
    _button.layer.cornerRadius = size/2.0;
    _button.layer.shadowColor = UIColor.blackColor.CGColor; _button.layer.shadowOpacity = 0.35;
    _button.layer.shadowRadius = 4; _button.layer.shadowOffset = CGSizeMake(0,1);
    _button.tintColor = UIColor.whiteColor;
    [_button setImage:[UIImage systemImageNamed:@"phone.fill"] forState:UIControlStateNormal];
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [_button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
    [self.rootViewController.view addSubview:_button];
    [self restorePosition];
    return self;
}
- (void)restorePosition {
    CGRect b = UIScreen.mainScreen.bounds; CGFloat size = _button.bounds.size.width;
    CGFloat x = CHFloat(kCHIconX, b.size.width-size-12), y = CHFloat(kCHIconY, 70);
    x = MAX(0,MIN(x,b.size.width-size)); y = MAX(0,MIN(y,b.size.height-size));
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
    if (!CHTapToAnswer() || !self.call) return;
    @try {
        if ([self.call respondsToSelector:@selector(callUUID)]) {
            NSString *u = [self.call callUUID];
            if (u) { NSMutableSet *s = [gRevealed mutableCopy]; [s addObject:u]; gRevealed = s; }
        }
        id cc = [objc_getClass("TUCallCenter") sharedInstance];
        if ([cc respondsToSelector:@selector(answerCall:)]) [cc answerCall:self.call];
    } @catch (__unused NSException *e) {}
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    return CGRectContainsPoint(_button.frame, point) ? [super hitTest:point withEvent:event] : nil;
}
- (void)showForCall:(id)call {
    self.call = call; CGFloat size = CHFloat(kCHIconSize, 44);
    [self restorePosition];
    CGRect f = _button.frame; f.size = CGSizeMake(size,size); _button.frame = f;
    _button.layer.cornerRadius = size/2.0; self.hidden = NO;
}
- (void)hide { self.hidden = YES; self.call = nil; }
@end

static void CHShowIcon(id call) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{ @try { [[CHIndicatorWindow shared] showForCall:call]; } @catch(__unused NSException *e){} });
}
static void CHHideIcon(void) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{ @try { [[CHIndicatorWindow shared] hide]; } @catch(__unused NSException *e){} });
}

#pragma mark - Hooks

%group SpringBoardGroup

%hook SBInCallPresentationManager
- (void)inCallPresentationRequestServer:(id)server
                     clientWithIdentifier:(id)ident
       requestsPresentationWithConfiguration:(id)config
                               completion:(void (^)(id))completion {
    // Observe only this build: confirm this path fires. Do NOT swallow.
    CHDiag(@"PRES-HOOK fired (hiddenRinging=%d)", gHiddenRinging);
    %orig;
}
%end

%hook SBBacklightController
- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    BOOL block = (CHSuppressWake() && gHiddenRinging);
    CHDiag(@"wake asked src=%lld hiddenRinging=%d block=%d", source, gHiddenRinging, block);
    if (block) { CHDiag(@"wake blocked"); return; }
    %orig;
}
%end

%end // SpringBoardGroup

%hook TUCall

// Forced getter: whenever the system checks, hidden calls report "suppress ring".
// Safe (returns a BOOL only) — this is the ring-silencing mechanism now.
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
        NSString *h = ([self respondsToSelector:@selector(handle)] && [self.handle respondsToSelector:@selector(value)]) ? self.handle.value : @"(nil)";
        CHDiag(@"status=%d incoming=1 handle=%@ -> hidden=%d", st, h ?: @"(nil)", hidden);

        if (hidden) {
            // status 4 = ringing, 1 = connected/active. Treat "ringing" as active-hidden.
            BOOL ringing = (st == 4);
            gHiddenRinging = ringing;
            CHDiag(@"  set gHiddenRinging=%d", gHiddenRinging);

            // Silence via property setter only (NO -suppressRingtone action; that crashed).
            if (CHSilenceRinger() && [self respondsToSelector:@selector(setShouldSuppressRingtone:)]) {
                CHDiag(@"  pre setShouldSuppressRingtone");
                [(id)self setShouldSuppressRingtone:YES];
                CHDiag(@"  post setShouldSuppressRingtone");
            }
            CHDiag(@"  pre showIcon");
            CHShowIcon(self);
            CHDiag(@"  post showIcon");
        } else {
            // Not hidden (or revealed) -> make sure we're not holding the wake block.
            // (Only clear if this is the call we were tracking state for.)
        }

        // Call finished? statuses 5/6 = disconnecting/disconnected.
        if (st == 5 || st == 6) {
            gHiddenRinging = NO;
            if (hidden) { CHDiag(@"  call ended -> hide icon"); CHHideIcon(); }
        }
    } @catch (__unused NSException *e) {
        CHDiag(@"EXCEPTION in _handleStatusChange (caught)");
    }
}

%end

#pragma mark - Init

%ctor {
    @autoreleasepool {
        gProc = NSProcessInfo.processInfo.processName;
        gIsSpringBoard = [gProc isEqualToString:@"SpringBoard"];
        gRevealed = [NSSet set];
        CHReload();
        CHDiag(@"CallHider v1.1.1 loaded in %@ (springboard=%d)", gProc, gIsSpringBoard);

        %init(_ungrouped);
        if (gIsSpringBoard) %init(SpringBoardGroup);

        int t1; notify_register_dispatch(kCHReloadNotify, &t1, dispatch_get_main_queue(), ^(int t){ CHReload(); });
        if (gIsSpringBoard) {
            int t2; notify_register_dispatch(kCHTestIconNotify, &t2, dispatch_get_main_queue(), ^(int t){
                CHDiag(@"test icon requested");
                [[CHIndicatorWindow shared] showForCall:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!gHiddenRinging) [[CHIndicatorWindow shared] hide];
                });
            });
            int t3; notify_register_dispatch(kCHClearLogNotify, &t3, dispatch_get_main_queue(), ^(int t){
                [[NSFileManager defaultManager] removeItemAtPath:kCHDiagPath error:nil];
                CHDiag(@"log cleared");
            });
        }
    }
}
