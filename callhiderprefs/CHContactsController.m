#import "CHContactsController.h"
#import <Contacts/Contacts.h>
#import <notify.h>
#import "../CHPrefs.h"

@implementation CHContactsController {
    UITableView *_table;
    NSMutableArray<NSDictionary *> *_entries;
}

#pragma mark - Storage

- (void)loadEntries {
    NSArray *a = (__bridge_transfer NSArray *)CFPreferencesCopyValue(
        (__bridge CFStringRef)kCHHiddenContacts, (__bridge CFStringRef)kCHAppID,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    _entries = [a isKindOfClass:[NSArray class]] ? [a mutableCopy] : [NSMutableArray array];
}

- (void)saveEntries {
    CFPreferencesSetValue((__bridge CFStringRef)kCHHiddenContacts, (__bridge CFArrayRef)_entries,
        (__bridge CFStringRef)kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCHAppID);
    notify_post(kCHReloadNotify);
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hidden callers";
    [self loadEntries];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(addTapped)];
    // Edit toggles delete controls on each row; tapping Done saves the result.
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
}

// editButtonItem calls this; drive the table's editing mode so per-row delete
// controls (the red minus) appear, letting individual contacts be removed.
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [_table setEditing:editing animated:animated];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadEntries];
    [_table reloadData];
}

#pragma mark - Add via contact picker

- (void)addTapped {
    CNContactPickerViewController *picker = [[CNContactPickerViewController alloc] init];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)contactPicker:(CNContactPickerViewController *)picker didSelectContact:(CNContact *)contact {
    NSMutableArray *numbers = [NSMutableArray array];
    if ([contact isKeyAvailable:CNContactPhoneNumbersKey]) {
        for (CNLabeledValue<CNPhoneNumber *> *lv in contact.phoneNumbers) {
            NSString *norm = CHNormalizeNumber(lv.value.stringValue);
            if (norm.length) [numbers addObject:norm];
        }
    }
    NSString *name = @"";
    if ([contact isKeyAvailable:CNContactGivenNameKey])
        name = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @"";
    if (name.length == 0) name = numbers.firstObject ?: @"Contact";

    // Avoid duplicates by identifier.
    for (NSDictionary *e in _entries) {
        if ([e[kCHEntryID] isEqualToString:contact.identifier]) return;
    }
    [_entries addObject:@{ kCHEntryID: contact.identifier ?: @"",
                           kCHEntryName: name,
                           kCHEntryNumbers: numbers }];
    [self saveEntries];
    [_table reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _entries.count; }

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return _entries.count ? @"Swipe a row to remove it. Both the contact and its saved numbers are matched, so VoIP calls are caught too." : @"Tap + to add a contact to hide.";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *e = _entries[ip.row];
    c.textLabel.text = e[kCHEntryName];
    NSArray *nums = e[kCHEntryNumbers];
    c.detailTextLabel.text = nums.count ? [NSString stringWithFormat:@"%lu number(s) matched", (unsigned long)nums.count]
                                        : @"matched by contact only";
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}

- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style
                                forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) {
        [_entries removeObjectAtIndex:ip.row];
        [self saveEntries];
        [t deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        [t reloadData];
    }
}

@end
