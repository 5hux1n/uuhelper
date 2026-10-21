#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <math.h>

extern void uuss_call_key_sink(void *fn, void *sink, void *array, uint8_t action, void *type, void *wtable);
extern void uuss_call_swift_geometry(void *fn, void *swiftSelf, double a, double b);

#define UULog(fmt, ...) NSLog(@"[uuhelper] " fmt, ##__VA_ARGS__)

static const char *kClsViewModel  = "_TtC14nrd_ios_client21ControlPanelViewModel";
static const char *kClsCombineKey = "_TtC14nrd_ios_client24CombineKeyViewController";
static const char *kClsMouse      = "_TtC14nrd_ios_client9MouseView";
static const char *kClsKeyButton  = "_TtC14nrd_ios_client18FullKeyboardButton";
static const char *kClsMenuItem   = "_TtC14nrd_ios_client23MultiScreenMenuItemView";

static char kAssocShortcutIndex;     // NSNumber: 新增组合键行的序号
static char kAssocShortcutTemplate;  // UIView: 对应的原始符号键（只读取平台）
static char kAssocShortcutTarget;    // UUShortcutTarget
static char kAssocShortcutRow;       // UIView: 新增组合键行
static char kAssocOriginalFrames;    // NSMapTable: 本轮布局修改前的原始 frame
static char kAssocWheelState;        // UUWheelState: 虚拟鼠标滚轮转盘状态
static char kAssocWheelArtworkMask;  // UUWheelArtworkMask: 可恢复的原始绘制遮罩
static char kAssocWheelDial;         // UUWheelDialView: 双层圆圈底盘
static char kAssocMenuTapHooked;     // NSNumber: 多显示屏菜单卡片手势添加标记

static inline SEL kUUAssocViewportMemory(void) {
    return sel_registerName("uu_assoc_viewport_memory");
}

static inline SEL kUUViewportEngineActive(void) {
    return sel_registerName("uu_viewport_engine_active");
}

static IMP sOrigCkLayout        = NULL;
static IMP sOrigCkDidLayout     = NULL;
static IMP sOrigMouseLayout     = NULL;
static IMP sOrigMousePress      = NULL;
static IMP sOrigMouseRelease    = NULL;
static IMP sOrigWheel           = NULL;
static IMP sOrigMenuItemLayout  = NULL;
static IMP sOrigContentLayout   = NULL;
static IMP sOrigRenderTransform = NULL;

// ---- Helpers -----------------------------------------------------------------

static intptr_t UUMainImageSlide(void) {
    static intptr_t slide = 0;
    static BOOL resolved = NO;
    if (resolved) return slide;
    resolved = YES;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len >= 15 && strcmp(name + len - 15, "/nrd-ios-client") == 0) {
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    return slide;
}

static BOOL UUIsSupportedAppVersion(void) {
    return YES;
}

static BOOL UUIsMainImagePointer(void *ptr) {
    if (!ptr) return NO;
    Dl_info info;
    if (!dladdr(ptr, &info) || !info.dli_fname) return NO;
    size_t len = strlen(info.dli_fname);
    return len >= 15 && strcmp(info.dli_fname + len - 15, "/nrd-ios-client") == 0;
}

static BOOL UUCodeStartsWith(void *fn, uint32_t insn) {
    return fn && *(const uint32_t *)fn == insn;
}

static void UUSwiftRelease(void *object) {
    if (!object) return;
    static void (*release)(void *);
    static BOOL resolved;
    if (!resolved) {
        resolved = YES;
        release = (void (*)(void *))dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
    }
    if (release) release(object);
}

static id UUObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static BOOL UURawIvar(id obj, const char *name, void *out, size_t size) {
    if (!obj || !out || size == 0) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    ptrdiff_t offset = ivar_getOffset(iv);
    if (offset < 0 || (size_t)offset + size > class_getInstanceSize(object_getClass(obj))) return NO;
    memcpy(out, (const uint8_t *)(__bridge void *)obj + offset, size);
    return YES;
}

static UILabel *UUFirstLabel(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    for (UIView *sub in v.subviews) {
        UILabel *l = UUFirstLabel(sub);
        if (l) return l;
    }
    return nil;
}

static id UUViewModelFromVC(UIViewController *vc, Class vmCls) {
    id vm = UUObjectIvar(vc, "viewModel");
    return (vm && [vm isKindOfClass:vmCls]) ? vm : nil;
}

static id UUSearchVCTree(UIViewController *vc, Class vmCls, int depth) {
    if (!vc || depth > 12) return nil;
    id vm = UUViewModelFromVC(vc, vmCls);
    if (vm) return vm;
    for (UIViewController *child in vc.childViewControllers) {
        vm = UUSearchVCTree(child, vmCls, depth + 1);
        if (vm) return vm;
    }
    return UUSearchVCTree(vc.presentedViewController, vmCls, depth + 1);
}

static id UUFindViewModel(UIView *from) {
    Class vmCls = objc_getClass(kClsViewModel);
    if (!vmCls) return nil;
    id cvc = UUObjectIvar(from, "contentViewController");
    if ([cvc isKindOfClass:[UIViewController class]]) {
        id vm = UUViewModelFromVC((UIViewController *)cvc, vmCls);
        if (vm) return vm;
    }
    for (UIResponder *r = from; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            id vm = UUViewModelFromVC((UIViewController *)r, vmCls);
            if (vm) return vm;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            id vm = UUSearchVCTree(w.rootViewController, vmCls, 0);
            if (vm) return vm;
        }
    }
    return nil;
}

static int32_t UUScreenID(id screen) {
    if (!screen) return -1;
    SEL sel = sel_registerName("screen_id");
    if ([screen respondsToSelector:sel]) {
        return ((int32_t (*)(id, SEL))(void *)objc_msgSend)(screen, sel);
    }
    int32_t raw = -1;
    if (UURawIvar(screen, "screen_id", &raw, sizeof(raw)) && raw >= 0) return raw;
    return -1;
}

// ---- Viewport Memory & Position Fix ------------------------------------------

@interface UUViewportSnapshot : NSObject
@property (nonatomic) double zoom;
@property (nonatomic) CGPoint offset;
@property (nonatomic) CGSize frameSize;
@end
@implementation UUViewportSnapshot
@end

