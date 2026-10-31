// QFOverlayHUD.m —— 全局拖动 + 常驻显示浮窗模块（移植自 QFSpeed-Overlay 2.1.6，仅保留浮窗核心）
//
// 移植要点（与参考源码一一对应，去掉了网速/CPU/设置面板等"其他"逻辑）：
//   ① 常驻：系统窗口 + SBSAccessibilityWindowHostingController 注册（委托控制器必须强引用）。
//   ② 触摸：UIApplication 的 eventDispatcher 的 run loop 源必须装到主 run loop；同时挂 eventFetcher。
//   ③ 拖动：窗口 hitTest 只命中浮条矩形，浮条挂 UIPanGestureRecognizer；HID 回调作备用通道。
//   ④ 位置：按归一化坐标 nx/ny 存，横竖屏来回不跑出屏。
//   ⑤ 退出：先 unregister 窗口上下文再销毁，避免"冻结贴图"残留。
//
// 注意：本文件调用多个 UIKit/BackBoard 私有符号，全部用 dlsym / NSSelectorFromString 取，不硬链接私有框架。

#import "QFOverlayHUD.h"

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

#pragma mark - 常量

// 共享偏好域：与宿主工程隔离，不干扰你原有的配置键。
#define QFOverlayDomain        "com.qfoverlay.module"
#define QFOverlayChangeNotify  "com.qfoverlay.module.changed"
#define QFOverlayResetNotify   "com.qfoverlay.module.reset"

#define QFOverlayPidPath       "/var/mobile/Library/Caches/com.qfoverlay.hud.pid"
#define QFOverlayLedgerDir     "/var/mobile/Library/Caches/com.qfoverlay.hud.d"
#define QFOverlayLogPath       "/var/mobile/Library/Logs/QFOverlay.log"
// UIKit 会把 10000010 钳回 10000000，直接写钳制后的值，行为可预期。
#define QFOverlayWindowLevel   10000000.0
#define QFOverlayDefaultBgAlpha 0.38
#define QFOverlayMinBgAlpha     0.18
#define QFOverlayDefaultFontSize 11.5

#pragma mark - 日志

static inline void QFOverlayLog(NSString *message) {
    if (message.length == 0) return;
    NSLog(@"[QFOverlay] %@", message);
    @try {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *path = @QFOverlayLogPath;
        [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES attributes:nil error:nil];
        if ([manager fileExistsAtPath:path]) {
            NSDictionary *attrs = [manager attributesOfItemAtPath:path error:nil];
            if (attrs && [attrs fileSize] > 256 * 1024) [manager removeItemAtPath:path error:nil];
        }
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) return;
        int fd = open(QFOverlayLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { write(fd, data.bytes, MIN(data.length, (NSUInteger)4000)); close(fd); }
    } @catch (__unused NSException *exception) {}
}
#define QFOverlayLogF(...) QFOverlayLog([NSString stringWithFormat:__VA_ARGS__])

#pragma mark - 共享偏好（容器文件 + CFPreferences + 系统路径，取最新一份）

