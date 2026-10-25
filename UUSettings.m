#import "UUSettings.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

NSString *const UUSettingsChangedNotification = @"UUHelperSettingsChanged";

static NSUserDefaults *UUPreferences(void) {
    static NSUserDefaults *prefs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ prefs = [[NSUserDefaults alloc] initWithSuiteName:@"im.mjh.uuhelper"]; });
    return prefs;
}

BOOL UUFeatureEnabled(NSString *key) {
    return [UUPreferences() boolForKey:@"enabled"] && [UUPreferences() boolForKey:key];
}

static id UUSettingsIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable([object class], name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id UUYogaLayout(UIView *view) {
    SEL selector = sel_registerName("yoga");
    return [view respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(view, selector) : nil;
}

void UUInvalidateNativeLabel(UILabel *label) {
    [label invalidateIntrinsicContentSize];
    id layout = UUYogaLayout(label);
    SEL dirty = sel_registerName("markDirty");
    // UU caches text measurements in Yoga separately from UIKit's intrinsic size.
    if ([layout respondsToSelector:dirty]) ((void (*)(id, SEL))objc_msgSend)(layout, dirty);
    [label.superview setNeedsLayout];
}

static CGFloat UUSettingsRowHeight(UITableView *table, UITableViewCell *cell) {
    id layout = UUYogaLayout(cell.contentView);
    SEL measure = sel_registerName("calculateLayoutWithSize:");
    if (CGRectGetWidth(table.bounds) > 0 && [layout respondsToSelector:measure]) {
        CGSize size = ((CGSize (*)(id, SEL, CGSize))objc_msgSend)(layout, measure,
            CGSizeMake(CGRectGetWidth(table.bounds), NAN));
        if (isfinite(size.height)) return MAX(56, ceil(size.height));
    }
    return 56;
}

// Use UU's own labels, switch, constraints and colors; no host cell model is changed.
static UITableViewCell *UUSettingsCell(UITableView *table, NSString *title, NSString *key, id target) {
    NSString *identifier = key ?: @"uuhelper.link";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        Class cls = objc_getClass("_TtC14nrd_ios_client22MineSettingsSwitchCell");
        cell = [[cls alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    UILabel *label = UUSettingsIvar(cell, "$__lazy_storage_$_titleLabel");
    UILabel *subtitle = UUSettingsIvar(cell, "$__lazy_storage_$_subTitleLabel");
    UISwitch *toggle = UUSettingsIvar(cell, "$__lazy_storage_$_switchButton");
    label.text = title;
    label.numberOfLines = 0;
    subtitle.text = nil;
    UUInvalidateNativeLabel(label);
    UUInvalidateNativeLabel(subtitle);
    toggle.hidden = !key;
    id switchLayout = UUYogaLayout(toggle);
    SEL included = sel_registerName("setIncludedInLayout:");
    if ([switchLayout respondsToSelector:included]) ((void (*)(id, SEL, BOOL))objc_msgSend)(switchLayout, included, key != nil);
    [toggle removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    if (key) {
        toggle.accessibilityIdentifier = key;
        toggle.on = [UUPreferences() boolForKey:key];
        toggle.enabled = [key isEqualToString:@"enabled"] || [UUPreferences() boolForKey:@"enabled"];
        [toggle addTarget:target action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
    }
    cell.selectionStyle = key ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.accessoryType = key ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    [cell setNeedsLayout];
    return cell;
}

@interface UUHelperSettingsController : UITableViewController
@property (nonatomic, strong) UIColor *nativeBackground;
- (void)settingChanged:(UISwitch *)sender;
@end
@implementation UUHelperSettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"uu 远控增强";
    self.tableView.backgroundColor = self.nativeBackground;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : section == 3 ? 4 : 2;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return @[@"", @"键盘与鼠标", @"画面与显示器", @"关于与支持"][section];
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"关闭总开关会保留各项选择。首次使用时，所有功能默认关闭。";
    if (section == 2) return @"快捷切屏将工具栏的“展开所有窗口”和“显示桌面”替换为显示器 1、2；缩放与位置记忆也适用于切回前台。";
    return nil;
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return UUSettingsRowHeight(table, [self tableView:table cellForRowAtIndexPath:path]);
}
- (void)tableView:(UITableView *)table willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    UIView *background = [UIView new];
    background.backgroundColor = self.nativeBackground;
    header.backgroundView = background;
}
- (void)tableView:(UITableView *)table willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    [self tableView:table willDisplayHeaderView:view forSection:section];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSArray *titles = @[@[@"启用 uu 远控增强"], @[@"常用快捷键", @"圆盘鼠标滚轮"],
        @[@"快捷切换显示器", @"记忆缩放与位置"], @[@"Junhong", @"反馈问题", @"apt.mjh.im", @"赏杯咖啡"]];
    NSArray *keys = @[@[@"enabled"], @[@"shortcuts", @"wheel"], @[@"displaySwitch", @"viewportMemory"]];
    NSString *key = path.section < 3 ? keys[path.section][path.row] : nil;
    return UUSettingsCell(table, titles[path.section][path.row], key, self);
}
- (void)settingChanged:(UISwitch *)sender {
    [UUPreferences() setBool:sender.on forKey:sender.accessibilityIdentifier];
    [NSNotificationCenter.defaultCenter postNotificationName:UUSettingsChangedNotification object:nil];
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section != 3) return;
    NSArray *links = @[@"https://mjh.im/", @"https://pingme.pm/uuhelper", @"https://apt.mjh.im/",
        @"alipays://platformapi/startapp?saId=10000007&qrcode=https%3A%2F%2Fqr.alipay.com%2Ffkx180736inoxop5mkbqh83%3F_s%3Dweb-other&launchKey=c7f8d186-3e05-4668-a7eb-8cf336c2108f-1780370320745"];
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:links[path.row]] options:@{} completionHandler:^(BOOL success) {
        if (success || path.row != 3) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开支付宝" message:@"请确认已安装支付宝。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}
@end

static IMP sSettingsSections, sSettingsRows, sSettingsCell, sSettingsHeight, sSettingsSelect;
static IMP sSettingsWillDisplay, sSettingsEndDisplay, sSettingsHeader, sSettingsFooter;
static IMP sSettingsHeaderHeight, sSettingsFooterHeight;

static NSInteger UUOriginalSettingsSections(id self, UITableView *table) {
    return ((NSInteger (*)(id, SEL, id))sSettingsSections)(self, @selector(numberOfSectionsInTableView:), table);
}
static BOOL UUIsPluginSection(id self, UITableView *table, NSInteger section) {
    return section == UUOriginalSettingsSections(self, table);
}
static NSInteger hook_settings_sections(id self, SEL cmd, UITableView *table) {
    return UUOriginalSettingsSections(self, table) + 1;
}
static NSInteger hook_settings_rows(id self, SEL cmd, UITableView *table, NSInteger section) {
    return UUIsPluginSection(self, table, section) ? 1 : ((NSInteger (*)(id, SEL, id, NSInteger))sSettingsRows)(self, cmd, table, section);
}
static id hook_settings_cell(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    return UUIsPluginSection(self, table, path.section) ? UUSettingsCell(table, @"uu 远控增强", nil, nil) : ((id (*)(id, SEL, id, id))sSettingsCell)(self, cmd, table, path);
}
static CGFloat hook_settings_height(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    return UUIsPluginSection(self, table, path.section) ? UUSettingsRowHeight(table, UUSettingsCell(table, @"uu 远控增强", nil, nil)) : ((CGFloat (*)(id, SEL, id, id))sSettingsHeight)(self, cmd, table, path);
}
static void hook_settings_select(id self, SEL cmd, UITableView *table, NSIndexPath *path) {
    if (!UUIsPluginSection(self, table, path.section)) {
        ((void (*)(id, SEL, id, id))sSettingsSelect)(self, cmd, table, path); return;
    }
    [table deselectRowAtIndexPath:path animated:YES];
    UIViewController *parent = nil;
    for (UIResponder *r = table; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) { parent = (UIViewController *)r; break; }
    }
    UUHelperSettingsController *controller = [[UUHelperSettingsController alloc] initWithStyle:table.style];
    controller.overrideUserInterfaceStyle = parent.view.traitCollection.userInterfaceStyle;
    // The host table is transparent; its enclosing settings page supplies the visible background.
    controller.nativeBackground = parent.view.backgroundColor;
    Class tableClass = objc_getClass("_TtC14nrd_ios_client13BaseTableView");
    UITableView *settingsTable = [[tableClass alloc] initWithFrame:CGRectZero style:table.style];
    settingsTable.backgroundColor = controller.nativeBackground;
    settingsTable.separatorStyle = table.separatorStyle;
    settingsTable.separatorColor = table.separatorColor;
    settingsTable.tintColor = table.tintColor;
    controller.tableView = settingsTable;
    [parent.navigationController pushViewController:controller animated:YES];
}
static void hook_settings_will_display(id self, SEL cmd, UITableView *table, id cell, NSIndexPath *path) {
    if (!UUIsPluginSection(self, table, path.section)) ((void (*)(id, SEL, id, id, id))sSettingsWillDisplay)(self, cmd, table, cell, path);
}
static void hook_settings_end_display(id self, SEL cmd, UITableView *table, id cell, NSIndexPath *path) {
    if (!UUIsPluginSection(self, table, path.section)) ((void (*)(id, SEL, id, id, id))sSettingsEndDisplay)(self, cmd, table, cell, path);
}
static id hook_settings_header(id self, SEL cmd, UITableView *table, NSInteger section) {
    return UUIsPluginSection(self, table, section) ? nil : ((id (*)(id, SEL, id, NSInteger))sSettingsHeader)(self, cmd, table, section);
}
static id hook_settings_footer(id self, SEL cmd, UITableView *table, NSInteger section) {
    return UUIsPluginSection(self, table, section) ? nil : ((id (*)(id, SEL, id, NSInteger))sSettingsFooter)(self, cmd, table, section);
}
static CGFloat hook_settings_header_height(id self, SEL cmd, UITableView *table, NSInteger section) {
    return UUIsPluginSection(self, table, section) ? 12 : ((CGFloat (*)(id, SEL, id, NSInteger))sSettingsHeaderHeight)(self, cmd, table, section);
}
static CGFloat hook_settings_footer_height(id self, SEL cmd, UITableView *table, NSInteger section) {
    return UUIsPluginSection(self, table, section) ? 0.01 : ((CGFloat (*)(id, SEL, id, NSInteger))sSettingsFooterHeight)(self, cmd, table, section);
}

void UUInstallSettings(void) {
    static BOOL installed;
    Class cls = objc_getClass("_TtC14nrd_ios_client25MineSettingTableViewModel");
    if (installed || !cls || !objc_getClass("_TtC14nrd_ios_client22MineSettingsSwitchCell")) return;
    struct { const char *selector; IMP hook; IMP *original; } hooks[] = {
        {"numberOfSectionsInTableView:", (IMP)hook_settings_sections, &sSettingsSections},
        {"tableView:numberOfRowsInSection:", (IMP)hook_settings_rows, &sSettingsRows},
        {"tableView:cellForRowAtIndexPath:", (IMP)hook_settings_cell, &sSettingsCell},
        {"tableView:heightForRowAtIndexPath:", (IMP)hook_settings_height, &sSettingsHeight},
        {"tableView:didSelectRowAtIndexPath:", (IMP)hook_settings_select, &sSettingsSelect},
        {"tableView:willDisplayCell:forRowAtIndexPath:", (IMP)hook_settings_will_display, &sSettingsWillDisplay},
        {"tableView:didEndDisplayingCell:forRowAtIndexPath:", (IMP)hook_settings_end_display, &sSettingsEndDisplay},
        {"tableView:viewForHeaderInSection:", (IMP)hook_settings_header, &sSettingsHeader},
        {"tableView:viewForFooterInSection:", (IMP)hook_settings_footer, &sSettingsFooter},
        {"tableView:heightForHeaderInSection:", (IMP)hook_settings_header_height, &sSettingsHeaderHeight},
        {"tableView:heightForFooterInSection:", (IMP)hook_settings_footer_height, &sSettingsFooterHeight},
    };
    // Check the full native table interface before adding our section.
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        if (!class_getInstanceMethod(cls, sel_registerName(hooks[i].selector))) return;
    }
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        SEL sel = sel_registerName(hooks[i].selector);
        Method method = class_getInstanceMethod(cls, sel);
        *hooks[i].original = method_getImplementation(method);
        if (!class_addMethod(cls, sel, hooks[i].hook, method_getTypeEncoding(method))) method_setImplementation(method, hooks[i].hook);
    }
    installed = YES;
}