static BOOL UUReadViewport(UIView *view, UUViewportSnapshot *snapshot) {
    Ivar temp = class_getInstanceVariable(view.class, "_tempZoomScale");
    Ivar min = class_getInstanceVariable(view.class, "minimumZoomScale");
    Ivar content = class_getInstanceVariable(view.class, "_contentSize");
    if (!temp || !min || !content) return NO;
    ptrdiff_t offset = ivar_getOffset(temp);
    if (ivar_getOffset(min) != offset + 16 || ivar_getOffset(content) != offset + 32) return NO;
    if (offset < 0 || (size_t)offset + 16 > class_getInstanceSize(view.class)) return NO;
    double zoom;
    memcpy(&zoom, (uint8_t *)(__bridge void *)view + offset + 8, sizeof(double));
    snapshot.zoom = zoom;
    CGPoint position;
    CGSize frame;
    if (!UURawIvar(view, "_contentOffset", &position, sizeof(position)) ||
        !UURawIvar(view, "videoFrameSize", &frame, sizeof(frame))) return NO;
    snapshot.offset = position;
    snapshot.frameSize = frame;
    return isfinite(snapshot.zoom) && snapshot.zoom > 0.001 && snapshot.zoom < 128 &&
        isfinite(position.x) && isfinite(position.y) && fabs(position.x) < 1e7 && fabs(position.y) < 1e7 &&
        isfinite(frame.width) && isfinite(frame.height) && frame.width > 0 && frame.height > 0;
}

static int32_t UUViewportCurrentScreenID(id session) {
    int32_t sid = UUScreenID(UUObjectIvar(session, "$__lazy_storage_$_currentScreenInfo"));
    if (sid >= 0) return sid;
    uint8_t optional[5] = {0, 0, 0, 0, 1};
    if (UURawIvar(session, "currentScreenID", optional, sizeof(optional)) && !(optional[4] & 1)) {
        memcpy(&sid, optional, sizeof(sid));
        if (sid >= 0) return sid;
    }
    uintptr_t raw = 0;
    if (UURawIvar(session, "screenInfos", &raw, sizeof(raw)) && raw && !(raw & 0xC000000000000001ULL)) {
        NSInteger count = *(NSInteger *)(raw + 0x10);
        if (count > 0 && count <= 16) return UUScreenID((__bridge id)(*(void **)(raw + 0x20)));
    }
    return -1;
}

static BOOL UUViewportFunctions(void **zoom, void **offset) {
    if (!UUIsSupportedAppVersion()) return NO;
    intptr_t slide = UUMainImageSlide();
    if (!slide) return NO;
    *zoom = (void *)(slide + 0x100849440);
    *offset = (void *)(slide + 0x10084b0dc);
    return UUIsMainImagePointer(*zoom) && UUIsMainImagePointer(*offset) &&
        memcmp(*zoom, (const uint32_t[]){0x6dbe23e9u, 0xa9017bfdu, 0x910043fdu, 0xb0010b68u}, 16) == 0 &&
        memcmp(*offset, (const uint32_t[]){0x6db923e9u, 0xa9016ffcu, 0xa90267fau, 0xa9035ff8u}, 16) == 0;
}

static BOOL UUApplyViewport(UIView *view, UUViewportSnapshot *saved) {
    void *zoomFn = NULL, *offsetFn = NULL;
    if (!UUViewportFunctions(&zoomFn, &offsetFn)) return NO;
    UUViewportSnapshot *current = [UUViewportSnapshot new];
    if (!UUReadViewport(view, current)) return NO;
    CGPoint point = saved.offset;
    point.x *= current.frameSize.width / saved.frameSize.width;
    point.y *= current.frameSize.height / saved.frameSize.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        uuss_call_swift_geometry(zoomFn, (__bridge void *)view, saved.zoom, 0);
        uuss_call_swift_geometry(offsetFn, (__bridge void *)view, point.x, point.y);
    }];
    [CATransaction commit];
    return YES;
}

typedef void (*UURenderTransformFn)(id, SEL, id, uint64_t, float, float, float, float, float, float);
static const char *kRenderTransformSelector = "setTransformFor:forHandel:scale_x:scale_y:trans_x:trans_y:pivot_x:pivot_y:";

@interface UUDeferredRenderTransform : NSObject
@property (nonatomic, weak) id manager;
@property (nonatomic, weak) id renderView;
@property (nonatomic) uint64_t handle;
@property (nonatomic) float sx, sy, tx, ty, px, py;
@end
@implementation UUDeferredRenderTransform
@end

static void UUForwardRenderTransform(UUDeferredRenderTransform *packet) {
    id manager = packet.manager, view = packet.renderView;
    if (manager && view && sOrigRenderTransform) {
        ((UURenderTransformFn)sOrigRenderTransform)(manager, sel_registerName(kRenderTransformSelector), view,
            packet.handle, packet.sx, packet.sy, packet.tx, packet.ty, packet.px, packet.py);
    }
}

@class UUViewportMemory;
static void UURefreshViewportBindings(UUViewportMemory *memory);

@interface UUViewportMemory : NSObject
@property (nonatomic, weak) id session;
@property (nonatomic, weak) id viewModel;
@property (nonatomic, weak) UIView *content;
@property (nonatomic, weak) id renderView;
@property (nonatomic, strong) UUDeferredRenderTransform *deferredTransform;
@property (nonatomic, strong) UUDeferredRenderTransform *lastRenderTransform;
@property (nonatomic) NSUInteger renderSerial;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UUViewportSnapshot *> *screens;
@property (nonatomic, strong) UUViewportSnapshot *pending;
@property (nonatomic, strong) UUViewportSnapshot *lastApplied;
@property (nonatomic, strong) UUViewportSnapshot *source;
@property (nonatomic, strong) UUViewportSnapshot *lastDesired;
@property (nonatomic) int32_t sourceID;
@property (nonatomic) CFRunLoopObserverRef observer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int32_t targetID;
@property (nonatomic) CFTimeInterval started;
@property (nonatomic) BOOL applying;
- (void)stop;
- (void)start;
- (void)willResign:(NSNotification *)note;
- (void)didBecomeActive:(NSNotification *)note;
- (void)tick:(NSTimer *)timer;
@end