static inline NSArray<NSString *> *QFOverlayPrefPaths(void) {
    NSString *container = [NSHomeDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Preferences/%s.plist", QFOverlayDomain]];
    return @[ container,
               [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%s.plist", QFOverlayDomain],
               [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%s.plist", QFOverlayDomain] ];
}

static inline double QFOverlayStamp(NSDictionary *state) {
    id v = state[@"_savedAt"]; return v ? [v doubleValue] : 0.0;
}

static inline NSDictionary *QFOverlayPrefRead(void) {
    NSDictionary *best = nil; double bestStamp = -1.0;
    for (NSString *path in QFOverlayPrefPaths()) {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:path];
        if (file.count == 0) continue;
        id nested = file[@"state"];
        NSDictionary *cand = [nested isKindOfClass:NSDictionary.class] ? nested : file;
        if (cand.count == 0) continue;
        double stamp = QFOverlayStamp(cand);
        if (stamp > bestStamp) { bestStamp = stamp; best = cand; }
    }
    CFPropertyListRef val = CFPreferencesCopyValue(CFSTR("state"), CFSTR(QFOverlayDomain),
                                                  kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (val) {
        if (CFGetTypeID(val) == CFDictionaryGetTypeID()) {
            NSDictionary *state = [(__bridge NSDictionary *)val copy];
            if (state.count && QFOverlayStamp(state) >= bestStamp) best = state;
        }
        CFRelease(val);
    }
    return best ?: @{};
}

static inline BOOL QFOverlayPrefWrite(NSDictionary *state) {
    if (!state) return NO;
    NSMutableDictionary *payload = [state mutableCopy];
    payload[@"_savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    state = payload;
    BOOL written = NO;
    CFPreferencesSetValue(CFSTR("state"), (__bridge CFPropertyListRef)state, CFSTR(QFOverlayDomain),
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (CFPreferencesSynchronize(CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost)) written = YES;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"state": state}
                                                           format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data) {
        for (NSString *path in QFOverlayPrefPaths()) {
            NSString *dir = [path stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            if ([data writeToFile:path atomically:YES]) written = YES;
        }
    }
    return written;
}

// 注册结果：HUD 进程把 registerWindow 的真实返回值写进 hudreg，App 侧据此决定是否补兜底浮条。
static inline void QFOverlayWriteRegistered(BOOL reg) {
    CFPropertyListRef v = (__bridge CFPropertyListRef)@(reg ? 1 : 0);
    CFPreferencesSetValue(CFSTR("hudreg"), v, CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}
static inline BOOL QFOverlayReadRegistered(void) {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("hudreg"), CFSTR(QFOverlayDomain),
                                                kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    BOOL f = NO; if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()||CFGetTypeID(v)==CFBooleanGetTypeID()) f=[(__bridge NSNumber*)v boolValue]; CFRelease(v); }
    return f;
}
// 心跳：比 kill(pid,0) 探活可靠（沙盒下常返回 EPERM）。
static inline void QFOverlayWriteBeat(void) {
    CFPropertyListRef v = (__bridge CFPropertyListRef)@([[NSDate date] timeIntervalSince1970]);
    CFPreferencesSetValue(CFSTR("hudbeat"), v, CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}
static inline BOOL QFOverlayBeatAlive(double within) {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("hudbeat"), CFSTR(QFOverlayDomain),
                                                kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    double stamp = 0; if (v) { if (CFGetTypeID(v)==CFNumberGetTypeID()) stamp=[(__bridge NSNumber*)v doubleValue]; CFRelease(v); }
    return stamp > 0 && ([[NSDate date] timeIntervalSince1970] - stamp) < within;
}
static inline void QFOverlayClearBeat(void) {
    CFPropertyListRef v = (__bridge CFPropertyListRef)@(0.0);
    CFPreferencesSetValue(CFSTR("hudbeat"), v, CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFOverlayDomain), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}

#pragma mark - 权限自检（entitlements 是否被内核真正认可）

static inline NSString *QFOverlayEntitlementsXML(void) {
    static NSString *cached; static dispatch_once_t once;
    dispatch_once(&once, ^{
        typedef int (*QFcsFn)(pid_t, unsigned int, void *, size_t);
        QFcsFn csops = (QFcsFn)dlsym(RTLD_DEFAULT, "csops");
        if (!csops) return;
        const size_t sz = 64*1024; unsigned char *buf = calloc(1, sz);
        if (!buf) return;
        if (csops(getpid(), 7, buf, sz) == 0) {       // 7 = CS_OPS_ENTITLEMENTS_BLOB
            unsigned int magic = 0, length = 0;
            memcpy(&magic, buf, 4); memcpy(&length, buf+4, 4);
            magic = ntohl(magic); length = ntohl(length);
            if (magic == 0xfade7171u && length > 8 && length <= sz) {
                cached = [[NSString alloc] initWithData:[NSData dataWithBytes:buf+8 length:length-8] encoding:NSUTF8StringEncoding];
            }
        }
        free(buf);
    });
    return cached ?: @"";
}
static inline BOOL QFOverlayHasEntitlement(NSString *key) {
    NSString *xml = QFOverlayEntitlementsXML();
    if (xml.length == 0 || key.length == 0) return NO;
    return [xml rangeOfString:[NSString stringWithFormat:@"<key>%@</key>", key]].location != NSNotFound;
}
static inline BOOL QFOverlayCanWriteSystemPath(void) {
    const char *p = "/var/mobile/Library/Logs/.qfoverlay_probe";
    int fd = open(p, O_WRONLY|O_CREAT, 0644);
    if (fd < 0) return NO; close(fd); unlink(p); return YES;
}
static inline NSString *QFOverlayEntitlementsSummary(void) {
    if (QFOverlayEntitlementsXML().length == 0) return @"读不到 entitlements（csops 失败）";
    return [NSString stringWithFormat:@"platform=%@ sandbox=%@ winHosting=%@ backboard=%@ hid=%@ 系统目录=%@",
            QFOverlayHasEntitlement(@"platform-application")?@"✓":@"✗",
            QFOverlayHasEntitlement(@"com.apple.private.security.no-sandbox")?@"✓":@"✗",
            QFOverlayHasEntitlement(@"com.apple.springboard.accessibility-window-hosting")?@"✓":@"✗",
            QFOverlayHasEntitlement(@"com.apple.backboard.client")?@"✓":@"✗",
            QFOverlayHasEntitlement(@"com.apple.private.hid.client.event-monitor")?@"✓":@"✗",
            QFOverlayCanWriteSystemPath()?@"可写":@"不可写"];
}

#pragma mark - 私有符号（全部 dlsym，不硬链接私有框架）

static void QFOverlayLoadFrameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths = @[
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            @"/System/Library/Frameworks/UIKit.framework/UIKit",
        ];
        for (NSString *p in paths) dlopen(p.UTF8String, RTLD_NOW);
    });
}
static void *QFOverlayLookup(const char *symbol) {
    QFOverlayLoadFrameworks();
    void *ptr = dlsym(RTLD_DEFAULT, symbol);
    if (ptr) return ptr;
    NSArray<NSString *> *paths = @[
        @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
        @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        @"/System/Library/Frameworks/UIKit.framework/UIKit",
    ];
    for (NSString *p in paths) { void *h = dlopen(p.UTF8String, RTLD_NOW); if (!h) continue; if ((ptr = dlsym(h, symbol))) return ptr; }
    return NULL;
}

typedef void (*QFOverlayVoidFn)(void);
typedef void (*QFOverlaySingletonFn)(Class);
typedef void (*QFOverlayHIDCallback)(void *target, void *refcon, void *service, void *event);
typedef void (*QFOverlayHIDRegisterFn)(QFOverlayHIDCallback callback);
typedef void (*QFOverlayUIntFn)(unsigned int);
typedef void (*QFOverlayModeFn)(CFStringRef);

#pragma mark - 浮条视图

static double gBarBgAlpha = QFOverlayDefaultBgAlpha;
static double gBarFontSize = QFOverlayDefaultFontSize;

@class QFOverlayBarView;
static void QFOverlayHandlePan(id pan);
static void QFOverlayHandleTap(id tap);
static void QFOverlayHandleLongPress(id lp);
static void QFOverlayToggleLock(void);
static void QFOverlayToggleCompact(void);
static void QFOverlayFlash(NSString *text, NSTimeInterval seconds);
static void QFOverlayShake(void);
static void QFOverlayLockHint(void);
static void QFOverlayMarkTouchArrived(void);
static void QFOverlayRefreshText(void);

@interface QFOverlayBarView : UIView
@property (nonatomic, strong) UILabel *label;
- (void)applyBackgroundAlpha:(double)alpha fontSize:(double)fontSize;
@end

@implementation QFOverlayBarView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 10.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
        self.userInteractionEnabled = YES;
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 1;
        _label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _label.shadowOffset = CGSizeMake(0.0, 0.5);
        [self addSubview:_label];
        [self applyBackgroundAlpha:gBarBgAlpha fontSize:gBarFontSize];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(qf_pan:)];
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(qf_tap:)];
        tap.numberOfTapsRequired = 1;
        [tap requireGestureRecognizerToFail:pan];   // 拖动过就不算点击
        [self addGestureRecognizer:tap];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(qf_longPress:)];
        lp.minimumPressDuration = 0.55;
        [self addGestureRecognizer:lp];
    }
    return self;
}
- (void)qf_pan:(id)pan { QFOverlayHandlePan(pan); }
- (void)qf_tap:(id)tap { QFOverlayHandleTap(tap); }
- (void)qf_longPress:(id)lp { QFOverlayHandleLongPress(lp); }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    QFOverlayMarkTouchArrived();   // 手势通道收到触摸就关掉 HID 备用通道
}
- (void)applyBackgroundAlpha:(double)alpha fontSize:(double)fontSize {
    alpha = MAX(0.0, MIN(1.0, alpha));
    fontSize = MAX(8.0, MIN(20.0, fontSize));
    gBarBgAlpha = alpha; gBarFontSize = fontSize;
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    self.layer.borderWidth = alpha > 0.02 ? 0.5 : 0.0;
    self.label.font = [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightMedium];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.label.frame = CGRectInset(self.bounds, 10.0, 3.0);
}
- (void)setText:(NSString *)text {
    if ([self.label.text isEqualToString:text]) return;
    self.label.text = text;
    CGSize fitted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGPoint center = self.center; CGRect bounds = self.bounds;
    bounds.size = CGSizeMake(MAX(ceil(fitted.width)+20.0, 72.0), MAX(ceil(fitted.height)+6.0, 22.0));
    self.bounds = bounds; self.center = center;
    [self setNeedsLayout];
}
@end

