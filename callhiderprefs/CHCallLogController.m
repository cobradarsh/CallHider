#import "CHCallLogController.h"
#import <notify.h>
#import "../CHPrefs.h"

@implementation CHCallLogController {
    UITableView *_table;
    NSArray<NSDictionary *> *_entries;   // newest first
    NSDateFormatter *_fmt;
}

- (void)loadEntries {
    NSArray *a = (__bridge_transfer NSArray *)CFPreferencesCopyValue(
        (__bridge CFStringRef)kCHCallLog, (__bridge CFStringRef)kCHAppID,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSArray *log = [a isKindOfClass:[NSArray class]] ? a : @[];
    _entries = [[log reverseObjectEnumerator] allObjects];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden call log";
    _fmt = [NSDateFormatter new];
    _fmt.dateStyle = NSDateFormatterMediumStyle;
    _fmt.timeStyle = NSDateFormatterShortStyle;

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                      target:self action:@selector(clearTapped)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadEntries];
    [_table reloadData];
}

- (void)clearTapped {
    UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Clear hidden call log?"
        message:@"This removes the list of recorded hidden calls and the red indicator."
        preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        CFPreferencesSetValue((__bridge CFStringRef)kCHCallLog, (__bridge CFArrayRef)@[],
            (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue((__bridge CFStringRef)kCHMissedCount, (__bridge CFNumberRef)@(0),
            (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
        notify_post(kCHClearMissedNotify);
        [self loadEntries];
        [self->_table reloadData];
    }]];
    [self presentViewController:c animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _entries.count; }

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return _entries.count
        ? [NSString stringWithFormat:@"%lu hidden call%@ recorded. These never appeared in Phone Recents or on the lock screen.",
           (unsigned long)_entries.count, _entries.count == 1 ? @"" : @"s"]
        : @"No hidden calls recorded yet.";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"l"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"l"];
    NSDictionary *e = _entries[ip.row];
    NSString *name = e[kCHLogName], *num = e[kCHLogNumber];
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:[e[kCHLogDate] doubleValue]];
    c.textLabel.text = name.length ? name : (num.length ? num : @"Unknown");
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@",
        (name.length && num.length) ? num : @"",
        (name.length && num.length) ? @"  ·  " : @"",
        [_fmt stringFromDate:when]];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

@end
