// CallHider — silently hide calls (cellular + VoIP) from selected contacts.
//
// Strategy (all based on public-dump iOS 16 TelephonyUtilities API):
//   * TUCall drives BOTH cellular and VoIP/CallKit calls (-isVoIPCall), and
//     SpringBoard reads -shouldSuppressInCallUI to decide whether to present
//     the banner / full-screen UI. Overriding it for hidden callers is the
//     system's own, version-robust way to hide the call UI (and the wake that
//     comes with presenting it).
//   * -shouldSuppressRingtone / -suppressRingtone mute the ringtone+vibration.
//   * A tightly-scoped SBBacklightController guard blocks the call-initiated
//     screen wake *only while a hidden call is actively ringing*.
//   * A high-level, draggable red phone window is the sole indicator.
//
// Matching is by CNContact identifier (TUCall.contactIdentifier) with a
// fallback to the normalized phone number (TUCall.handle.value), so VoIP calls
// that don't carry a contact id still match a saved contact's number.

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import "CHPrefs.h"

#pragma mark - Private interfaces (from iOS 16 runtime headers)

@interface TUHandle : NSObject
@property (nonatomic, readonly, copy) NSString *value;
@property (nonatomic, readonly, copy) NSString *normalizedValue;
@end

@interface TUCall : NSObject
@property (nonatomic, readonly) int callStatus;
@property (getter=isIncoming, nonatomic, readonly) BOOL incoming;
@property (getter=isVoIPCall, nonatomic, readonly) BOOL voipCall;
@property (nonatomic, readonly) TUHandle *handle;
@property (nonatomic, readonly, copy) NSString *contactIdentifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *callUUID;
@property (nonatomic, readonly) BOOL shouldSuppressInCallUI;
@property (nonatomic) BOOL shouldSuppressRingtone;
- (void)suppressRingtone;
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

static BOOL      gIsSpringBoard = NO;
static NSDictionary *gPrefs = nil;          // snapshot of CFPreferences
static NSMutableSet<NSString *> *gRevealed; // call UUIDs the user chose to reveal

#pragma mark - Preferences

static BOOL CHBool(NSString *key, BOOL def) {
    id v = gPrefs[key];
    return (v == nil) ? def : [v boolValue];
}
static CGFloat CHFloat(NSString *key, CGFloat def) {
    id v = gPrefs[key];
    return (v == nil) ? def : [v doubleValue];
}
#define CHEnabled()       CHBool(kCHEnabled, YES)
#define CHSilenceRinger() CHBool(kCHSilenceRinger, YES)
#define CHSuppressWake()  CHBool(kCHSuppressWake, YES)
#define CHSuppressUI()    CHBool(kCHSuppressUI, YES)
#define CHTapToAnswer()   CHBool(kCHTapToAnswer, NO)
#define CHDebug()         CHBool(kCHDebugLog, NO)

static void CHLog(NSString *fmt, ...) {
    if (!CHDebug()) return;
    va_list args; va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[CallHider] %@", s);
}

static void CHReload(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    NSArray *keys = @[kCHEnabled, kCHSilenceRinger, kCHSuppressWake, kCHSuppressUI,
                      kCHTapToAnswer, kCHDebugLog, kCHIconX, kCHIconY, kCHIconSize,
                      kCHHiddenContacts];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        id v = (__bridge_transfer id)CFPreferencesCopyValue(
            (__bridge CFStringRef)k, (__bridge CFStringRef)kCHAppID,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) d[k] = v;
    }
    gPrefs = [d copy];
    CHLog(@"prefs reloaded (%lu hidden)", (unsigned long)[gPrefs[kCHHiddenContacts] count]);
}

#pragma mark - Matching

static BOOL CHIsHiddenCall(TUCall *call) {
    if (![call isKindOfClass:objc_getClass("TUCall")] && ![call respondsToSelector:@selector(handle)])
        return NO;
    NSArray *hidden = gPrefs[kCHHiddenContacts];
    if (![hidden isKindOfClass:[NSArray class]] || hidden.count == 0) return NO;

    NSString *cid = nil, *num = nil;
    @try {
        cid = call.contactIdentifier;
        num = CHNormalizeNumber(call.handle.value);
    } @catch (__unused NSException *e) { return NO; }

    for (NSDictionary *entry in hidden) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *eid = entry[kCHEntryID];
        if (cid.length && [eid isKindOfClass:[NSString class]] && [eid isEqualToString:cid])
            return YES;
        if (num.length) {
            for (NSString *n in entry[kCHEntryNumbers]) {
                if ([n isKindOfClass:[NSString class]] && [n length] && [num hasSuffix:n])
                    return YES;
                if ([n isKindOfClass:[NSString class]] && [n length] && [n hasSuffix:num])
                    return YES;
            }
        }
    }
    return NO;
}

static BOOL CHShouldHideUI(TUCall *call) {
    if (!CHEnabled()) return NO;
    NSString *uuid = call.callUUID;
    if (uuid && [gRevealed containsObject:uuid]) return NO; // user revealed this call
    return CHIsHiddenCall(call);
}

// Is a hidden incoming call ringing right now? (Used to scope the wake guard.)
static BOOL CHHasRingingHiddenCall(void) {
    if (!CHEnabled() || !gIsSpringBoard) return NO;
    TUCallCenter *cc = [objc_getClass("TUCallCenter") sharedInstance];
    for (TUCall *c in cc.currentCalls) {
        @try {
            if (c.isIncoming && CHShouldHideUI(c)) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

#pragma mark - Red indicator window (SpringBoard only)

@interface CHIndicatorWindow : UIWindow
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, weak)   TUCall  *call;
@end

@implementation CHIndicatorWindow

+ (instancetype)shared {
    static CHIndicatorWindow *w = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [[CHIndicatorWindow alloc] init]; });
    return w;
}