@interface QFOverlayRootController : UIViewController @end
@implementation QFOverlayRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
}
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

#pragma mark - 系统窗口

static UIView *QFOverlayHitTestBar(CGPoint pointInWindow);

@interface QFOverlayWindow : UIWindow @end
static BOOL gSecureContext = NO;

@implementation QFOverlayWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }   // 1.5.0 起不再整窗穿透，只命中浮条
- (BOOL)_isSecure { return gSecureContext; }
- (BOOL)_shouldCreateContextAsSecure { return gSecureContext; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return QFOverlayHitTestBar(point);
}
@end

#pragma mark - 状态

static void QFOverlayClampBar(void);
static void QFOverlayPersistPosition(void);
static NSArray<NSNumber *> *QFOverlayLiveInstances(void);
static unsigned int QFOverlayWindowContextId(UIWindow *window);

static QFOverlayWindow *gWindow;
static QFOverlayRootController *gRoot;
static QFOverlayBarView *gBar;
static NSTimer *gTimer;
static CGRect gScreenBounds = { {0,0},{0,0} };
static BOOL gMounted, gRegistered;
static BOOL gLocked;
static NSTimeInterval gStartWall;
static NSTimeInterval gLastKillRequestAt;

static BOOL gGestureEverWorked;
static CGPoint gGestureBeganCenter;
static BOOL gGestureMoved;
static NSString *gFlashText;
static NSTimeInterval gFlashUntil;
static BOOL gLockHintShownThisDrag;

#pragma mark - 手势

static void QFOverlayMarkTouchArrived(void) {
    if (gGestureEverWorked) return;
    gGestureEverWorked = YES;
    QFOverlayLog(@"UIKit 触摸已到达浮条，HID 备用通道关闭");
}
static void QFOverlayFlash(NSString *text, NSTimeInterval seconds) {
    gFlashText = text; gFlashUntil = [NSDate timeIntervalSinceReferenceDate] + seconds;
    QFOverlayRefreshText();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([NSDate timeIntervalSinceReferenceDate] >= gFlashUntil) { gFlashText = nil; QFOverlayRefreshText(); }
    });
}
static void QFOverlayLockHint(void) {
    if (gLockHintShownThisDrag) return;
    gLockHintShownThisDrag = YES;
    QFOverlayShake();
    QFOverlayFlash(@"🔒 位置已锁定 · 长按解锁", 1.6);
    QFOverlayLog(@"拖动被锁定拦截，已提示长按解锁");
}
static void QFOverlayToggleLock(void) {
    gLocked = !gLocked;
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"locked"] = @(gLocked);
    QFOverlayPrefWrite(state);
    if (gLocked) { QFOverlayFlash(@"🔒 位置已锁定", 1.2); QFOverlayLog(@"长按 → 锁定位置"); }
    else { QFOverlayFlash(@"位置已解锁，可拖动", 1.2); QFOverlayLog(@"长按 → 解锁位置"); }
    QFOverlayRefreshText();
}
static void QFOverlayHandlePan(id pan) {
    if (!gBar || !gRoot) return;
    UIView *root = gRoot.view; if (!root) return;
    switch ((UIGestureRecognizerState)[pan state]) {
        case UIGestureRecognizerStateBegan:
            gGestureEverWorked = YES; gGestureMoved = NO; gLockHintShownThisDrag = NO;
            gGestureBeganCenter = gBar.center; break;
        case UIGestureRecognizerStateChanged: {
            CGPoint t = [pan translationInView:root];
            if (fabs(t.x) > 3.0 || fabs(t.y) > 3.0) gGestureMoved = YES;
            if (gLocked) { if (gGestureMoved) QFOverlayLockHint(); break; }
            gBar.center = CGPointMake(gGestureBeganCenter.x + t.x, gGestureBeganCenter.y + t.y);
            QFOverlayClampBar(); break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (gGestureMoved && !gLocked) { QFOverlayPersistPosition(); QFOverlayLogF(@"拖动结束 → (%.0f,%.0f)", gBar.center.x, gBar.center.y); }
            gGestureMoved = NO; break;
        default: break;
    }
}
static void QFOverlayHandleTap(id tap) {
    if ((UIGestureRecognizerState)[tap state] != UIGestureRecognizerStateEnded) return;
    gGestureEverWorked = YES;
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL compact = ![state[@"compact"] boolValue];
    state[@"compact"] = @(compact);
    QFOverlayPrefWrite(state);
    QFOverlayRefreshText();
    QFOverlayLogF(@"点击 → %@模式", compact ? @"紧凑" : @"完整");
}
static void QFOverlayHandleLongPress(id lp) {
    if ((UIGestureRecognizerState)[lp state] != UIGestureRecognizerStateBegan) return;
    gGestureEverWorked = YES; QFOverlayToggleLock();
}
static void QFOverlayShake(void) {
    if (!gBar) return;
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[@0,@-7,@7,@-5,@5,@-2,@2,@0]; shake.duration = 0.35;
    [gBar.layer addAnimation:shake forKey:@"qf.shake"];
}
static UIView *QFOverlayHitTestBar(CGPoint pointInWindow) {
    if (!gBar || !gRoot || !gWindow || gBar.hidden) return nil;
    UIView *root = gRoot.view; if (!root) return nil;
    CGPoint inRoot = [gWindow convertPoint:pointInWindow toView:root];
    CGRect hit = CGRectInset(gBar.frame, -12.0, -12.0);   // 外扩 12pt 容错
    if (!CGRectContainsPoint(hit, inRoot)) return nil;
    return gBar;
}

#pragma mark - 位置与文案

static void QFOverlayClampBar(void) {
    if (!gBar) return;
    CGRect b = gRoot ? gRoot.view.bounds : gScreenBounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    CGSize s = gBar.bounds.size; CGPoint c = gBar.center;
    c.x = MAX(s.width/2+6, MIN(b.size.width - s.width/2 - 6, c.x));
    c.y = MAX(s.height/2+6, MIN(b.size.height - s.height/2 - 6, c.y));
    gBar.center = c;
}
static void QFOverlayPlaceFromPrefs(NSDictionary *state) {
    if (!gBar) return;
    CGRect b = gRoot ? gRoot.view.bounds : gScreenBounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    double nx = -1, ny = -1;
    if (state[@"nx"] && state[@"ny"]) { nx = [state[@"nx"] doubleValue]; ny = [state[@"ny"] doubleValue]; }
    else {
        double lx = [state[@"x"] doubleValue], ly = [state[@"y"] doubleValue];
        if (lx > 1 && ly > 1 && gScreenBounds.size.width > 1 && gScreenBounds.size.height > 1) {
            nx = lx / gScreenBounds.size.width; ny = ly / gScreenBounds.size.height;
        }
    }
    if (nx < 0 || nx > 1) nx = 0.5;
    if (ny < 0 || ny > 1) ny = 0.12;
    gBar.center = CGPointMake(nx*b.size.width, ny*b.size.height);
    QFOverlayClampBar();
}
static void QFOverlayPersistPosition(void) {
    if (!gBar) return;
    CGRect b = gRoot ? gRoot.view.bounds : gScreenBounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"nx"] = @(gBar.center.x / b.size.width);
    state[@"ny"] = @(gBar.center.y / b.size.height);
    state[@"x"] = @(gBar.center.x); state[@"y"] = @(gBar.center.y);
    QFOverlayPrefWrite(state);
}
static void QFOverlayRefreshText(void) {
    if (!gBar) return;
    if (gFlashText && [NSDate timeIntervalSinceReferenceDate] < gFlashUntil) { [gBar setText:gFlashText]; return; }
    // 文字来源解耦：宿主通过 +setOverlayText: 写入共享偏好的 overlayText 键。
    NSDictionary *state = QFOverlayPrefRead();
    NSString *text = state[@"overlayText"];
    if (text.length == 0) text = @"QFSpeed";
    if (gLocked) text = [@"🔒 " stringByAppendingString:text];
    [gBar setText:text];
}

