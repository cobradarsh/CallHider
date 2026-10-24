#import "CHDiagController.h"
#import <notify.h>
#import "../CHPrefs.h"

@implementation CHDiagController {
    UITextView *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";

    _text = [[UITextView alloc] initWithFrame:self.view.bounds];
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _text.editable = NO;
    _text.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _text.alwaysBounceVertical = YES;
    [self.view addSubview:_text];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash   target:self action:@selector(clear)],
    ];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }

- (void)reload {
    NSString *log = [NSString stringWithContentsOfFile:kCHDiagPath encoding:NSUTF8StringEncoding error:nil];
    if (log.length == 0) {
        log = @"(no diagnostics yet)\n\n"
              @"What to do:\n"
              @"1. Tap “Flash test icon” on the previous screen.\n"
              @"   • If the red icon appears → the tweak IS loaded in SpringBoard.\n"
              @"   • If not, and this page stays empty → it is NOT loading; respring,\n"
              @"     and confirm the package is installed.\n"
              @"2. Have a hidden contact call you, then come back and Refresh.\n"
              @"   Each incoming call should add a “call status … hidden=1” line.";
    }
    _text.text = log;
    // scroll to bottom
    if (_text.text.length > 1)
        [_text scrollRangeToVisible:NSMakeRange(_text.text.length - 1, 1)];
}

- (void)clear {
    [[NSFileManager defaultManager] removeItemAtPath:kCHDiagPath error:nil];
    notify_post(kCHClearLogNotify);
    [self reload];
}

@end
