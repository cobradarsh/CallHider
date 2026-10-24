#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <ContactsUI/ContactsUI.h>

@interface CHContactsController : PSViewController <UITableViewDataSource, UITableViewDelegate, CNContactPickerDelegate>
@end