#pragma mark - 建窗 + 注册到 SpringBoard

static unsigned int QFOverlayWindowContextId(UIWindow *window) {
    unsigned int ctx = 0;
    SEL sel = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:sel]) {
        NSMethodSignature *sig = [window methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:window]; [inv setSelector:sel]; [inv invoke];
            if (sig.methodReturnLength >= sizeof(unsigned int)) [inv getReturnValue:&ctx];
        }
    }
    if (ctx == 0) { @try { ctx = (unsigned int)[[window valueForKey:@"_contextId"] unsignedIntValue]; } @catch (__unused NSException *e) {} }
    return ctx;
}
static BOOL QFOverlayRegisterWindow(UIWindow *window) {
    Class hostClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostClass) { QFOverlayLog(@"未找到 SBSAccessibilityWindowHostingController，无法注册窗口"); return NO; }
    unsigned int ctx = QFOverlayWindowContextId(window);
    if (ctx == 0) { QFOverlayLogF(@"拿不到窗口的 _contextId（CAContext 未建出），注册中止 secure=%d", gSecureContext?1:0); return NO; }
    double level = window.windowLevel;
    // ★ 必须强引用托管控制器：它一释放，SpringBoard 侧挂着的窗口也跟着撤掉。
    static id host;
    if (!host) host = [[hostClass alloc] init];
    if (!host) { QFOverlayLog(@"SBSAccessibilityWindowHostingController 创建失败"); return NO; }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:host];
    [inv setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [inv setArgument:&ctx atIndex:2];
    [inv setArgument:&level atIndex:3];
    @try { [inv invoke]; }
    @catch (NSException *e) { QFOverlayLogF(@"注册窗口抛异常 %@", e); return NO; }
    QFOverlayLogF(@"窗口已交给 SpringBoard 合成 ctx=%u level=%.0f secure=%d", ctx, level, gSecureContext?1:0);
    return YES;
}
static BOOL QFOverlayCreateWindowAndRegister(BOOL secure) {
    gSecureContext = secure;
    QFOverlayWindow *window = [[QFOverlayWindow alloc] initWithFrame:gScreenBounds];
    QFOverlayRootController *controller = [QFOverlayRootController new];
    QFOverlayBarView *bar = [[QFOverlayBarView alloc] initWithFrame:CGRectMake(0, 0, 220, 24)];
    gWindow = window; gRoot = controller; gBar = bar;

    // 顺序严格照抄 TrollSpeed：delegate.window 必须在 makeKeyAndVisible 之前。
    id appDelegate = (id)[UIApplication sharedApplication].delegate;
    if (appDelegate) { @try { [appDelegate setValue:window forKey:@"window"]; } @catch (__unused NSException *e) {} }

    window.windowLevel = QFOverlayWindowLevel;
    window.backgroundColor = UIColor.clearColor; window.opaque = NO;
    window.layer.opaque = NO; window.layer.backgroundColor = UIColor.clearColor.CGColor;

    // plugin 进程没有 windowScene，contentsScale 不会自动继承，必须手动给成屏幕 scale，否则字被放大三倍的糊。
    CGFloat scale = [UIScreen mainScreen].scale; if (scale < 1) scale = 3.0;
    window.layer.contentsScale = scale;
    controller.view.contentScaleFactor = scale;
    controller.view.layer.contentsScale = scale;

    window.rootViewController = controller;
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.frame = window.bounds;
    [controller.view addSubview:bar];

    NSDictionary *state = QFOverlayPrefRead();
    double alpha = [state[@"bgAlpha"] doubleValue];
    if (alpha < QFOverlayMinBgAlpha) alpha = QFOverlayDefaultBgAlpha;
    alpha = MIN(1.0, alpha);
    [bar applyBackgroundAlpha:alpha fontSize:[state[@"fontSize"] doubleValue] ?: QFOverlayDefaultFontSize];
    gLocked = [state[@"locked"] boolValue];
    QFOverlayPlaceFromPrefs(state);
    QFOverlayRefreshText();

    window.hidden = NO;
    [window makeKeyAndVisible];
    [window layoutIfNeeded];

    BOOL registered = QFOverlayRegisterWindow(window);
    gRegistered = registered;
    return registered;
}
static void QFOverlayTeardownWindow(void) {
    if (gWindow) { @try { gWindow.hidden = YES; gWindow.rootViewController = nil; } @catch (__unused NSException *e) {} }
    gWindow = nil; gRoot = nil; gBar = nil; gMounted = NO; gRegistered = NO;
}

#pragma mark - 干净退出