- (instancetype)init {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    }
    if (scene) self = [super initWithWindowScene:scene];
    else       self = [super initWithFrame:UIScreen.mainScreen.bounds];
    if (!self) return nil;

    self.windowLevel = UIWindowLevelAlert + 2000;
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;

    CGFloat size = CHFloat(kCHIconSize, 44);
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = CGRectMake(0, 0, size, size);
    _button.backgroundColor = [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1.0];
    _button.layer.cornerRadius = size / 2.0;
    _button.layer.shadowColor = UIColor.blackColor.CGColor;
    _button.layer.shadowOpacity = 0.35;
    _button.layer.shadowRadius = 4;
    _button.layer.shadowOffset = CGSizeMake(0, 1);
    _button.tintColor = UIColor.whiteColor;
    UIImage *glyph = [UIImage systemImageNamed:@"phone.fill"];
    [_button setImage:glyph forState:UIControlStateNormal];
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [_button addGestureRecognizer:pan];
    [self.rootViewController.view addSubview:_button];

    [self restorePosition];
    return self;
}

- (void)restorePosition {
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat size = _button.bounds.size.width;
    CGFloat defX = b.size.width - size - 12;       // top-right by default
    CGFloat defY = 70;
    CGFloat x = CHFloat(kCHIconX, defX);
    CGFloat y = CHFloat(kCHIconY, defY);
    x = MAX(0, MIN(x, b.size.width  - size));
    y = MAX(0, MIN(y, b.size.height - size));
    _button.frame = CGRectMake(x, y, size, size);
}

- (void)savePosition {
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconX, (__bridge CFNumberRef)@(_button.frame.origin.x),
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconY, (__bridge CFNumberRef)@(_button.frame.origin.y),
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
}

- (void)panned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGRect f = _button.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    CGRect b = self.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, b.size.width  - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, b.size.height - f.size.height));
    _button.frame = f;
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) [self savePosition];
}

- (void)tapped {
    if (!CHTapToAnswer() || !self.call) return;
    NSString *uuid = self.call.callUUID;
    if (uuid) [gRevealed addObject:uuid];      // stop suppressing -> real UI appears
    @try { [[objc_getClass("TUCallCenter") sharedInstance] answerCall:self.call]; }
    @catch (__unused NSException *e) {}
}

// Only the icon itself is interactive; everything else passes through.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    if (CGRectContainsPoint(_button.frame, point)) return [super hitTest:point withEvent:event];
    return nil;
}

- (void)showForCall:(TUCall *)call {
    self.call = call;
    [self restorePosition];
    CGFloat size = CHFloat(kCHIconSize, 44);
    CGRect f = _button.frame; f.size = CGSizeMake(size, size);
    _button.frame = f; _button.layer.cornerRadius = size / 2.0;
    self.hidden = NO;
}

- (void)hide { self.hidden = YES; self.call = nil; }

@end

#pragma mark - Call lifecycle

static NSString *gActiveHiddenUUID = nil;

static void CHUpdateForCall(TUCall *call) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        TUCallCenter *cc = [objc_getClass("TUCallCenter") sharedInstance];
        BOOL present = [cc.currentCalls containsObject:call];
        NSString *uuid = call.callUUID;
        BOOL hide = present && call.isIncoming && CHShouldHideUI(call);

        if (hide) {
            if (CHSilenceRinger()) {
                @try { call.shouldSuppressRingtone = YES; [call suppressRingtone]; }
                @catch (__unused NSException *e) {}
            }
            gActiveHiddenUUID = uuid;
            [[CHIndicatorWindow shared] showForCall:call];
            CHLog(@"hiding call %@ (voip=%d)", call.displayName ?: call.handle.value, call.isVoIPCall);
        }
        // Tear down once the hidden call we were tracking leaves the call list.
        if (gActiveHiddenUUID && [gActiveHiddenUUID isEqualToString:uuid] && !present) {
            [[CHIndicatorWindow shared] hide];
            if (uuid) [gRevealed removeObject:uuid];
            gActiveHiddenUUID = nil;
            CHLog(@"hidden call ended");
        }
    });
}

#pragma mark - Hooks

%hook TUCall

- (BOOL)shouldSuppressInCallUI {
    if (CHSuppressUI() && CHShouldHideUI(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressRingtone {
    if (CHSilenceRinger() && CHShouldHideUI(self)) return YES;
    return %orig;
}

- (void)_handleStatusChange {
    %orig;
    @try {
        if (self.isIncoming) CHUpdateForCall(self);
    } @catch (__unused NSException *e) {}
}

%end

%hook SBBacklightController

- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    if (CHSuppressWake() && CHHasRingingHiddenCall()) {
        CHLog(@"blocked screen wake (source=%lld) for hidden ringing call", source);
        return;
    }
    %orig;
}

%end

#pragma mark - Init

%ctor {
    @autoreleasepool {
        gIsSpringBoard = [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
        gRevealed = [NSMutableSet set];
        CHReload();
        int token;
        notify_register_dispatch(kCHReloadNotify, &token, dispatch_get_main_queue(),
                                 ^(int t){ CHReload(); });
        CHLog(@"loaded in %@", NSProcessInfo.processInfo.processName);
    }
}
