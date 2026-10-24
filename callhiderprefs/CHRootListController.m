#import "CHRootListController.h"
#import <notify.h>
#import "../CHPrefs.h"

@implementation CHRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)resetIconPosition {
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconX, NULL,
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue((__bridge CFStringRef)kCHIconY, NULL,
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    notify_post(kCHReloadNotify);

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Icon reset"
        message:@"The red icon will return to the top-right on the next hidden call."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)flashTestIcon {
    // Asks SpringBoard to show the red icon for 5s. If it appears, the tweak is
    // injected into SpringBoard and the indicator works — independent of any call.
    notify_post(kCHTestIconNotify);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Test icon sent"
        message:@"If CallHider is active in SpringBoard, the red icon appears for ~5 seconds. If nothing shows, the tweak isn't loading into SpringBoard — check the Diagnostics page."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