static void QFOverlayShutdown(NSString *reason) {
    QFOverlayLogF(@"退出浮窗：%@", reason);
    QFOverlayWriteRegistered(NO);
    QFOverlayClearBeat();
    unlink(QFOverlayPidPath);
    [[NSFileManager defaultManager] removeItemAtPath:
        [@QFOverlayLedgerDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", getpid()]] error:nil];
    UIWindow *window = gWindow;
    if (!window) exit(EXIT_SUCCESS);
    unsigned int ctx = QFOverlayWindowContextId(window);
    Class hostClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (ctx != 0 && hostClass) {
        id host = [[hostClass alloc] init];
        NSArray<NSString *> *cands = @[ @"unregisterWindowWithContextID:", @"unregisterWindow:", @"removeWindowWithContextID:" ];
        for (NSString *name in cands) {
            SEL sel = NSSelectorFromString(name);
            if (![host respondsToSelector:sel]) continue;
            NSMethodSignature *sig = [host methodSignatureForSelector:sel];
            if (!sig) continue;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:host]; [inv setSelector:sel];
            if (sig.numberOfArguments > 2) {
                const char *type = [sig getArgumentTypeAtIndex:2];
                if (type && type[0] == '@') [inv setArgument:&window atIndex:2]; else [inv setArgument:&ctx atIndex:2];
            }
            @try { [inv invoke]; QFOverlayLogF(@"已注销窗口上下文 ctx=%u 方法=%@", ctx, name); }
            @catch (NSException *e) { QFOverlayLogF(@"注销窗口上下文抛异常 %@", e); }
            break;
        }
    }
    gWindow = nil; gBar = nil; gRoot = nil;
    window.hidden = YES; window.alpha = 0.0; window.rootViewController = nil; [window removeFromSuperview];
    exit(EXIT_SUCCESS);
}

#pragma mark - 配置轮询（0.25s）+ 变化通知

static NSString *QFOverlayDigest(NSDictionary *state) {
    return [NSString stringWithFormat:@"c%d lock%d a%.2f f%.1f t%@",
            [state[@"compact"] boolValue], [state[@"locked"] boolValue],
            [state[@"bgAlpha"] doubleValue], [state[@"fontSize"] doubleValue],
            state[@"overlayText"] ?: @""];
}
static void QFOverlayPoll(void) {
    static NSString *applied; static BOOL sawEnabledOnce;
    NSDictionary *latest = QFOverlayPrefRead();

    double killAt = [latest[@"killAt"] doubleValue];
    if (killAt > 0 && gStartWall > 0 && killAt > gStartWall) { QFOverlayShutdown(@"收到宿主的结束指令"); return; }

    id enabledFlag = latest[@"enabled"];
    BOOL explicitlyOff = enabledFlag != nil && ![enabledFlag boolValue];
    BOOL oldEnough = gStartWall > 0 && ([[NSDate date] timeIntervalSince1970] - gStartWall > 4.0);
    if (explicitlyOff && (sawEnabledOnce || oldEnough)) { QFOverlayShutdown(@"宿主关闭了常驻浮窗"); return; }
    if ([enabledFlag boolValue]) sawEnabledOnce = YES;

    NSString *digest = QFOverlayDigest(latest);
    if (![digest isEqualToString:applied]) {
        applied = digest;
        gLocked = [latest[@"locked"] boolValue];
        double alpha = [latest[@"bgAlpha"] doubleValue];
        if (alpha < QFOverlayMinBgAlpha) alpha = QFOverlayDefaultBgAlpha;
        [gBar applyBackgroundAlpha:alpha fontSize:[latest[@"fontSize"] doubleValue] ?: QFOverlayDefaultFontSize];
        QFOverlayRefreshText();
    }
}

#pragma mark - 挂载

static void QFOverlayMount(void) {
    if (gMounted && gWindow) return;
    UIScreen *screen = [UIScreen mainScreen];
    CGRect raw = screen ? screen.bounds : CGRectZero;
    QFOverlayLogF(@"屏幕自检 UIScreen=%@ bounds=%.0fx%.0f scale=%.2f",
                  screen?NSStringFromClass(screen.class):@"nil", raw.size.width, raw.size.height, screen?screen.scale:-1);
    gScreenBounds = raw;
    if (gScreenBounds.size.width < 1 || gScreenBounds.size.height < 1) { gScreenBounds = CGRectMake(0,0,390,844); QFOverlayLog(@"屏幕读到 0x0，改用兜底 390x844"); }

    BOOL registered = QFOverlayCreateWindowAndRegister(NO);
    gMounted = YES;
    QFOverlayWriteRegistered(registered);
    QFOverlayLogF(@"已挂载 屏幕=%.0fx%.0f 位置=(%.0f,%.0f) 注册=%@ ctx=%u",
                  gScreenBounds.size.width, gScreenBounds.size.height,
                  gBar.center.x, gBar.center.y, registered?@"成功":@"失败", QFOverlayWindowContextId(gWindow));
    QFOverlayLogF(@"窗口自检 layer=%.0fx%.0f scale=%.2f 条=%.0fx%.0f bg=%.2f 文字=\"%@\"",
                  gWindow.layer.bounds.size.width, gWindow.layer.bounds.size.height, gWindow.layer.contentsScale,
                  gBar.bounds.size.width, gBar.bounds.size.height, gBarBgAlpha, gBar.label.text ?: @"");
    QFOverlayLogF(@"[权限自检] %@", QFOverlayEntitlementsSummary());
    if (!QFOverlayHasEntitlement(@"com.apple.springboard.accessibility-window-hosting"))
        QFOverlayLog(@"[权限自检] 缺少 accessibility-window-hosting，SpringBoard 会丢弃注册的窗口");

    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                    object:nil queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note){
        UIInterfaceOrientation o = UIInterfaceOrientationPortrait;
        switch (UIDevice.currentDevice.orientation) {
            case UIDeviceOrientationLandscapeLeft:  o = UIInterfaceOrientationLandscapeRight; break;
            case UIDeviceOrientationLandscapeRight: o = UIInterfaceOrientationLandscapeLeft; break;
            case UIDeviceOrientationPortraitUpsideDown: o = UIInterfaceOrientationPortraitUpsideDown; break;
            default: o = UIInterfaceOrientationPortrait; break;
        }
        UIScreen *s = [UIScreen mainScreen];
        if (s) { gScreenBounds = s.bounds; [gBar.superview setNeedsLayout]; QFOverlayPlaceFromPrefs(QFOverlayPrefRead()); }
        QFOverlayLogF(@"方向切换 %ld 视图尺寸 %.0fx%.0f", (long)o, gScreenBounds.size.width, gScreenBounds.size.height);
    }];

    if (gTimer) [gTimer invalidate];
    gTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t){ QFOverlayBeatAlive(0); QFOverlayWriteBeat(); QFOverlayPoll(); }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];

    static NSTimer *cfg;
    if (cfg) [cfg invalidate];
    cfg = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *t){ QFOverlayPoll(); }];
    [[NSRunLoop mainRunLoop] addTimer:cfg forMode:NSRunLoopCommonModes];

    static int changeToken;
    notify_register_dispatch(QFOverlayChangeNotify, &changeToken, dispatch_get_main_queue(), ^(int t){ (void)t; QFOverlayPoll(); });
    static int resetToken;
    notify_register_dispatch(QFOverlayResetNotify, &resetToken, dispatch_get_main_queue(), ^(int t){
        (void)t; NSDictionary *l = QFOverlayPrefRead(); [gBar applyBackgroundAlpha:[l[@"bgAlpha"] doubleValue]?:QFOverlayDefaultBgAlpha fontSize:[l[@"fontSize"] doubleValue]?:QFOverlayDefaultFontSize]; QFOverlayPlaceFromPrefs(l);
    });

    if (!registered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QFOverlayLog(@"第一次注册失败，改用 secure 上下文重建一次");
            QFOverlayTeardownWindow();
            BOOL retried = QFOverlayCreateWindowAndRegister(YES);
            gMounted = YES; QFOverlayWriteRegistered(retried);
            QFOverlayLogF(@"重建完成（secure=1）注册=%@ ctx=%u", retried?@"成功":@"失败", QFOverlayWindowContextId(gWindow));
            if (!retried) QFOverlayLog(@"两条路都注册不上：签名里的 accessibility-window-hosting 大概率没生效，请用 TrollStore 重新安装");
        });
    }
    if (registered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gWindow) return;
            BOOL again = QFOverlayRegisterWindow(gWindow);
            QFOverlayLogF(@"补注册 ctx=%u 结果=%@", QFOverlayWindowContextId(gWindow), again?@"成功":@"失败");
            QFOverlayWriteRegistered(again || QFOverlayReadRegistered());
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gWindow) return;
        if (gWindow.hidden || gWindow.alpha < 0.01) {
            gWindow.hidden = NO; gWindow.alpha = 1.0; [gWindow makeKeyAndVisible];
            gRegistered = QFOverlayRegisterWindow(gWindow); QFOverlayWriteRegistered(gRegistered);
        } else {
            QFOverlayLogF(@"自检 hidden=%d alpha=%.2f center=(%.0f,%.0f) ctx=%u 注册=%@",
                          gWindow.hidden, gWindow.alpha, gBar.center.x, gBar.center.y,
                          QFOverlayWindowContextId(gWindow), gRegistered?@"是":@"否");
        }
    });
}

