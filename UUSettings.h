#import <UIKit/UIKit.h>

extern NSString *const UUSettingsChangedNotification;
extern BOOL UUFeatureEnabled(NSString *key);
extern void UUInstallSettings(void);
extern void UUInvalidateNativeLabel(UILabel *label);