@implementation UUViewportMemory
- (instancetype)init {
    if ((self = [super init])) {
        _screens = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willResign:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    if (_observer) {
        CFRunLoopObserverInvalidate(_observer);
        CFRelease(_observer);
        _observer = NULL;
    }
    self.pending = nil;
    self.lastApplied = nil;
    self.source = nil;
    self.lastDesired = nil;
    self.deferredTransform = nil;
    self.lastRenderTransform = nil;
}
- (void)start {
    __weak UUViewportMemory *weakMemory = self;
    _observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
        kCFRunLoopBeforeWaiting | kCFRunLoopExit, YES, -1000, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            [weakMemory tick:nil];
        });
    if (_observer) CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    self.timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        UUViewportMemory *memory = weakMemory;
        if (memory) [memory tick:timer]; else [timer invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)willResign:(NSNotification *)note {
    UURefreshViewportBindings(self);
    UUViewportSnapshot *snapshot = [UUViewportSnapshot new];
    int32_t sid = UUViewportCurrentScreenID(self.session);
    if (sid >= 0 && (!self.pending || self.lastApplied) && UUReadViewport(self.content, snapshot)) {
        self.screens[@(sid)] = snapshot;
    }
    [self stop];
}
- (void)didBecomeActive:(NSNotification *)note {
    id vm = UUFindViewModel(nil);
    if (UUObjectIvar(vm, "session") == self.session) self.viewModel = vm;
    UURefreshViewportBindings(self);
    int32_t sid = UUViewportCurrentScreenID(self.session);
    UUViewportSnapshot *saved = self.screens[@(sid)];
    [self stop];
    if (!saved || !self.content || !self.session) return;
    self.pending = self.source = saved;
    self.targetID = self.sourceID = sid;
    self.started = CACurrentMediaTime();
    [self start];
    [self tick:nil];
}
- (void)tick:(NSTimer *)timer {
    if (self.applying || !self.pending) return;
    UURefreshViewportBindings(self);
    UIView *view = self.content;
    id session = self.session;
    CFTimeInterval now = CACurrentMediaTime();
    if (!session || now - self.started > 3.0 ||
        objc_getAssociatedObject(view, kUUAssocViewportMemory()) != self) { [self stop]; return; }
    if (!view.window) return;
    int32_t currentID = UUViewportCurrentScreenID(session);
    if (currentID != self.targetID && currentID != self.sourceID) { [self stop]; return; }
    UUViewportSnapshot *desired = currentID == self.targetID ? self.pending : self.source;
    if (!desired) return;
    BOOL touching = NO, zooming = NO;
    UURawIvar(view, "isTouching", &touching, 1);
    UURawIvar(view, "isZooming", &zooming, 1);
    if (touching || zooming) { [self stop]; return; }
    UUViewportSnapshot *current = [UUViewportSnapshot new];
    if (!UUReadViewport(view, current)) return;
    UUViewportSnapshot *last = self.lastApplied;
    BOOL changed = !last || self.lastDesired != desired || fabs(current.zoom - last.zoom) > 0.0001 ||
        fabs(current.offset.x - last.offset.x) > 0.25 || fabs(current.offset.y - last.offset.y) > 0.25 ||
        !CGSizeEqualToSize(current.frameSize, last.frameSize);
    if (changed) {
        self.applying = YES;
        self.deferredTransform = nil;
        BOOL ok = UUApplyViewport(view, desired);
        UUDeferredRenderTransform *finalTransform = self.deferredTransform;
        self.deferredTransform = nil;
        if (ok && finalTransform) {
            self.lastRenderTransform = finalTransform;
            self.renderSerial++;
            UUForwardRenderTransform(finalTransform);
        }
        self.applying = NO;
        if (!ok) { [self stop]; return; }
        UUViewportSnapshot *applied = [UUViewportSnapshot new];
        if (UUReadViewport(view, applied)) {
            self.lastApplied = applied;
            self.lastDesired = desired;
        }
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_timer invalidate];
    if (_observer) { CFRunLoopObserverInvalidate(_observer); CFRelease(_observer); }
}
@end