#pragma mark - 宿主 App 进程控制

static NSString *QFOverlayExecutablePath(void) {
    static NSString *path; static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t sz = 0; _NSGetExecutablePath(NULL, &sz); if (sz == 0) return;
        char *buf = calloc(1, sz+1); if (!buf) return;
        if (_NSGetExecutablePath(buf, &sz) == 0) path = [NSString stringWithUTF8String:buf];
        free(buf);
    });
    return path;
}
typedef int (*QFOverlayPersonaFn)(const posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*QFOverlayPersonaIdFn)(const posix_spawnattr_t *, uid_t);
static void QFOverlayApplyPersona(posix_spawnattr_t *attr) {
    QFOverlayPersonaFn setPersona = (QFOverlayPersonaFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    QFOverlayPersonaIdFn setUid = (QFOverlayPersonaIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    QFOverlayPersonaIdFn setGid = (QFOverlayPersonaIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!setPersona || !setUid || !setGid) return;
    setPersona(attr, 99, 1); setUid(attr, 0); setGid(attr, 0);   // 以 root 身份拉起，常驻不被挂起
}
static pid_t QFOverlaySpawnArgument(NSString *argument, BOOL detached) {
    NSString *path = QFOverlayExecutablePath(); if (path.length == 0) return -1;
    for (int attempt = 0; attempt < 2; attempt++) {
        posix_spawnattr_t attr; posix_spawnattr_init(&attr);
        if (detached) { posix_spawnattr_setpgroup(&attr, 0); posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP); }
        if (attempt == 0) QFOverlayApplyPersona(&attr);
        const char *exe = path.UTF8String;
        const char *args[] = { exe, argument.UTF8String, NULL };
        pid_t pid = 0;
        int result = posix_spawn(&pid, exe, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
        if (result == 0) return pid;
        QFOverlayLogF(@"posix_spawn(%@) 第 %d 次失败：%s", argument, attempt+1, strerror(result));
    }
    return -1;
}

@implementation QFOverlayHUD

+ (BOOL)isAvailable { return objc_getClass("SBSAccessibilityWindowHostingController") != NULL; }

static NSArray<NSNumber *> *QFOverlayLiveInstances(void) {
    NSMutableArray<NSNumber *> *alive = [NSMutableArray array];
    NSFileManager *m = [NSFileManager defaultManager];
    for (NSString *name in [m contentsOfDirectoryAtPath:@QFOverlayLedgerDir error:nil]) {
        pid_t pid = (pid_t)name.intValue; if (pid <= 0) continue;
        if (kill(pid, 0) == 0 || errno == EPERM) [alive addObject:@(pid)];
    }
    return alive;
}
static void QFOverlayLedgerRegisterSelf(void) {
    NSFileManager *m = [NSFileManager defaultManager];
    [m createDirectoryAtPath:@QFOverlayLedgerDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *p = [@QFOverlayLedgerDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", getpid()]];
    [[NSString stringWithFormat:@"%.6f", now] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL QFOverlayReapOlderInstances(void) {
    NSFileManager *m = [NSFileManager defaultManager];
    [m createDirectoryAtPath:@QFOverlayLedgerDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    pid_t selfPid = getpid(); NSUInteger killed = 0; BOOL hasTwin = NO;
    for (NSString *name in [m contentsOfDirectoryAtPath:@QFOverlayLedgerDir error:nil]) {
        pid_t pid = (pid_t)name.intValue; if (pid <= 0) { [m removeItemAtPath:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] error:nil]; continue; }
        if (pid == selfPid) continue;
        NSString *content = [NSString stringWithContentsOfFile:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
        double started = content.doubleValue;
        if (started > now) continue;
        if (kill(pid, 0) != 0) { [m removeItemAtPath:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] error:nil]; continue; }
        if (now - started < 3.0) { hasTwin = YES; continue; }   // 同一批兄弟：让位，防进程风暴
        kill(pid, SIGKILL); killed++;
        [m removeItemAtPath:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] error:nil];
    }
    if (killed > 0) QFOverlayLogF(@"清理了 %lu 个旧浮窗实例", (unsigned long)killed);
    if (hasTwin) { QFOverlayLog(@"检测到 3 秒内的兄弟实例，本次让位（防进程风暴）"); return NO; }
    return YES;
}
static NSTimeInterval gLastSpawnAt;
+ (BOOL)spawn {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gLastSpawnAt > 0 && now - gLastSpawnAt < 8.0 && [self isRunning]) { QFOverlayLog(@"8 秒内刚拉起过，跳过"); return YES; }
    if ([self isRunning]) { QFOverlayLog(@"浮窗已在运行，不重复拉起"); return YES; }
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"enabled"] = @YES; QFOverlayPrefWrite(state);   // 先置 enabled，否则子进程会按"关闭"自杀
    // 清掉旧台账/pid 再拉起，避免两个进程抢同一位置
    NSFileManager *m = [NSFileManager defaultManager];
    for (NSString *name in [m contentsOfDirectoryAtPath:@QFOverlayLedgerDir error:nil]) [m removeItemAtPath:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] error:nil];
    unlink(QFOverlayPidPath);
    gLastSpawnAt = now;
    pid_t pid = QFOverlaySpawnArgument(@"-hud", YES);
    if (pid <= 0) { QFOverlayLogF(@"拉起浮窗进程失败，可执行文件=%@", QFOverlayExecutablePath()); return NO; }
    QFOverlayLogF(@"已拉起浮窗进程 pid=%d", pid);
    return YES;
}
+ (void)terminate {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"killAt"] = @([[NSDate date] timeIntervalSince1970]);   // 优先发"结束指令"，子进程自清
    QFOverlayPrefWrite(state);
    notify_post(QFOverlayChangeNotify);
    gLastKillRequestAt = [NSDate timeIntervalSinceReferenceDate];
    NSFileManager *m = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *src = [NSMutableArray array];
    NSString *pidStr = [NSString stringWithContentsOfFile:@QFOverlayPidPath encoding:NSUTF8StringEncoding error:nil];
    if (pidStr.length) [src addObject:pidStr];
    for (NSString *name in [m contentsOfDirectoryAtPath:@QFOverlayLedgerDir error:nil]) [src addObject:name];
    NSUInteger killed = 0, denied = 0;
    for (NSString *s in src) {
        pid_t pid = (pid_t)s.intValue; if (pid <= 0) continue;
        if (kill(pid, SIGKILL) == 0) { int st=0; waitpid(pid, &st, WNOHANG); killed++; }
        else denied++;   // root 进程杀不动，靠指令通道带走
    }
    if (killed) QFOverlayLogF(@"已结束 %lu 个浮窗进程", (unsigned long)killed);
    if (denied) QFOverlayLogF(@"%lu 个进程不接受信号（以 root 运行），已下发结束指令", (unsigned long)denied);
    unlink(QFOverlayPidPath);
    for (NSString *name in [m contentsOfDirectoryAtPath:@QFOverlayLedgerDir error:nil]) [m removeItemAtPath:[@QFOverlayLedgerDir stringByAppendingPathComponent:name] error:nil];
    QFOverlayClearBeat(); QFOverlayWriteRegistered(NO); gLastSpawnAt = 0;
}
+ (BOOL)isRunning {
    for (NSNumber *pid in QFOverlayLiveInstances()) if (pid.intValue > 0) return YES;
    if (QFOverlayBeatAlive(12.0)) return YES;
    NSString *pidStr = [NSString stringWithContentsOfFile:@QFOverlayPidPath encoding:NSUTF8StringEncoding error:nil];
    if (pidStr.length == 0) return NO;
    pid_t pid = (pid_t)pidStr.intValue; if (pid <= 0) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}

#pragma mark - 宿主设置 API

+ (void)setOverlayText:(NSString *)text {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"overlayText"] = text ?: @""; QFOverlayPrefWrite(state);
    notify_post(QFOverlayChangeNotify);
}
+ (void)setEnabled:(BOOL)enabled {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"enabled"] = @(enabled); QFOverlayPrefWrite(state);
    notify_post(QFOverlayChangeNotify);
}
+ (BOOL)isLocked { return [QFOverlayPrefRead()[@"locked"] boolValue]; }
+ (void)setLocked:(BOOL)locked {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"locked"] = @(locked); QFOverlayPrefWrite(state);
    notify_post(QFOverlayChangeNotify);
}
+ (void)resetPosition {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    [state removeObjectForKey:@"nx"]; [state removeObjectForKey:@"ny"];
    [state removeObjectForKey:@"x"]; [state removeObjectForKey:@"y"];
    QFOverlayPrefWrite(state);
    notify_post(QFOverlayResetNotify);
}

