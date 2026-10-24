// CHPrefs.h — shared preference keys and defaults for CallHider.
#import <Foundation/Foundation.h>

#define kCHAppID            @"com.cobradarsh.callhider"
#define kCHReloadNotify     "com.cobradarsh.callhider/reload"
#define kCHTestIconNotify   "com.cobradarsh.callhider/testicon"
#define kCHClearLogNotify   "com.cobradarsh.callhider/clearlog"

// On-device diagnostics, written by the tweak (SpringBoard) and read by the
// Settings bundle. /var/mobile is shared between both processes.
#define kCHDiagDir          @"/var/mobile/Library/CallHider"
#define kCHDiagPath         @"/var/mobile/Library/CallHider/diag.log"

// Behaviour
#define kCHEnabled          @"enabled"          // master on/off           (default YES)
#define kCHSilenceRinger    @"silenceRinger"    // mute ringtone+vibration (default YES)
#define kCHSuppressWake     @"suppressWake"     // keep screen from waking  (default YES)
#define kCHSuppressUI       @"suppressUI"       // no banner / no full UI    (default YES)
#define kCHTapToAnswer      @"tapToAnswer"      // tap red icon answers call (default NO)
#define kCHDebugLog         @"debugLog"         //                           (default NO)

// Indicator
#define kCHIconX            @"iconX"            // CGFloat, screen point
#define kCHIconY            @"iconY"
#define kCHIconSize         @"iconSize"         // CGFloat diameter (default 44)

// Hidden callers: array of dictionaries, each:
//   { "id": <CNContact identifier>, "name": <display>, "numbers": [<normalized digit strings>] }
#define kCHHiddenContacts   @"hiddenContacts"
#define kCHEntryID          @"id"
#define kCHEntryName        @"name"
#define kCHEntryNumbers     @"numbers"

// Normalize a phone/handle value to a comparable digit string (keeps the last
// 10 digits so country-code / formatting differences still match).
static inline NSString *CHNormalizeNumber(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return nil;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (digits.length == 0) return nil;              // e.g. a FaceTime email handle
    if (digits.length > 10) return [digits substringFromIndex:digits.length - 10];
    return digits;
}