static void UURefreshViewportBindings(UUViewportMemory *memory) {
    UIViewController *vc = UUObjectIvar(memory.viewModel, "contentViewController");
    if ([vc isKindOfClass:UIViewController.class]) {
        UIView *content = UUObjectIvar(vc, "$__lazy_storage_$_remoteContentView");
        if ([content isKindOfClass:objc_getClass("_TtC14nrd_ios_client17RemoteContentView")]) memory.content = content;
    }
    if (memory.content) objc_setAssociatedObject(memory.content, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Ivar iv = class_getInstanceVariable(object_getClass(memory.session), "videoRenderView");
    void *(*loadWeak)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_unknownObjectRelease");
    if (iv && loadWeak && release) {
        void *raw = loadWeak((uint8_t *)(__bridge void *)memory.session + ivar_getOffset(iv));
        if (raw) {
            id render = (__bridge id)raw;
            if ([render isKindOfClass:UIView.class]) {
                memory.renderView = render;
                objc_setAssociatedObject(render, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            release(raw);
        }
    }
}

static void hook_render_transform(id self, SEL cmd, id view, uint64_t handle,
    float sx, float sy, float tx, float ty, float px, float py) {
    UUViewportMemory *memory = objc_getAssociatedObject(view, kUUAssocViewportMemory());
    if (NSThread.isMainThread && memory.pending && sOrigRenderTransform) {
        if (memory.applying) {
            UUDeferredRenderTransform *packet = [UUDeferredRenderTransform new];
            packet.manager = self; packet.renderView = view; packet.handle = handle;
            packet.sx = sx; packet.sy = sy; packet.tx = tx; packet.ty = ty; packet.px = px; packet.py = py;
            memory.deferredTransform = packet;
            return;
        }
        NSUInteger serial = memory.renderSerial;
        [memory tick:nil];
        UUDeferredRenderTransform *finalTransform = memory.lastRenderTransform;
        if (memory.pending && finalTransform.renderView == view && finalTransform.handle == handle) {
            if (serial == memory.renderSerial) UUForwardRenderTransform(finalTransform);
            return;
        }
    }
    if (sOrigRenderTransform) ((UURenderTransformFn)sOrigRenderTransform)(self, cmd, view, handle, sx, sy, tx, ty, px, py);
}

static void hook_content_layout(UIView *self, SEL _cmd) {
    if (sOrigContentLayout) ((void (*)(id, SEL))sOrigContentLayout)(self, _cmd);
    UUViewportMemory *memory = objc_getAssociatedObject(self, kUUAssocViewportMemory());
    [memory tick:nil];
}

static UUViewportMemory *UUPrepareViewportSwitch(id vm, id session, id targetScreen) {
    void *zoom = NULL, *offset = NULL;
    if (!UUViewportFunctions(&zoom, &offset)) return nil;
    UIViewController *vc = UUObjectIvar(vm, "contentViewController");
    if (![vc isKindOfClass:UIViewController.class]) return nil;
    UIView *content = UUObjectIvar(vc, "$__lazy_storage_$_remoteContentView");
    Class cls = objc_getClass("_TtC14nrd_ios_client17RemoteContentView");
    if (!cls || ![content isKindOfClass:cls]) return nil;
    int32_t nextID = UUScreenID(targetScreen);
    int32_t currentID = UUViewportCurrentScreenID(session);
    if (nextID < 0 || currentID < 0 || nextID == currentID) return nil;
    UUViewportMemory *memory = objc_getAssociatedObject(session, kUUAssocViewportMemory());
    if (!memory) {
        memory = [UUViewportMemory new];
        memory.session = session;
        objc_setAssociatedObject(session, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UUViewportSnapshot *outgoing = [UUViewportSnapshot new];
    BOOL valid = UUReadViewport(content, outgoing);
    if (valid && !memory.pending) memory.screens[@(currentID)] = outgoing;
    UUViewportSnapshot *incoming = memory.screens[@(nextID)] ?: memory.pending ?: (valid ? outgoing : nil);
    UUViewportSnapshot *source = memory.screens[@(currentID)] ?: (valid ? outgoing : nil);
    [memory stop];
    if (!incoming) return nil;
    memory.viewModel = vm;
    memory.content = content;
    UURefreshViewportBindings(memory);
    memory.targetID = nextID;
    memory.pending = incoming;
    memory.source = source;
    memory.sourceID = currentID;
    objc_setAssociatedObject(content, kUUAssocViewportMemory(), memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    memory.started = CACurrentMediaTime();
    return memory;
}

// ---- Native MultiScreenMenuView Hook -----------------------------------------

@interface UUMenuTapHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedInstance;
- (void)handleMenuTap:(UITapGestureRecognizer *)gesture;
@end

@implementation UUMenuTapHandler
+ (instancetype)sharedInstance {
    static UUMenuTapHandler *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [UUMenuTapHandler new];
    });
    return inst;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}
- (void)handleMenuTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded && gesture.state != UIGestureRecognizerStateRecognized) {
        return;
    }
    UIView *view = gesture.view;
    Class itemCls = objc_getClass(kClsMenuItem);
    UIView *item = view;
    while (item && itemCls && ![item isKindOfClass:itemCls]) {
        item = item.superview;
    }
    if (!item) return;
    id screenModel = UUObjectIvar(item, "screenModel");
    if (!screenModel) return;
    id vm = UUFindViewModel(item);
    if (!vm) return;
    id session = UUObjectIvar(vm, "session");
    if (!session) return;

    UUViewportMemory *mem = UUPrepareViewportSwitch(vm, session, screenModel);
    if (mem) {
        [mem start];
    }
}
@end

static void hook_menu_item_layout(UIView *self, SEL _cmd) {
    if (sOrigMenuItemLayout) ((void (*)(id, SEL))sOrigMenuItemLayout)(self, _cmd);
    @try {
        UIView *cell = UUObjectIvar(self, "screenCell") ?: self;
        if (!objc_getAssociatedObject(cell, &kAssocMenuTapHooked)) {
            objc_setAssociatedObject(cell, &kAssocMenuTapHooked, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            cell.userInteractionEnabled = YES;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[UUMenuTapHandler sharedInstance] action:@selector(handleMenuTap:)];
            tap.cancelsTouchesInView = NO;
            tap.delaysTouchesBegan = NO;
            tap.delaysTouchesEnded = NO;
            tap.delegate = [UUMenuTapHandler sharedInstance];
            [cell addGestureRecognizer:tap];
        }
    } @catch (NSException *e) {
        UULog(@"menu item layout exception: %@", e);
    }
}

// ---- Keyboard Combination Shortcuts Row --------------------------------------

typedef struct {
    uint8_t macModifierHID;
    uint8_t winModifierHID;
    uint8_t keyHID;
    const char *macTitle;
    const char *winTitle;
} UUShortcut;

static const UUShortcut kShortcuts[6] = {
    { 0xe1, 0xe1, 0x28, "Shift+Enter", "Shift+Enter" },
    { 0xe3, 0xe0, 0x04, "⌘A", "Ctrl+A" },
    { 0xe3, 0xe0, 0x1d, "⌘Z", "Ctrl+Z" },
    { 0xe3, 0xe0, 0x1b, "⌘X", "Ctrl+X" },
    { 0xe3, 0xe0, 0x06, "⌘C", "Ctrl+C" },
    { 0xe3, 0xe0, 0x19, "⌘V", "Ctrl+V" },
};

static Class UUKeyboardButtonClass(void) {
    static Class cls = Nil;
    if (!cls) cls = objc_getClass(kClsKeyButton);
    return cls;
}

static NSArray<UIView *> *UUFirstPageButtons(id owner) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    uintptr_t raw = 0;
    if (!UURawIvar(owner, "firstPageButtons", &raw, sizeof(raw))) return out;
    if (!raw || (raw & 0xC000000000000001ULL)) return out;
    NSInteger count = *(NSInteger *)(raw + 0x10);
    if (count <= 0 || count > 200) return out;

    Class btnCls = UUKeyboardButtonClass();
    for (NSInteger i = 0; i < count; i++) {
        id button = (__bridge id)(*(void **)(raw + 0x20 + (uintptr_t)i * sizeof(void *)));
        if (!button || !btnCls || ![button isKindOfClass:btnCls]) continue;
        [out addObject:button];
    }
    return out;
}

@interface UUShortcutTarget : NSObject
@property (nonatomic, weak) UIViewController *controller;
- (void)shortcutTapped:(UIButton *)sender;
@end

static UIImage *UUShiftEnterImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        UIImage *shift = [UIImage systemImageNamed:@"shift" withConfiguration:config];
        UIImage *enter = [UIImage systemImageNamed:@"return" withConfiguration:config];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(38, 16)];
        image = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [shift drawInRect:CGRectMake(0, 1, 15, 14)];
            [enter drawInRect:CGRectMake(23, 1, 15, 14)];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

static UIButton *UUMakeShortcutButton(UIView *template, NSInteger index) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    UIFont *font = nil;
    UIColor *textColor = nil;
    if ([template isKindOfClass:[UIButton class]]) {
        UIButton *t = (UIButton *)template;
        UIImage *bg = [t backgroundImageForState:UIControlStateNormal];
        UIImage *bgHi = [t backgroundImageForState:UIControlStateHighlighted];
        if (bg) {
            [btn setBackgroundImage:bg forState:UIControlStateNormal];
            if (bgHi) [btn setBackgroundImage:bgHi forState:UIControlStateHighlighted];
        }
        font = t.titleLabel.font;
        textColor = [t titleColorForState:UIControlStateNormal];
        if (!textColor) textColor = t.titleLabel.textColor;
        if (!font) {
            UILabel *label = UUFirstLabel(t);
            if (label) font = label.font;
        }
        if (!textColor) {
            UILabel *label = UUFirstLabel(t);
            if (label) textColor = label.textColor;
        }
        btn.backgroundColor = t.backgroundColor;
        btn.layer.cornerRadius = t.layer.cornerRadius;
        btn.layer.borderWidth = t.layer.borderWidth;
        btn.layer.borderColor = t.layer.borderColor;
        btn.contentEdgeInsets = t.contentEdgeInsets;
    }
    if (!btn.currentBackgroundImage) {
        BOOL lightText = YES;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            if ([textColor getRed:&r green:&g blue:&b alpha:&a]) {
                lightText = (0.299 * r + 0.587 * g + 0.114 * b) > 0.5;
            }
        } else {
            textColor = UIColor.whiteColor;
        }
        btn.backgroundColor = lightText ? [UIColor colorWithWhite:1.0 alpha:0.16]
                                       : [UIColor colorWithWhite:0.0 alpha:0.06];
        btn.layer.cornerRadius = 6.0;
        btn.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        btn.layer.borderColor = (lightText ? [UIColor colorWithWhite:1.0 alpha:0.12]
                                           : [UIColor colorWithWhite:0.0 alpha:0.10]).CGColor;
        btn.layer.masksToBounds = YES;
    }
    btn.layer.cornerRadius = 6.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.clipsToBounds = YES;
    if (!textColor) textColor = UIColor.whiteColor;
    [btn setTitleColor:textColor forState:UIControlStateNormal];
    btn.titleLabel.font = font ?: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    btn.titleLabel.numberOfLines = 1;
    btn.titleLabel.textAlignment = NSTextAlignmentCenter;
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    btn.titleLabel.minimumScaleFactor = 0.42;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsZero;
    if (index == 0) {
        [btn setImage:UUShiftEnterImage() forState:UIControlStateNormal];
        btn.tintColor = textColor;
        btn.contentEdgeInsets = UIEdgeInsetsMake(2, 2, 2, 2);
        btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    }
    btn.tag = index;
    return btn;
}

