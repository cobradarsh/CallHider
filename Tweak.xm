// CallHider — hide incoming calls (cellular + VoIP) from selected contacts.
//
// iOS 16 reality: the incoming-call screen is drawn by a SEPARATE process
// (the in-call UI service), which asks SpringBoard to present it over XPC.
// SpringBoard's SBInCallPresentationManager is the delegate that receives
// "requestsPresentationWithConfiguration:completion:". Intercepting THAT is
// what actually stops the call screen and the wake — hooking the TUCall UI
// flags (v1.0) was the wrong layer, which is why calls still came through.
//
// This build also writes an on-device diagnostic log (read by the Settings
// "Diagnostics" page) so we can see, per call, exactly what the tweak sees
// and does — and a "flash test icon" trigger that proves SpringBoard
// injection independently of any phone call.

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
- (void)suppressRingtone;
- (void)setShouldSuppressRingtone:(BOOL)v;
- (void)setShouldSuppressInCallUI:(BOOL)v;
@end

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly, copy) NSArray *currentCalls;
@property (nonatomic, readonly) TUCall *incomingCall;
@property (nonatomic, readonly, copy) NSArray *incomingCalls;
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
        // cap the log so it can't grow unbounded
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

static BOOL CHBool(NSString *key, BOOL def) {
    id v = gPrefs[key]; return (v == nil) ? def : [v boolValue];
}
static CGFloat CHFloat(NSString *key, CGFloat def) {
    id v = gPrefs[key]; return (v == nil) ? def : [v doubleValue];
}
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

#pragma mark - Matching

static NSSet<NSString *> *gRevealed;    // call UUIDs the user chose to reveal

static BOOL CHMatchNumbersOrId(NSString *cid, NSString *num) {
    NSArray *hidden = gPrefs[kCHHiddenContacts];
    if (![hidden isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *e in hidden) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *eid = e[kCHEntryID];
        if (cid.length && [eid isKindOfClass:[NSString class]] && [eid isEqualToString:cid]) return YES;
        if (num.length) for (NSString *n in e[kCHEntryNumbers]) {
            if ([n isKindOfClass:[NSString class]] && n.length &&
                ([num hasSuffix:n] || [n hasSuffix:num])) return YES;
        }
    }
    return NO;
}

static BOOL CHCallHidden(TUCall *call) {
    if (!CHEnabled() || !call) return NO;
    NSString *uuid = call.callUUID;
    if (uuid && [gRevealed containsObject:uuid]) return NO;
    NSString *cid = nil, *num = nil;
    @try { cid = call.contactIdentifier; num = CHNormalizeNumber(call.handle.value); }
    @catch (__unused NSException *e) { return NO; }
    return CHMatchNumbersOrId(cid, num);
}

// Any incoming call right now that should be hidden?
static TUCall *CHActiveHiddenIncoming(void) {
    Class cc = objc_getClass("TUCallCenter");
    if (!cc) return nil;
    TUCallCenter *center = [cc sharedInstance];
    NSMutableArray *calls = [NSMutableArray array];
    @try {
        if (center.incomingCall) [calls addObject:center.incomingCall];
        if (center.incomingCalls) [calls addObjectsFromArray:center.incomingCalls];
        if (center.currentCalls)  [calls addObjectsFromArray:center.currentCalls];
    } @catch (__unused NSException *e) {}
    for (TUCall *c in calls) {
        @try { if (c.isIncoming && CHCallHidden(c)) return c; } @catch (__unused NSException *e) {}
    }
    return nil;
}

#pragma mark - Red indicator window (SpringBoard only)

@interface CHIndicatorWindow : UIWindow
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, weak)   TUCall  *call;
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
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;

    CGFloat size = CHFloat(kCHIconSize, 44);
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.frame = CGRectMake(0, 0, size, size);
    _button.backgroundColor = [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1.0];
    _button.layer.cornerRadius = size/2.0;
    _button.layer.shadowColor = UIColor.blackColor.CGColor;
    _button.layer.shadowOpacity = 0.35; _button.layer.shadowRadius = 4;
    _button.layer.shadowOffset = CGSizeMake(0, 1);
    _button.tintColor = UIColor.whiteColor;
    [_button setImage:[UIImage systemImageNamed:@"phone.fill"] forState:UIControlStateNormal];
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [_button addGestureRecognizer:pan];
    [self.rootViewController.view addSubview:_button];
    [self restorePosition];
    return self;
}