#pragma mark - HID 备用通道（窗口由 SpringBoard 合成，普通 UITouch 不一定进来）

static BOOL gDragActive; static CGPoint gDragOffset; static CGPoint gDragStart; static NSTimeInterval gDragStartT; static BOOL gDragMoved2;
static void QFOverlayApplyTouch(CGPoint windowPoint, NSInteger phase) {
    if (!gBar || !gWindow || !gRoot) return;
    if (gGestureEverWorked) return;   // 手势通道已工作，这条备用路让开
    UIView *root = gRoot.view;
    if (phase == 0) {
        CGRect f = [gBar convertRect:gBar.bounds toView:gWindow];
        CGRect area = CGRectInset(f, -12, -12);
        BOOL inside = CGRectContainsPoint(area, windowPoint);
        if (!inside) return;
        CGPoint bp = [root convertPoint:windowPoint fromView:gWindow];
        gDragActive = YES; gDragMoved2 = NO; gLockHintShownThisDrag = NO;
        gDragStart = windowPoint; gDragStartT = [NSDate timeIntervalSinceReferenceDate];
        gDragOffset = CGPointMake(bp.x - gBar.center.x, bp.y - gBar.center.y);
        return;
    }
    if (!gDragActive) return;
    if (phase == 1) {
        if (fabs(windowPoint.x - gDragStart.x) > 6 || fabs(windowPoint.y - gDragStart.y) > 6) gDragMoved2 = YES;
        if (gLocked) { if (gDragMoved2) QFOverlayLockHint(); return; }
        CGPoint bp = [root convertPoint:windowPoint fromView:gWindow];
        gBar.center = CGPointMake(bp.x - gDragOffset.x, bp.y - gDragOffset.y);
        QFOverlayClampBar(); return;
    }
    gDragActive = NO;
    NSTimeInterval dur = [NSDate timeIntervalSinceReferenceDate] - gDragStartT;
    if (!gDragMoved2 && dur < 0.45) { QFOverlayToggleCompact(); }
    else if (!gDragMoved2 && dur >= 0.55) QFOverlayToggleLock();
    else if (gDragMoved2 && !gLocked) QFOverlayLogF(@"HID 拖动结束 → (%.0f,%.0f)", gBar.center.x, gBar.center.y);
    QFOverlayPersistPosition();
}
static void QFOverlayToggleCompact(void) {
    NSMutableDictionary *state = [QFOverlayPrefRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"compact"] = @(![state[@"compact"] boolValue]); QFOverlayPrefWrite(state); QFOverlayRefreshText();
}
+ (void)qf_toggleCompact { QFOverlayToggleCompact(); }
static BOOL QFOverlayBoolMsg(id object, NSString *selName);   // 前向声明
static void QFOverlayEventCallback(void *t, void *rc, void *svc, void *event) {
    @autoreleasepool {
        Class repCls = objc_getClass("AXEventRepresentation");
        if (!repCls || !event) return;
        SEL f = NSSelectorFromString(@"representationWithHIDEvent:hidStreamIdentifier:");
        if (![repCls respondsToSelector:f]) return;
        id rep = ((id (*)(id,SEL,void*,id))objc_msgSend)((id)repCls, f, event, @"UIApplicationEvents");
        if (!rep) return;
        SEL loc = NSSelectorFromString(@"location");
        if (![rep respondsToSelector:loc]) return;
        CGPoint p = ((CGPoint (*)(id,SEL))objc_msgSend)(rep, loc);
        NSInteger phase = -1;
        if (QFOverlayBoolMsg(rep, @"isTouchDown")) phase = 0;
        else if (QFOverlayBoolMsg(rep, @"isMove")) phase = 1;
        else if (QFOverlayBoolMsg(rep, @"isLift") || QFOverlayBoolMsg(rep, @"isInRangeLift")) phase = 2;
        else if (QFOverlayBoolMsg(rep, @"isCancel")) phase = 3;
        if (phase < 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{ QFOverlayApplyTouch(p, phase); });
    }
}
static BOOL QFOverlayBoolMsg(id object, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!object || ![object respondsToSelector:s]) return NO;
    return ((BOOL (*)(id,SEL))objc_msgSend)(object, s);
}