static void UURestoreKeyboardFrames(UIViewController *vc) {
    NSMapTable<UIView *, NSValue *> *frames = objc_getAssociatedObject(vc, &kAssocOriginalFrames);
    for (UIView *view in frames) {
        BOOL autoresizes = view.autoresizesSubviews;
        view.autoresizesSubviews = NO;
        view.frame = [frames objectForKey:view].CGRectValue;
        view.autoresizesSubviews = autoresizes;
    }
    objc_setAssociatedObject(vc, &kAssocOriginalFrames, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UUApplyKeyboardShortcuts(UIViewController *vc) {
    NSArray<UIView *> *buttons = UUFirstPageButtons(vc);
    if (!buttons.count) return;
    UIView *first = nil;
    for (UIView *button in buttons) {
        uint8_t keyType = 0xff;
        if (UURawIvar(button, "keyType", &keyType, 1) && keyType == 0x48) first = button;
    }
    if (!first.superview) return;

    UIView *content = first.superview;
    for (UIView *button in buttons) {
        while (content && ![button isDescendantOfView:content]) content = content.superview;
    }
    if (!content) return;
    NSMutableArray<UIButton *> *shortcuts = objc_getAssociatedObject(vc, &kAssocShortcutRow);
    if (!shortcuts) {
        shortcuts = [NSMutableArray array];
        UUShortcutTarget *target = [UUShortcutTarget new];
        target.controller = vc;
        objc_setAssociatedObject(vc, &kAssocShortcutTarget, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSInteger i = 0; i < 6; i++) {
            UIButton *button = UUMakeShortcutButton(first, i);
            [button addTarget:target action:@selector(shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
            [shortcuts addObject:button];
        }
        objc_setAssociatedObject(vc, &kAssocShortcutRow, shortcuts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIButton *button in shortcuts) {
        if (button.superview != content) [content addSubview:button];
    }

    NSMapTable<UIView *, NSValue *> *frames = objc_getAssociatedObject(vc, &kAssocOriginalFrames);
    if (frames) return;
    frames = [NSMapTable weakToStrongObjectsMapTable];
    CGFloat top = CGFLOAT_MAX, bottom = -CGFLOAT_MAX;
    CGFloat left = CGFLOAT_MAX, right = -CGFLOAT_MAX;
    CGRect symbolFrame = [first.superview convertRect:first.frame toView:content];
    for (UIView *button in buttons) {
        CGRect f = [button.superview convertRect:button.frame toView:content];
        if (CGRectIsEmpty(f)) continue;
        left = MIN(left, CGRectGetMinX(f));
        right = MAX(right, CGRectGetMaxX(f));
        top = MIN(top, CGRectGetMinY(f));
        bottom = MAX(bottom, CGRectGetMaxY(f));
    }
    if (top == CGFLOAT_MAX || bottom <= top || right <= left || CGRectIsEmpty(symbolFrame)) return;
    CGFloat gap = MAX(2.0, symbolFrame.size.height * 0.08);
    CGFloat scale = (bottom - top) / (bottom - top + symbolFrame.size.height + gap);
    CGFloat rowHeight = symbolFrame.size.height * scale;
    CGFloat shift = (symbolFrame.size.height + gap) * scale;
    NSMutableOrderedSet<UIView *> *views = [NSMutableOrderedSet orderedSet];
    for (UIView *button in buttons) {
        NSMutableArray<UIView *> *path = [NSMutableArray array];
        for (UIView *v = button; v && v != content; v = v.superview) [path addObject:v];
        for (UIView *v in path.reverseObjectEnumerator) [views addObject:v];
    }
    NSMapTable<UIView *, NSValue *> *destinations = [NSMapTable weakToStrongObjectsMapTable];
    for (UIView *v in views) {
        [frames setObject:[NSValue valueWithCGRect:v.frame] forKey:v];
        CGRect f = [v.superview convertRect:v.frame toView:content];
        f.origin.y = top + shift + (f.origin.y - top) * scale;
        f.size.height *= scale;
        [destinations setObject:[NSValue valueWithCGRect:f] forKey:v];
    }
    for (UIView *v in views) {
        BOOL autoresizes = v.autoresizesSubviews;
        v.autoresizesSubviews = NO;
        v.frame = [content convertRect:[destinations objectForKey:v].CGRectValue toView:v.superview];
        v.autoresizesSubviews = autoresizes;
    }
    objc_setAssociatedObject(vc, &kAssocOriginalFrames, frames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat width = (right - left - 5 * gap) / 6;
    uint8_t platform = 1;
    UURawIvar(first, "keyboardPlatform", &platform, 1);
    for (NSInteger i = 0; i < 6; i++) {
        UIButton *button = shortcuts[i];
        button.frame = CGRectMake(left + i * (width + gap), top, width, rowHeight);
        NSString *title = [NSString stringWithUTF8String:platform == 0 ? kShortcuts[i].winTitle : kShortcuts[i].macTitle];
        [button setTitle:i == 0 ? nil : title forState:UIControlStateNormal];
        button.accessibilityLabel = title;
        objc_setAssociatedObject(button, &kAssocShortcutIndex, @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, &kAssocShortcutTemplate, first, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL UUSendKeyArray(UIViewController *vc, const uint8_t *codes, size_t count) {
    if (!vc || !codes || count == 0 || count > 8) return NO;
    if (!UUIsSupportedAppVersion()) return NO;

    void *existential[2] = {0};
    if (!UURawIvar(vc, "keyboardEventSink", existential, sizeof(existential))) return NO;
    void *sink = existential[0];
    void *wtable = existential[1];
    if (!sink || !wtable) return NO;

    void *fn = *(void **)((uint8_t *)wtable + 8);
    if (!fn || !UUIsMainImagePointer(fn)) return NO;

    intptr_t slide = UUMainImageSlide();
    if (!slide) return NO;

    void *empty = dlsym(RTLD_DEFAULT, "__swiftEmptyArrayStorage");
    if (!empty) empty = *(void **)(slide + 0x1026dc218);
    if (!empty) return NO;
    if (*(uint64_t *)((uint8_t *)empty + 0x10) != 0) return NO;

    typedef void *(*EnsureFn)(uint64_t, uint64_t, uint64_t, void *);
    EnsureFn ensure = (EnsureFn)(slide + 0x10056d9e4);
    if (!UUIsMainImagePointer((void *)ensure)) return NO;
    if (!UUCodeStartsWith((void *)ensure, 0xa9bd57f6u)) return NO;

    void *storage = ensure(0, count, 1, empty);
    if (!storage) return NO;

    *(uint64_t *)((uint8_t *)storage + 0x10) = count;
    for (size_t i = 0; i < count; i++) {
        *(uint64_t *)((uint8_t *)storage + 0x20 + i * sizeof(uint64_t)) = codes[i];
    }

    void *(*getType)(void *) = dlsym(RTLD_DEFAULT, "swift_getObjectType");
    if (!getType) { UUSwiftRelease(storage); return NO; }
    void *type = getType(sink);
    uuss_call_key_sink(fn, sink, storage, 2, type, wtable);

    UUSwiftRelease(storage);
    return YES;
}

static void UUSendShortcut(UIViewController *vc, UIView *source, UIView *templateButton, NSInteger index) {
    if (index < 0 || index >= 6 || !vc) return;
    UIView *button = templateButton ?: source;
    if (!button) return;
    const UUShortcut *sc = &kShortcuts[index];

    uint8_t platform = 1;
    UURawIvar(button, "keyboardPlatform", &platform, 1);

    uint8_t codes[2] = {
        (platform == 0) ? sc->winModifierHID : sc->macModifierHID,
        sc->keyHID
    };
    UUSendKeyArray(vc, codes, 2);
}

@implementation UUShortcutTarget
- (void)shortcutTapped:(UIButton *)sender {
    NSNumber *idx = objc_getAssociatedObject(sender, &kAssocShortcutIndex);
    UIView *tpl = objc_getAssociatedObject(sender, &kAssocShortcutTemplate);
    if (!idx || !self.controller) return;
    @try {
        UUSendShortcut(self.controller, sender, tpl, idx.integerValue);
    } @catch (NSException *e) {
        UULog(@"shortcut exception: %@", e);
    }
}
@end

static void hook_ck_layout(UIViewController *self, SEL _cmd) {
    UURestoreKeyboardFrames(self);
    if (sOrigCkLayout) ((void (*)(id, SEL))sOrigCkLayout)(self, _cmd);
}

static void hook_ck_didLayout(UIViewController *self, SEL _cmd) {
    if (sOrigCkDidLayout) ((void (*)(id, SEL))sOrigCkDidLayout)(self, _cmd);
    @try {
        UUApplyKeyboardShortcuts(self);
    } @catch (NSException *e) {
        UULog(@"keyboard layout exception: %@", e);
    }
}

// ---- Virtual Mouse Circular Wheel Dial ---------------------------------------

static const double kWheelRadius = 46.0;
static const double kWheelDeadZone = 11.0;
static const double kWheelStep = 14.0 * M_PI / 180.0;

@interface UUWheelState : NSObject
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
@property (nonatomic) BOOL active;
@property (nonatomic) double lastAngle;
@property (nonatomic) double accumulated;
@property (nonatomic) double lastTime;
@property (nonatomic) NSInteger lastDirection;
@end
@implementation UUWheelState
@end

@interface UUWheelDialView : UIView
@property (nonatomic) CGFloat radius;
@property (nonatomic) BOOL rotating;
@property (nonatomic) CGFloat indicatorAngle;
@property (nonatomic) CGSize hostSize;
@end

@implementation UUWheelDialView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = [UIColor colorWithWhite:0.05 alpha:1.0].CGColor;
        self.layer.shadowOpacity = 0;
        self.layer.shadowRadius = 10.0;
        self.layer.shadowOffset = CGSizeMake(0, 3);
    }
    return self;
}
- (void)setRadius:(CGFloat)radius {
    _radius = radius;
    [self setNeedsDisplay];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = self.radius;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    self.layer.shadowPath = [UIBezierPath bezierPathWithArcCenter:c radius:r
                                                       startAngle:0 endAngle:M_PI * 2 clockwise:YES].CGPath;
}
- (void)setRotating:(BOOL)rotating {
    _rotating = rotating;
    [self setNeedsDisplay];
}
- (void)setIndicatorAngle:(CGFloat)indicatorAngle {
    _indicatorAngle = indicatorAngle;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat outerRadius = self.radius + 12.0;
    CGFloat innerRadius = self.radius - 12.0;
    if (innerRadius <= 0) return;
    UIBezierPath *outer = [UIBezierPath bezierPathWithArcCenter:c radius:outerRadius
        startAngle:0 endAngle:2 * M_PI clockwise:YES];
    UIBezierPath *inner = [UIBezierPath bezierPathWithArcCenter:c radius:innerRadius
        startAngle:0 endAngle:2 * M_PI clockwise:YES];
    UIBezierPath *ring = [outer copy];
    [ring appendPath:inner];
    ring.usesEvenOddFillRule = YES;
    [[UIColor colorWithRed:0.65 green:0.73 blue:0.75 alpha:0.42] setFill];
    [ring fill];
    [[UIColor colorWithRed:0.38 green:0.45 blue:0.46 alpha:0.62] setStroke];
    outer.lineWidth = inner.lineWidth = 1.5;
    [outer stroke];
    [inner stroke];
    if (!self.rotating) {
        UIBezierPath *center = [UIBezierPath bezierPathWithArcCenter:c radius:24
            startAngle:0 endAngle:2 * M_PI clockwise:YES];
        [[UIColor colorWithRed:0.76 green:0.82 blue:0.83 alpha:0.65] setFill];
        [center fill];
        [[UIColor colorWithRed:0.38 green:0.45 blue:0.46 alpha:0.62] setStroke];
        center.lineWidth = 1.5;
        [center stroke];
    } else {
        CGPoint indicator = CGPointMake(c.x + self.radius * cos(self.indicatorAngle),
                                        c.y + self.radius * sin(self.indicatorAngle));
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 4, [UIColor colorWithRed:1 green:0.74 blue:0.25 alpha:0.8].CGColor);
        [[UIColor colorWithRed:1 green:0.75 blue:0.28 alpha:0.95] setFill];
        [[UIBezierPath bezierPathWithArcCenter:indicator radius:8 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        CGContextRestoreGState(ctx);
    }
}
@end

static void UUWheelSend(NSInteger dy) {
    intptr_t slide = UUMainImageSlide();
    if (!slide) return;

    typedef struct { uint64_t a, b; } UUSwiftString;
    UUSwiftString (*build)(int64_t, int64_t, int64_t, uint8_t) =
        (UUSwiftString (*)(int64_t, int64_t, int64_t, uint8_t))(slide + 0x100277280);
    void (*send)(void *, void *, uint64_t, uint64_t) =
        (void (*)(void *, void *, uint64_t, uint64_t))(slide + 0x1007c68d0);

    if (!UUIsMainImagePointer((void *)build) || !UUIsMainImagePointer((void *)send)) return;
    if (!UUCodeStartsWith((void *)build, 0xa9bc5ff8u) ||
        !UUCodeStartsWith((void *)send, 0xd10203ffu)) return;

    UUSwiftString packet = build(0, dy, 0, 7);
    uint64_t context[4] = { 0, 0, 1, 0 };
    send(context, context, packet.a, packet.b);

    if (!(packet.b & 0x8000000000000000ULL)) UUSwiftRelease((void *)packet.a);
}

@interface UUWheelArtworkMask : NSObject
@property (nonatomic, strong) CALayer *original;
@property (nonatomic, strong) CALayer *empty;
@end
@implementation UUWheelArtworkMask
@end

static void UUSetWheelArtworkHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    UUWheelArtworkMask *state = objc_getAssociatedObject(view, &kAssocWheelArtworkMask);
    if (hidden) {
        if (!state) {
            state = [UUWheelArtworkMask new];
            state.original = view.layer.mask;
            state.empty = [CALayer layer];
            objc_setAssociatedObject(view, &kAssocWheelArtworkMask, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.layer.mask = state.empty;
    } else if (state) {
        if (view.layer.mask == state.empty) view.layer.mask = state.original;
        objc_setAssociatedObject(view, &kAssocWheelArtworkMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UUWheelDialView *UUEnsureDialForView(UIView *view) {
    UIView *mode = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollModeView");
    UIView *button = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollButton");
    UUWheelDialView *dial = objc_getAssociatedObject(view, &kAssocWheelDial);
    BOOL enabled = NO, folded = NO;
    UURawIvar(view, "enableScrollScreen", &enabled, 1);
    UURawIvar(view, "isFold", &folded, 1);
    if (!enabled || folded || mode.hidden || !mode.superview || !button.superview) {
        UUSetWheelArtworkHidden(button, NO);
        UUSetWheelArtworkHidden(mode, NO);
        dial.hidden = YES;
        return dial;
    }

    CGFloat side = 2.0 * (kWheelRadius + 16.0);
    if (!dial) {
        dial = [[UUWheelDialView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
        dial.radius = kWheelRadius;
        objc_setAssociatedObject(view, &kAssocWheelDial, dial, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL place = dial.superview != view || dial.hidden || !CGSizeEqualToSize(dial.hostSize, view.bounds.size);
    [UIView performWithoutAnimation:^{
        dial.bounds = CGRectMake(0, 0, side, side);
        if (place) dial.center = [mode.superview convertPoint:mode.center toView:view];
    }];
    dial.hostSize = view.bounds.size;
    if (dial.superview != view) [view addSubview:dial];
    [view bringSubviewToFront:dial];
    UIView *close = UUObjectIvar(view, "$__lazy_storage_$_closeButton");
    if (close.superview == view) [view bringSubviewToFront:close];
    UUWheelState *state = objc_getAssociatedObject(view, &kAssocWheelState);
    dial.rotating = state.active;
    dial.indicatorAngle = state.lastAngle;
    dial.hidden = NO;
    dial.alpha = 1.0;
    UUSetWheelArtworkHidden(mode, YES);
    UUSetWheelArtworkHidden(button, YES);
    return dial;
}

static void UUWheelHandle(UIView *view, SEL cmd, UIGestureRecognizer *gesture, IMP original) {
    BOOL enabled = NO;
    if (!UURawIvar(view, "enableScrollScreen", &enabled, 1) || !enabled) {
        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        return;
    }

    UIView *mode = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollModeView");
    UIView *button = UUObjectIvar(view, "$__lazy_storage_$_mouseScrollButton");
    if (!mode || !mode.superview || !button || !button.superview) {
        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        return;
    }

    UUWheelState *state = objc_getAssociatedObject(view, &kAssocWheelState);
    if (!state) {
        state = [UUWheelState new];
        state.feedback = [UISelectionFeedbackGenerator new];
        objc_setAssociatedObject(view, &kAssocWheelState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UUWheelDialView *dial = UUEnsureDialForView(view);
    CGPoint center = dial && !dial.hidden
        ? [view convertPoint:dial.center toView:button.superview]
        : [mode.superview convertPoint:mode.center toView:button.superview];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        id timer = UUObjectIvar(view, "sendScrollEventTimer");
        if ([timer respondsToSelector:@selector(invalidate)]) [timer invalidate];

        state.active = YES;
        state.accumulated = 0;
        state.lastDirection = 0;
        state.lastTime = CACurrentMediaTime();

        CGPoint p = [gesture locationInView:button.superview];
        state.lastAngle = atan2(p.y - center.y, p.x - center.x);

        UUEnsureDialForView(view);
        [state.feedback prepare];
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (!state.active) {
            if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
            return;
        }

        CGPoint p = [gesture locationInView:button.superview];
        double dx = p.x - center.x;
        double dy = p.y - center.y;
        double radius = hypot(dx, dy);
        if (radius < kWheelDeadZone) {
            state.lastAngle = atan2(dy, dx);
            return;
        }

        double angle = atan2(dy, dx);
        double delta = atan2(sin(angle - state.lastAngle), cos(angle - state.lastAngle));
        state.lastAngle = angle;

        double now = CACurrentMediaTime();
        double dt = now - state.lastTime;
        if (dt < 0.001) dt = 0.001;
        state.lastTime = now;

        double omega = fabs(delta) / dt;
        double gain = 1.0 + 1.0 * MIN(MAX(omega - 1.0, 0.0), 6.0) / 6.0;
        double effective = delta * gain;

        NSInteger direction = effective > 0 ? 1 : -1;
        if (state.lastDirection != 0 && direction != state.lastDirection) state.accumulated = 0;
        state.lastDirection = direction;
        state.accumulated += effective;

        NSInteger sent = 0;
        while (fabs(state.accumulated) >= kWheelStep && sent < 4) {
            double sign = state.accumulated > 0 ? 1.0 : -1.0;
            UUWheelSend(sign > 0 ? -120 : 120);
            state.accumulated -= sign * kWheelStep;
            sent++;
            [state.feedback selectionChanged];
        }

        dial.indicatorAngle = angle;
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        state.active = NO;
        state.accumulated = 0;
        state.lastDirection = 0;

        UUWheelDialView *d = objc_getAssociatedObject(view, &kAssocWheelDial);
        d.rotating = NO;

        if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
        UUEnsureDialForView(view);
        return;
    }

    if (original) ((void (*)(id, SEL, id))original)(view, cmd, gesture);
}

static void hook_wheel(UIView *self, SEL _cmd, UIGestureRecognizer *sender) {
    @try {
        UUWheelHandle(self, _cmd, sender, sOrigWheel);
    } @catch (NSException *e) {
        UULog(@"wheel exception: %@", e);
        if (sOrigWheel) ((void (*)(id, SEL, id))sOrigWheel)(self, _cmd, sender);
    }
}

static void hook_mouse_layout(UIView *self, SEL _cmd) {
    if (sOrigMouseLayout) ((void (*)(id, SEL))sOrigMouseLayout)(self, _cmd);
    @try {
        if (UUIsSupportedAppVersion()) UUEnsureDialForView(self);
    } @catch (NSException *e) {
        UULog(@"mouse layout exception: %@", e);
    }
}

static void hook_mouse_press(UIView *self, SEL _cmd) {
    if (sOrigMousePress) ((void (*)(id, SEL))sOrigMousePress)(self, _cmd);
    UUEnsureDialForView(self);
}

static void hook_mouse_release(UIView *self, SEL _cmd) {
    if (sOrigMouseRelease) ((void (*)(id, SEL))sOrigMouseRelease)(self, _cmd);
    UUEnsureDialForView(self);
}

// ---- Hooks Installation ------------------------------------------------------

static BOOL UUHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { UULog(@"method not found: %@", NSStringFromSelector(sel)); return NO; }
    BOOL own = NO;
    unsigned int c = 0;
    Method *list = class_copyMethodList(cls, &c);
    for (unsigned int i = 0; i < c; i++) if (list[i] == m) { own = YES; break; }
    free(list);
    if (!own) {
        *orig = method_getImplementation(m);
        return class_addMethod(cls, sel, imp, method_getTypeEncoding(m));
    }
    *orig = method_setImplementation(m, imp);
    return YES;
}

static void UUInstall(void) {
    static BOOL keyboardTried = NO, wheelTried = NO, menuTried = NO;

    Class ck = objc_getClass(kClsCombineKey);
    if (!keyboardTried && ck) {
        keyboardTried = YES;
        BOOL l = UUHook(ck, @selector(viewWillLayoutSubviews), (IMP)hook_ck_layout, &sOrigCkLayout);
        SEL didLayout = @selector(viewDidLayoutSubviews);
        Method method = class_getInstanceMethod(ck, didLayout);
        sOrigCkDidLayout = method_getImplementation(method);
        BOOL d = class_addMethod(ck, didLayout, (IMP)hook_ck_didLayout, method_getTypeEncoding(method));
        if (!d) d = UUHook(ck, didLayout, (IMP)hook_ck_didLayout, &sOrigCkDidLayout);
        UULog(@"keyboard hook: will=%d did=%d", l, d);
    }

    Class mouse = objc_getClass(kClsMouse);
    if (!wheelTried && mouse) {
        wheelTried = YES;
        if (UUIsSupportedAppVersion()) {
            BOOL w = UUHook(mouse, @selector(mouseScrollActionWithSender:), (IMP)hook_wheel, &sOrigWheel);
            BOOL ml = UUHook(mouse, @selector(layoutSubviews), (IMP)hook_mouse_layout, &sOrigMouseLayout);
            BOOL p = UUHook(mouse, @selector(mouseScrollButtonPress), (IMP)hook_mouse_press, &sOrigMousePress);
            BOOL r = UUHook(mouse, @selector(mouseScrollButtonRelease), (IMP)hook_mouse_release, &sOrigMouseRelease);
            UULog(@"wheel hooks: gesture=%d layout=%d press=%d release=%d", w, ml, p, r);
        }
    }

    Class menuItemCls = objc_getClass(kClsMenuItem);
    if (!menuTried && menuItemCls) {
        menuTried = YES;
        SEL sel = @selector(layoutSubviews);
        Method m = class_getInstanceMethod(menuItemCls, sel);
        if (m) {
            sOrigMenuItemLayout = method_getImplementation(m);
            BOOL added = class_addMethod(menuItemCls, sel, (IMP)hook_menu_item_layout, method_getTypeEncoding(m));
            if (!added) {
                UUHook(menuItemCls, sel, (IMP)hook_menu_item_layout, &sOrigMenuItemLayout);
            }
            UULog(@"menu item layout hook installed");
        }
    }

    SEL engineKey = kUUViewportEngineActive();
    if (!objc_getAssociatedObject(UIApplication.sharedApplication, engineKey)) {
        static BOOL renderTried = NO, contentTried = NO;
        Class renderer = objc_getClass("StreamerManager");
        if (!renderTried && renderer && UUIsSupportedAppVersion()) {
            renderTried = YES;
            SEL sel = sel_registerName(kRenderTransformSelector);
            Method method = class_getInstanceMethod(renderer, sel);
            BOOL signature = method && method_getNumberOfArguments(method) == 10;
            const char *expected[] = {"v", "@", "Q", "f", "f", "f", "f", "f", "f"};
            for (unsigned int i = 0; signature && i < 9; i++) {
                char *type = i == 0 ? method_copyReturnType(method) : method_copyArgumentType(method, i + 1);
                signature = type && strcmp(type, expected[i]) == 0;
                free(type);
            }
            BOOL r = signature && UUHook(renderer, sel, (IMP)hook_render_transform, &sOrigRenderTransform);
            UULog(@"viewport render hook=%d", r);
        }

        Class content = objc_getClass("_TtC14nrd_ios_client17RemoteContentView");
        if (!contentTried && content && UUIsSupportedAppVersion()) {
            contentTried = YES;
            BOOL c = UUHook(content, @selector(layoutSubviews), (IMP)hook_content_layout, &sOrigContentLayout);
            UULog(@"viewport layout hook=%d", c);
        }

        if (renderTried || contentTried) {
            objc_setAssociatedObject(UIApplication.sharedApplication, engineKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

__attribute__((constructor)) static void UUInit(void) {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.netease.uuremote"]) return;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            UUInstall();
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            UUInstall();
        }];
    }
}