- (void)restorePosition {
    CGRect b = UIScreen.mainScreen.bounds; CGFloat size = _button.bounds.size.width;
    CGFloat x = CHFloat(kCHIconX, b.size.width - size - 12);
    CGFloat y = CHFloat(kCHIconY, 70);
    x = MAX(0, MIN(x, b.size.width - size)); y = MAX(0, MIN(y, b.size.height - size));
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
    CGPoint t = [g translationInView:self]; CGRect f = _button.frame;
    f.origin.x += t.x; f.origin.y += t.y; CGRect b = self.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, b.size.width - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, b.size.height - f.size.height));
    _button.frame = f; [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded) [self savePosition];
}
- (void)tapped {
    if (!CHTapToAnswer() || !self.call) return;
    NSString *uuid = self.call.callUUID;
    if (uuid) { NSMutableSet *s = [gRevealed mutableCopy]; [s addObject:uuid]; gRevealed = s; }
    @try { [[objc_getClass("TUCallCenter") sharedInstance] answerCall:self.call]; } @catch (__unused NSException *e) {}
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    return CGRectContainsPoint(_button.frame, point) ? [super hitTest:point withEvent:event] : nil;
}
- (void)showForCall:(TUCall *)call {
    self.call = call;
    CGFloat size = CHFloat(kCHIconSize, 44);
    [self restorePosition];
    CGRect f = _button.frame; f.size = CGSizeMake(size, size); _button.frame = f;
    _button.layer.cornerRadius = size/2.0;
    self.hidden = NO;
}
- (void)hide { self.hidden = YES; self.call = nil; }
@end

static void CHShowIcon(TUCall *call) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [[CHIndicatorWindow shared] showForCall:call]; });
}
static void CHHideIconIfDone(void) {
    if (!gIsSpringBoard) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!CHActiveHiddenIncoming()) [[CHIndicatorWindow shared] hide];
    });
}

#pragma mark - Hooks: the real iOS 16 presentation request

%group SpringBoardGroup

%hook SBInCallPresentationManager
- (void)inCallPresentationRequestServer:(id)server
                     clientWithIdentifier:(id)ident
       requestsPresentationWithConfiguration:(id)config
                               completion:(void (^)(id))completion {
    TUCall *hidden = CHActiveHiddenIncoming();
    if (hidden && CHSuppressUI()) {
        CHDiag(@"SUPPRESS presentation request for hidden call %@",
               hidden.displayName ?: hidden.handle.value);
        @try { [hidden setShouldSuppressRingtone:YES]; [hidden suppressRingtone]; } @catch (__unused NSException *e) {}
        CHShowIcon(hidden);
        if (completion) completion(nil);   // tell the client "done" without presenting
        return;
    }
    CHDiag(@"presentation request (not hidden) -> passing through");
    %orig;
}
%end

%hook SBBacklightController
- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    if (CHSuppressWake() && CHActiveHiddenIncoming()) {
        CHDiag(@"blocked screen wake (source=%lld)", source);
        return;
    }
    %orig;
}
%end

%end // SpringBoardGroup

#pragma mark - Hooks: call tracking (all processes TelephonyUtilities loads in)

%hook TUCall
- (void)_handleStatusChange {
    %orig;
    @try {
        if (!self.isIncoming) return;
        BOOL hidden = CHCallHidden(self);
        CHDiag(@"call status=%d incoming=%d voip=%d handle=%@ cid=%@ -> hidden=%d",
               self.callStatus, self.isIncoming, self.isVoIPCall,
               self.handle.value ?: @"(nil)", self.contactIdentifier ?: @"(nil)", hidden);
        if (hidden) {
            if (CHSilenceRinger()) { [self setShouldSuppressRingtone:YES]; [self suppressRingtone]; }
            if (CHSuppressUI())    { [self setShouldSuppressInCallUI:YES]; }
            CHShowIcon(self);
        }
        CHHideIconIfDone();
    } @catch (__unused NSException *e) {}
}
%end

#pragma mark - Init

%ctor {
    @autoreleasepool {
        gProc = NSProcessInfo.processInfo.processName;
        gIsSpringBoard = [gProc isEqualToString:@"SpringBoard"];
        gRevealed = [NSSet set];
        CHReload();
        CHDiag(@"CallHider v1.1.0 loaded in %@ (springboard=%d)", gProc, gIsSpringBoard);

        %init(_ungrouped);
        if (gIsSpringBoard) %init(SpringBoardGroup);

        int t1; notify_register_dispatch(kCHReloadNotify, &t1, dispatch_get_main_queue(), ^(int t){ CHReload(); });

        if (gIsSpringBoard) {
            int t2; notify_register_dispatch(kCHTestIconNotify, &t2, dispatch_get_main_queue(), ^(int t){
                CHDiag(@"test icon requested");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[CHIndicatorWindow shared] showForCall:nil];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5*NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (!CHActiveHiddenIncoming()) [[CHIndicatorWindow shared] hide];
                    });
                });
            });
            int t3; notify_register_dispatch(kCHClearLogNotify, &t3, dispatch_get_main_queue(), ^(int t){
                [[NSFileManager defaultManager] removeItemAtPath:kCHDiagPath error:nil];
                CHDiag(@"log cleared");
            });
        }
    }
}
