#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>

// Lists every hidden call CallHider recorded (name/number + time), newest first.
@interface CHCallLogController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end