#pragma mark - 事件源装配（触摸通路的必要条件）

@end

@interface QFOverlayApplication : UIApplication @end
@implementation QFOverlayApplication
- (instancetype)init {
    if ((self = [super init])) {
        @try {
            id dispatcher = [self valueForKey:@"eventDispatcher"];
            if (dispatcher) [self qf_install:dispatcher]; else QFOverlayLog(@"eventDispatcher 取不到");
        } @catch (NSException *e) { QFOverlayLogF(@"装事件源抛异常 %@", e); }
    }
    return self;
}
- (BOOL)qf_install:(id)dispatcher {
    CFRunLoopRef rl = CFRunLoopGetMain();
    for (NSString *name in @[@"_installEventRunLoopSources:", @"installEventRunLoopSources:"]) {
        SEL s = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:s]) continue;
        ((void (*)(id,SEL,CFRunLoopRef))objc_msgSend)(dispatcher, s, rl);
        [self qf_attachFetcher:dispatcher]; return YES;
    }
    for (NSString *name in @[@"_installEventRunLoopSources", @"installEventRunLoopSources"]) {
        SEL s = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:s]) continue;
        ((void (*)(id,SEL))objc_msgSend)(dispatcher, s);
        [self qf_attachFetcher:dispatcher]; return YES;
    }
    return NO;
}
- (void)qf_attachFetcher:(id)dispatcher {
    Class fc = objc_getClass("UIEventFetcher"); if (!fc) { QFOverlayLog(@"没有 UIEventFetcher，手势触摸可能收不到，靠 HID 备用通道"); return; }
    id fetcher = [[fc alloc] init];
    [dispatcher setValue:fetcher forKey:@"eventFetcher"];
    SEL sink = NSSelectorFromString(@"setEventFetcherSink:");
    if ([fetcher respondsToSelector:sink]) ((void (*)(id,SEL,id))objc_msgSend)(fetcher, sink, dispatcher);
    else [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
    [self setValue:fetcher forKey:@"eventFetcher"];
    QFOverlayLog(@"eventFetcher 已挂到 dispatcher（UIKit 触摸才进得来）");
}
@end

@interface QFOverlayAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation QFOverlayAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)o {
    QFOverlayLog(@"HUD 代理收到 didFinishLaunching");
    QFOverlayMount();
    self.window = gWindow;
    return YES;
}
@end

#pragma mark - 插件进程入口

@implementation QFOverlayHUD (PluginEntry)

+ (void)runPlugin {
    @autoreleasepool {
        if (QFOverlayLiveInstances().count > 1) {
            NSUInteger stale = 0; for (NSNumber *pid in QFOverlayLiveInstances()) if (pid.intValue != getpid()) stale++;
            if (stale == 0) {/* 旧版孤儿处理省略，保持精简 */ }
        }
        if (!QFOverlayReapOlderInstances()) return;   // 让位：不建窗，直接退出
        QFOverlayLedgerRegisterSelf();
        gStartWall = [[NSDate date] timeIntervalSince1970];
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        [pidStr writeToFile:@QFOverlayPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        QFOverlayLogF(@"浮窗进程启动 pid=%d 实例数=%lu 路径=%@", getpid(), (unsigned long)QFOverlayLiveInstances().count, QFOverlayExecutablePath());
        QFOverlayLogF(@"[权限自检] %@", QFOverlayEntitlementsSummary());

        QFOverlayLoadFrameworks();
        [UIScreen initialize]; CFRunLoopGetCurrent();
        QFOverlayVoidFn GSInitialize = (QFOverlayVoidFn)QFOverlayLookup("GSInitialize");
        QFOverlayVoidFn BKS = (QFOverlayVoidFn)QFOverlayLookup("BKSDisplayServicesStart");
        QFOverlayVoidFn UIAppInit = (QFOverlayVoidFn)QFOverlayLookup("UIApplicationInitialize");
        QFOverlaySingletonFn UIAppSingle = (QFOverlaySingletonFn)QFOverlayLookup("UIApplicationInstantiateSingleton");
        QFOverlayHIDRegisterFn HIDReg = (QFOverlayHIDRegisterFn)QFOverlayLookup("BKSHIDEventRegisterEventCallback");
        QFOverlayUIntFn GSEventInit = (QFOverlayUIntFn)QFOverlayLookup("GSEventInitialize");
        QFOverlayModeFn GSEventPush = (QFOverlayModeFn)QFOverlayLookup("GSEventPushRunLoopMode");
        if (!UIAppInit || !UIAppSingle) { QFOverlayLog(@"UIKit 私有入口取不到，插件模式无法启动"); unlink(QFOverlayPidPath); return; }
        if (GSInitialize) GSInitialize(); else QFOverlayLog(@"GSInitialize 不可用，跳过");
        if (BKS) BKS(); else QFOverlayLog(@"BKSDisplayServicesStart 不可用，跳过");
        UIAppInit();
        UIAppSingle(objc_getClass("QFOverlayApplication"));
        UIApplication *app = [UIApplication sharedApplication];
        app.delegate = [QFOverlayAppDelegate new];
        SEL acc = NSSelectorFromString(@"_accessibilityInit");
        if ([app respondsToSelector:acc]) ((void (*)(id,SEL))objc_msgSend)(app, acc);
        else QFOverlayLog(@"没有 _accessibilityInit，注册窗口大概率失败");
        [NSRunLoop currentRunLoop];
        if (HIDReg) { HIDReg((QFOverlayHIDCallback)QFOverlayEventCallback); QFOverlayLog(@"HID 事件回调已注册"); }
        else QFOverlayLog(@"HID 回调不可用，浮条将不能拖动");
        if (GSEventInit) GSEventInit(0);
        if (GSEventPush) GSEventPush(kCFRunLoopDefaultMode);
        SEL complete = NSSelectorFromString(@"__completeAndRunAsPlugin");
        if ([app respondsToSelector:complete]) ((void (*)(id,SEL))objc_msgSend)(app, complete);
        else { QFOverlayLog(@"没有 __completeAndRunAsPlugin，退化为直接建窗"); QFOverlayMount(); }
        if (!gMounted) { QFOverlayLog(@"didFinishLaunching 未触发，直接建窗"); QFOverlayMount(); }
        CFRunLoopRun();
    }
}

@end
