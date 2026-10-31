// QFHudPlugin.m —— 常驻浮窗的「插件进程」实现（纯 TrollStore，不需要越狱）。
//
// 结构对照 TrollSpeed：
//   主 App  --posix_spawn(self, "-hud", SETPGROUP)-->  插件进程
//   插件进程：GSInitialize → BKSDisplayServicesStart → UIApplicationInitialize
//            → UIApplicationInstantiateSingleton → 装事件 run loop 源
//            → _accessibilityInit → BKSHIDEventRegisterEventCallback
//            → GSEventInitialize → __completeAndRunAsPlugin
//            → 建系统窗口 → registerWindowWithContextID:atLevel: → CFRunLoopRun()
//
// 关键点：这个进程没有 FBScene，也不需要 FBScene。窗口的 CAContext 被交给 SpringBoard 的
// 辅助功能窗口托管层，由 SpringBoard 负责合成，所以退后台 / 回桌面 / 切 App / 锁屏都还在。
//
// 1.4.0 修的三件事：
//   ① 触摸：只注册 HID 回调是不够的，还得把 UIApplication 的 eventDispatcher 的
//      run loop 源装到主 run loop 上（TrollSpeed 的 HUDMainApplication 就是这么做的）。
//      没有这一步，backboardd 送来的事件没人取，回调根本不触发 —— 表现就是「点了没反应」。
//   ② 旋转：窗口交给 SpringBoard 合成后不会再被系统自动旋转。改成自己监听 FBSOrientationObserver，
//      旋转根视图并把 bounds 换成横屏尺寸（和 TrollSpeed 的 updateOrientation 一致）。
//   ③ 透明度：背景色 / 字号 / 显示项全部改成偏好驱动，App 里改完立刻生效。

#import "QFHudPlugin.h"
#import "QFMetrics.h"
#import "../QFShared.h"

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

#define QFHudPidPath "/var/mobile/Library/Caches/com.wacljcr.qfspeed.hud.pid"
// 每个实例在这里留一个 <pid> 文件，内容是自己启动的时间戳。
// 单靠一个 pid 文件管不住多实例：pid 文件被后来的实例覆盖，先前的就变成杀不掉的孤儿。
#define QFHudLedgerDir "/var/mobile/Library/Caches/com.wacljcr.qfspeed.hud.d"
// 10000010 会被 UIKit 钳回 10000000（日志里读回来就是 10000000），
// 说明这个值超出上限，设了也白设。直接写钳制后的值，行为可预期。
#define QFHudWindowLevel 10000000.0

// 默认值：背景半透明、字号 11.5，和 1.3.0 视觉一致但明显更透。
#define QFHudDefaultBgAlpha 0.38
#define QFHudDefaultFontSize 11.5
// 背景不透明度的下限。日志实测 `bg=0.00` 就是这个功能"看起来完全消失"的直接原因：
// 文字还在、窗口也在，只是承载它的一块底色没了。全透明没有使用价值，锁死在 0.18。
#define QFHudMinBgAlpha 0.18

#pragma mark - 私有符号（全部 dlsym，不硬链接私有框架）

static void QFHudLoadFrameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *paths = @[
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            @"/System/Library/Frameworks/UIKit.framework/UIKit",
        ];
        for (NSString *path in paths) {
            dlopen(path.UTF8String, RTLD_NOW);
        }
    });
}

static void *QFHudLookup(const char *symbol) {
    QFHudLoadFrameworks();
    void *pointer = dlsym(RTLD_DEFAULT, symbol);
    if (pointer) return pointer;
    // RTLD_DEFAULT 取不到时逐个 handle 再翻一遍（部分符号不是全局导出的）。
    NSArray<NSString *> *paths = @[
        @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
        @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        @"/System/Library/Frameworks/UIKit.framework/UIKit",
    ];
    for (NSString *path in paths) {
        void *handle = dlopen(path.UTF8String, RTLD_NOW);
        if (!handle) continue;
        pointer = dlsym(handle, symbol);
        if (pointer) return pointer;
    }
    return NULL;
}

typedef void (*QFHudVoidFn)(void);
typedef void (*QFHudUIntFn)(unsigned int);
typedef void (*QFHudModeFn)(CFStringRef);
typedef id (*QFHudSingletonFn)(Class);
typedef void (*QFHudHIDCallback)(void *target, void *refcon, void *service, void *event);
typedef void (*QFHudHIDRegisterFn)(QFHudHIDCallback callback);

#pragma mark - 偏好读取

static inline BOOL QFHudFlag(NSDictionary *state, NSString *key, BOOL fallback) {
    id value = state[key];
    return value ? [value boolValue] : fallback;
}

static inline double QFHudNumber(NSDictionary *state, NSString *key, double fallback) {
    id value = state[key];
    return value ? [value doubleValue] : fallback;
}

#pragma mark - 界面

static double gBarBgAlpha = QFHudDefaultBgAlpha;
static double gBarFontSize = QFHudDefaultFontSize;

static void QFHudHandlePan(UIPanGestureRecognizer *pan);
static void QFHudHandleTap(UITapGestureRecognizer *tap);
static void QFHudHandleLongPress(UILongPressGestureRecognizer *longPress);
static void QFHudToggleLock(void);
static void QFHudFlash(NSString *text, NSTimeInterval seconds);
static void QFHudShake(void);
static void QFHudLockHint(void);
static void QFHudMarkTouchArrived(void);

@interface QFHudBarView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIVisualEffectView *blurView;
- (void)setAttributedText:(NSAttributedString *)text;
- (void)applyBackgroundAlpha:(double)alpha fontSize:(double)fontSize;
@end

@implementation QFHudBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // IPA 样式：胶囊形 + 毛玻璃背景
        self.layer.cornerRadius = frame.size.height / 2.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        self.layer.masksToBounds = YES;
        // 浮条自己吃触摸：窗口的 hitTest 只把它交出来，拖动/点击走 UIKit 手势。
        self.userInteractionEnabled = YES;

        // 毛玻璃底层（Material ultraThin dark 观感）
        _blurView = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 1;
        [self addSubview:_label];
        [self applyBackgroundAlpha:gBarBgAlpha fontSize:gBarFontSize];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(qf_pan:)];
        pan.minimumNumberOfTouches = 1;
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(qf_tap:)];
        tap.numberOfTapsRequired = 1;
        // 拖动过就不算点击，避免松手时误切紧凑/完整。
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(qf_longPress:)];
        longPress.minimumPressDuration = 0.55;
        [self addGestureRecognizer:longPress];
    }
    return self;
}

- (void)qf_pan:(UIPanGestureRecognizer *)pan { QFHudHandlePan(pan); }
- (void)qf_tap:(UITapGestureRecognizer *)tap { QFHudHandleTap(tap); }
- (void)qf_longPress:(UILongPressGestureRecognizer *)longPress { QFHudHandleLongPress(longPress); }

// 触摸真的到达浮条了 —— 比手势识别更早，用来第一时间关掉 HID 备用通道，
// 免得同一次点击既被 HID 处理又被手势处理（各切一次 = 看着像没反应）。
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    QFHudMarkTouchArrived();
}

- (void)applyBackgroundAlpha:(double)alpha fontSize:(double)fontSize {
    alpha = MAX(0.0, MIN(1.0, alpha));
    fontSize = MAX(8.0, MIN(20.0, fontSize));
    gBarBgAlpha = alpha;
    gBarFontSize = fontSize;
    // IPA 毛玻璃样式：blurView 管磨砂，这里叠一层调透明度的深色罩
    self.blurView.alpha = alpha;
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:alpha * 0.55];
    self.layer.borderWidth = alpha > 0.02 ? 0.5 : 0.0;
    self.label.font = [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightSemibold];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 胶囊形：圆角 = 高度一半
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
    self.label.frame = CGRectInset(self.bounds, 14.0, 3.0);
}

- (void)setAttributedText:(NSAttributedString *)text {
    self.label.attributedText = text;
    CGSize fitted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGPoint center = self.center;
    CGRect bounds = self.bounds;
    bounds.size = CGSizeMake(MAX(ceil(fitted.width) + 28.0, 80.0), MAX(ceil(fitted.height) + 8.0, 28.0));
    self.bounds = bounds;
    self.center = center;
    [self setNeedsLayout];
}

@end

@interface QFHudRootController : UIViewController
@end

@implementation QFHudRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
}
// 旋转完全由 QFHudApplyOrientation 手工接管，别让 UIKit 再转一次。
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

#pragma mark - 系统窗口

// 只把浮条那块矩形算作自己的，别的地方一律返回 nil 交还系统 —— 窗口吃触摸但绝不吞全屏。
static UIView *QFHudHitTestBar(CGPoint pointInWindow);

@interface QFHudWindow : UIWindow
@end

// 1.9.0：默认不开 secure 上下文。
// secure 需要 com.apple.QuartzCore.secure-mode 权限，一旦这条权限没被系统认下，
// CAContext 会直接建不出来 —— 窗口对象、hidden、alpha 全都正常，屏幕上什么都没有，
// 而且全程不报错。1.8.x 就是栽在这里。它的唯一作用是"截屏时隐身"，
// 对显示没有任何帮助，反而挡住了唯一的排查手段（截图看不见浮条）。
// 现在改成：默认关；万一某台机器只有 secure 才肯合成，自检会发现 ctx=0 并自动重试一次。
static BOOL gHudSecureContext = NO;

@implementation QFHudWindow

// 自报系统窗口，并声明 CAContext 由自己管 —— 两个条件缺一个，SpringBoard 就不会合成它。
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
// 1.5.0：不再整窗穿透。穿透模式下 UIKit 事件永远进不到浮条，只能靠 HID 伪造触摸，
// 那是"能显示但拖不动"的根源。改成窗口参与命中、但只命中浮条 —— 与 TrollSpeed 一致。
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_isSecure { return gHudSecureContext; }
- (BOOL)_shouldCreateContextAsSecure { return gHudSecureContext; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return QFHudHitTestBar(point);
}

@end

#pragma mark - 状态

static void QFHudClampBar(void);
static void QFHudPersistPosition(void);
static void QFHudRefreshText(void);
static void QFHudApplyPreferences(void);
static NSArray<NSNumber *> *QFHudLiveInstances(void);
static unsigned int QFHudWindowContextId(UIWindow *window);

static QFHudWindow *gHudWindow;
static QFHudRootController *gHudRoot;
static QFHudBarView *gHudBar;
static NSTimer *gHudTimer;
static UIInterfaceOrientation gHudOrientation = UIInterfaceOrientationPortrait;
static UIInterfaceOrientation gHudDeviceOrientation = UIInterfaceOrientationPortrait;
static BOOL gHudOrientationApplied;
static id gHudOrientationObserver;
static CGRect gHudScreenBounds = { { 0, 0 }, { 0, 0 } };
static BOOL gHudMounted;
static BOOL gHudRegistered;
static BOOL gHudOrientationStarted;

static BOOL gHudCompact;
static BOOL gHudShowNetwork = YES;
static BOOL gHudShowCPU = YES;
static BOOL gHudShowMemory = YES;
static BOOL gHudShowBattery = YES;
static BOOL gHudShowFPS = YES;
static BOOL gHudShowVoltage = YES;
static BOOL gHudShowAmpere = YES;
static BOOL gHudShowWatt = YES;
static BOOL gHudShowTemp = YES;
static BOOL gHudFollowRotation = YES;
static BOOL gHudHideInLandscape;
static BOOL gHudLocked;

// 本进程的启动时刻（wall clock，秒）。App 侧写 killAt 时间戳来下"结束指令"，
// 只有晚于这个值的指令才执行 —— 否则刚拉起的新实例会被上一轮的旧指令秒掉。
static NSTimeInterval gHudStartWall;

// 最近一次下发"结束指令"的时刻。App 侧用它判断 HUD 是不是没响应。
static NSTimeInterval gLastKillRequestAt;

static BOOL gDragActive;static CGPoint gDragOffset;
static CGPoint gDragStartWindowPoint;
static NSTimeInterval gDragStartTime;
static BOOL gDragMoved;
static NSTimeInterval gLastTouchLogTime;
static NSUInteger gTouchCounter;

// 手势通道（主路）。只要手势真的收到过一次触摸，就把 HID 那条备用路关掉，免得一次拖动走两遍。
static BOOL gGestureEverWorked;
static CGPoint gGestureBeganCenter;
static BOOL gGestureMoved;

// 锁定提示：浮条上要看得出"锁着"，拖不动时要给出路（长按解锁）。
static NSString *gFlashText;
static NSTimeInterval gFlashUntil;
static BOOL gLockHintShownThisDrag;

#pragma mark - 手势

static void QFHudMarkTouchArrived(void) {
    if (gGestureEverWorked) return;
    gGestureEverWorked = YES;
    QFLogMessage(@"UIKit 触摸已到达浮条，HID 备用通道关闭");
}

// 在浮条上短暂显示一行提示（盖掉指标文字），到点自动恢复。
static void QFHudFlash(NSString *text, NSTimeInterval seconds) {
    gFlashText = text;
    gFlashUntil = [NSDate timeIntervalSinceReferenceDate] + seconds;
    QFHudRefreshText();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([NSDate timeIntervalSinceReferenceDate] >= gFlashUntil) {
            gFlashText = nil;
            QFHudRefreshText();
        }
    });
}

// 锁着的时候拖了一下 —— 抖一下 + 说清楚怎么解锁，别让用户以为是死的。
static void QFHudLockHint(void) {
    if (gLockHintShownThisDrag) return;
    gLockHintShownThisDrag = YES;
    QFHudShake();
    QFHudFlash(@"🔒 位置已锁定 · 长按解锁", 1.6);
    QFLogMessage(@"拖动被锁定拦截，已提示长按解锁");
}

static void QFHudToggleLock(void) {
    gHudLocked = !gHudLocked;
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"locked"] = @(gHudLocked);
    QFPreferencesWrite(state);
    if (gHudLocked) {
        QFHudFlash(@"🔒 位置已锁定", 1.2);
        QFLogMessage(@"HUD 长按 → 锁定位置");
    } else {
        QFHudFlash(@"位置已解锁，可拖动", 1.2);
        QFLogMessage(@"HUD 长按 → 解锁位置");
    }
    QFHudRefreshText();
}

static void QFHudHandlePan(UIPanGestureRecognizer *pan) {
    if (!gHudBar || !gHudRoot) return;
    UIView *root = gHudRoot.view;
    if (!root) return;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            gGestureEverWorked = YES;
            gDragActive = NO;   // 手势接管，HID 那条路正在进行的拖动作废
            gGestureMoved = NO;
            gLockHintShownThisDrag = NO;
            gGestureBeganCenter = gHudBar.center;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [pan translationInView:root];
            if (fabs(translation.x) > 3.0 || fabs(translation.y) > 3.0) gGestureMoved = YES;
            if (gHudLocked) {
                if (gGestureMoved) QFHudLockHint();
                break;
            }
            gHudBar.center = CGPointMake(gGestureBeganCenter.x + translation.x,
                                         gGestureBeganCenter.y + translation.y);
            QFHudClampBar();
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (gGestureMoved && !gHudLocked) {
                QFHudPersistPosition();
                QFLogFormat(@"HUD 拖动结束 → (%.0f,%.0f)", gHudBar.center.x, gHudBar.center.y);
            }
            gGestureMoved = NO;
            break;
        }
        default:
            break;
    }
}

static void QFHudHandleTap(UITapGestureRecognizer *tap) {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    gGestureEverWorked = YES;
    gHudCompact = !gHudCompact;
    QFHudRefreshText();
    QFLogFormat(@"HUD 点击 → %@模式", gHudCompact ? @"紧凑" : @"完整");
}

static void QFHudHandleLongPress(UILongPressGestureRecognizer *longPress) {
    if (longPress.state != UIGestureRecognizerStateBegan) return;
    gGestureEverWorked = YES;
    QFHudToggleLock();
}

static void QFHudShake(void) {
    if (!gHudBar) return;
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[ @0, @-7, @7, @-5, @5, @-2, @2, @0 ];
    shake.duration = 0.35;
    [gHudBar.layer addAnimation:shake forKey:@"qf.shake"];
}

static UIView *QFHudHitTestBar(CGPoint pointInWindow) {
    if (!gHudBar || !gHudRoot || !gHudWindow || gHudBar.hidden) return nil;
    UIView *root = gHudRoot.view;
    if (!root) return nil;
    CGPoint inRoot = [gHudWindow convertPoint:pointInWindow toView:root];
    // 外扩 12pt 做手指容错；其余区域返回 nil，触摸照常落到下面的 App。
    CGRect hit = CGRectInset(gHudBar.frame, -12.0, -12.0);
    if (!CGRectContainsPoint(hit, inRoot)) return nil;
    return gHudBar;
}

#pragma mark - 旋转几何

static CGFloat QFHudOrientationAngle(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        case UIInterfaceOrientationLandscapeLeft:      return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:     return M_PI_2;
        default:                                       return 0.0;
    }
}

static CGRect QFHudOrientationBounds(UIInterfaceOrientation orientation, CGRect bounds) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

static CGRect QFHudRootBounds(void) {
    return gHudRoot ? gHudRoot.view.bounds : gHudScreenBounds;
}

#pragma mark - 位置与文案

static void QFHudClampBar(void) {
    if (!gHudBar) return;
    CGRect bounds = QFHudRootBounds();
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) return;
    CGSize size = gHudBar.bounds.size;
    CGPoint center = gHudBar.center;
    CGFloat halfWidth = size.width / 2.0;
    CGFloat halfHeight = size.height / 2.0;
    center.x = MAX(halfWidth + 6.0, MIN(bounds.size.width - halfWidth - 6.0, center.x));
    center.y = MAX(halfHeight + 6.0, MIN(bounds.size.height - halfHeight - 6.0, center.y));
    gHudBar.center = center;
}

// 位置按「当前方向视图」的归一化比例存，横竖屏来回转都不会跑到屏幕外面去。
static void QFHudPlaceBarFromPreferences(NSDictionary *state) {
    if (!gHudBar) return;
    CGRect bounds = QFHudRootBounds();
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) return;

    double nx = -1.0;
    double ny = -1.0;
    if (state[@"nx"] && state[@"ny"]) {
        nx = QFHudNumber(state, @"nx", -1.0);
        ny = QFHudNumber(state, @"ny", -1.0);
    } else {
        // 兼容 1.3.0 存的绝对坐标（那是竖屏视图坐标）。
        double legacyX = QFHudNumber(state, @"x", -1.0);
        double legacyY = QFHudNumber(state, @"y", -1.0);
        if (legacyX > 1.0 && legacyY > 1.0 &&
            gHudScreenBounds.size.width > 1.0 && gHudScreenBounds.size.height > 1.0) {
            nx = legacyX / gHudScreenBounds.size.width;
            ny = legacyY / gHudScreenBounds.size.height;
        }
    }
    if (nx < 0.0 || nx > 1.0) nx = 0.5;
    if (ny < 0.0 || ny > 1.0) ny = 0.12;

    gHudBar.center = CGPointMake(nx * bounds.size.width, ny * bounds.size.height);
    QFHudClampBar();
}

static void QFHudPersistPosition(void) {
    if (!gHudBar) return;
    CGRect bounds = QFHudRootBounds();
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) return;
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"nx"] = @(gHudBar.center.x / bounds.size.width);
    state[@"ny"] = @(gHudBar.center.y / bounds.size.height);
    state[@"x"] = @(gHudBar.center.x);
    state[@"y"] = @(gHudBar.center.y);
    state[@"compact"] = @(gHudCompact);
    QFPreferencesWrite(state);
}

// IPA 样式：图标 + 数值 归因字符串
static NSAttributedString *QFIconAttrText(NSString *iconName, NSString *text,
                                          NSDictionary *textAttrs, CGFloat fontSize) {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:fontSize * 0.88 weight:UIFontWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:iconName withConfiguration:config];
    if (!icon) {
        return [[NSAttributedString alloc] initWithString:text attributes:textAttrs];
    }
    // 图标用独立的深红色（比文字更深），文字单独用红色
    UIColor *tint = [UIColor colorWithRed:0.72 green:0.08 blue:0.06 alpha:0.95];
    icon = [icon imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = icon;
    CGFloat is = fontSize * 0.92;
    att.bounds = CGRectMake(0, -fontSize * 0.1, is, is);
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:textAttrs]];
    return result;
}

static NSAttributedString *QFHudComposeText(void) {
    QFMetrics *metrics = [QFMetrics shared];
    CGFloat fontSize = gBarFontSize;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:0.98],
    };
    NSDictionary *sepA = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:fontSize * 0.82 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.28],
    };
    NSAttributedString *sep = [[NSAttributedString alloc] initWithString:@"  " attributes:sepA];
    NSMutableArray<NSAttributedString *> *items = [NSMutableArray array];

    if (gHudCompact) {
        if (gHudShowCPU) {
            [items addObject:QFIconAttrText(@"cpu", [NSString stringWithFormat:@"%.0f%%", metrics.cpuPercent], attrs, fontSize)];
        }
        if (gHudShowFPS) {
            [items addObject:QFIconAttrText(@"gauge", [NSString stringWithFormat:@"%.0f", metrics.fps], attrs, fontSize)];
        }
        if (gHudShowNetwork) {
            [items addObject:QFIconAttrText(@"arrow.up", [QFMetrics shortRateText:metrics.uploadRate], attrs, fontSize)];
            [items addObject:QFIconAttrText(@"arrow.down", [QFMetrics shortRateText:metrics.downloadRate], attrs, fontSize)];
        }
        if (gHudShowMemory) {
            [items addObject:QFIconAttrText(@"memorychip", [NSString stringWithFormat:@"%.1fG", metrics.memoryGB], attrs, fontSize)];
        }
        if (gHudShowBattery) {
            [items addObject:QFIconAttrText(@"battery.100", [NSString stringWithFormat:@"%ld%%", (long)metrics.batteryPercent], attrs, fontSize)];
        }
        if (gHudShowVoltage) {
            [items addObject:QFIconAttrText(@"bolt", [NSString stringWithFormat:@"%.2fV", metrics.voltage], attrs, fontSize)];
        }
        if (gHudShowAmpere) {
            [items addObject:QFIconAttrText(@"waveform.path.ecg", [NSString stringWithFormat:@"%.0fmA", metrics.amperage], attrs, fontSize)];
        }
        if (gHudShowWatt) {
            [items addObject:QFIconAttrText(@"bolt.fill", [NSString stringWithFormat:@"%.1fW", metrics.wattage], attrs, fontSize)];
        }
        if (gHudShowTemp) {
            [items addObject:QFIconAttrText(@"thermometer", [NSString stringWithFormat:@"%.1f°C", metrics.temperature], attrs, fontSize)];
        }
    } else {
        if (gHudShowCPU) {
            [items addObject:QFIconAttrText(@"cpu", [NSString stringWithFormat:@"%.0f%%", metrics.cpuPercent], attrs, fontSize)];
        }
        if (gHudShowFPS) {
            [items addObject:QFIconAttrText(@"gauge", [NSString stringWithFormat:@"%.0f", metrics.fps], attrs, fontSize)];
        }
        if (gHudShowNetwork) {
            [items addObject:QFIconAttrText(@"arrow.up", [NSString stringWithFormat:@"%@/s", [QFMetrics shortRateText:metrics.uploadRate]], attrs, fontSize)];
            [items addObject:QFIconAttrText(@"arrow.down", [NSString stringWithFormat:@"%@/s", [QFMetrics shortRateText:metrics.downloadRate]], attrs, fontSize)];
        }
        if (gHudShowMemory) {
            [items addObject:QFIconAttrText(@"memorychip", [NSString stringWithFormat:@"%.1fG", metrics.memoryGB], attrs, fontSize)];
        }
        if (gHudShowBattery) {
            [items addObject:QFIconAttrText(@"battery.100", [NSString stringWithFormat:@"%ld%%", (long)metrics.batteryPercent], attrs, fontSize)];
        }
        if (gHudShowVoltage) {
            [items addObject:QFIconAttrText(@"bolt", [NSString stringWithFormat:@"%.2fV", metrics.voltage], attrs, fontSize)];
        }
        if (gHudShowAmpere) {
            [items addObject:QFIconAttrText(@"waveform.path.ecg", [NSString stringWithFormat:@"%.0fmA", metrics.amperage], attrs, fontSize)];
        }
        if (gHudShowWatt) {
            [items addObject:QFIconAttrText(@"bolt.fill", [NSString stringWithFormat:@"%.1fW", metrics.wattage], attrs, fontSize)];
        }
        if (gHudShowTemp) {
            [items addObject:QFIconAttrText(@"thermometer", [NSString stringWithFormat:@"%.1f°C", metrics.temperature], attrs, fontSize)];
        }
    }
    if (items.count == 0) {
        return [[NSAttributedString alloc] initWithString:@"无显示项" attributes:attrs];
    }
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    for (NSUInteger i = 0; i < items.count; i++) {
        if (i > 0) [result appendAttributedString:sep];
        [result appendAttributedString:items[i]];
    }
    return result;
}

static void QFHudRefreshText(void) {
    if (!gHudBar) return;
    NSDictionary *fa = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:gBarFontSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.96],
    };
    // 提示语期间盖掉指标；锁定时给指标加 🔒 前缀 —— 状态必须一眼看得见。
    if (gFlashText && [NSDate timeIntervalSinceReferenceDate] < gFlashUntil) {
        [gHudBar setAttributedText:[[NSAttributedString alloc] initWithString:gFlashText attributes:fa]];
    } else {
        NSAttributedString *text = QFHudComposeText();
        if (gHudLocked) {
            NSMutableAttributedString *m = [[NSMutableAttributedString alloc] initWithString:@"🔒 " attributes:fa];
            [m appendAttributedString:text];
            text = m;
        }
        [gHudBar setAttributedText:text];
    }
    QFHudClampBar();
}

// 宿主 App 的 bundle 路径：可执行文件在 <App>.app 里面，去掉最后一段就是 bundle。
static NSString *QFHudHostBundlePath(void) {
    static NSString *bundlePath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);
        if (size == 0) return;
        char *buffer = calloc(1, size + 1);
        if (!buffer) return;
        if (_NSGetExecutablePath(buffer, &size) == 0) {
            NSString *executable = [NSString stringWithUTF8String:buffer];
            bundlePath = [executable stringByDeletingLastPathComponent];
        }
        free(buffer);
    });
    return bundlePath;
}

// TrollStore 卸载 App 会把这个目录删掉。浮窗是独立进程，不会跟着死 —— 所以自己盯着。
static BOOL QFHudHostStillInstalled(void) {
    NSString *bundle = QFHudHostBundlePath();
    if (bundle.length == 0) return YES;   // 拿不到就不做判断，别误杀自己
    return [[NSFileManager defaultManager] fileExistsAtPath:bundle];
}

static void QFHudShutdown(NSString *reason) {
    QFLogFormat(@"退出浮窗：%@", reason);
    QFWriteHudRegistered(NO);   // 先告诉 App 侧"常驻没了"，它好把前台兜底浮条顶上
    QFClearHudBeat();           // 心跳清零，App 立刻知道停了，不用等过期
    unlink(QFHudPidPath);   // 别留 pid 文件，否则下次装回来会以为还在跑
    [[NSFileManager defaultManager] removeItemAtPath:
        [@QFHudLedgerDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%d", getpid()]] error:nil];

    UIWindow *window = gHudWindow;
    if (!window) exit(EXIT_SUCCESS);

    // ★ 2.1.1：退出前主动把窗口从 SpringBoard 的合成层摘掉。
    // 现场问题：卸载 App 之后屏幕上还留着一条浮条，要注销 / respring 才消失。
    // 原因是进程虽然退了，CAContext 已经在 SpringBoard 侧注册过，没人注销它，
    // 那一块就成了"冻结的贴图"。所以这里先 unregister，再销毁视图，最后才 exit。
    unsigned int contextId = QFHudWindowContextId(window);
    Class hostClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (contextId != 0 && hostClass) {
        id host = [[hostClass alloc] init];
        // 方法名各系统版本不一样，逐个试，都没有就退化成 hidden + 销毁内容。
        NSArray<NSString *> *candidates = @[ @"unregisterWindowWithContextID:",
                                             @"unregisterWindow:",
                                             @"removeWindowWithContextID:" ];
        for (NSString *name in candidates) {
            SEL selector = NSSelectorFromString(name);
            if (![host respondsToSelector:selector]) continue;
            NSMethodSignature *signature = [host methodSignatureForSelector:selector];
            if (!signature) continue;
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:host];
            [invocation setSelector:selector];
            if (signature.numberOfArguments > 2) {
                // 两个候选的参数类型不同：一个要 unsigned int，一个要对象。按签名长度猜。
                const char *type = [signature getArgumentTypeAtIndex:2];
                if (type && type[0] == '@') {
                    [invocation setArgument:&window atIndex:2];
                } else {
                    [invocation setArgument:&contextId atIndex:2];
                }
            }
            @try {
                [invocation invoke];
                QFLogFormat(@"已注销窗口上下文 ctx=%u 方法=%@", contextId, name);
            } @catch (NSException *exception) {
                QFLogFormat(@"注销窗口上下文抛异常 %@", exception);
            }
            break;
        }
    }

    gHudWindow = nil;
    gHudBar = nil;
    gHudRoot = nil;
    window.hidden = YES;
    window.alpha = 0.0;
    window.rootViewController = nil;
    [window removeFromSuperview];

    [UIView animateWithDuration:0.15 animations:^{
        window.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        exit(EXIT_SUCCESS);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(EXIT_SUCCESS);   // 动画没回调也要退
    });
}

// 当前生效配置的指纹。用于"配置变了就重读"，不依赖通知能不能送到。
static NSString *QFHudConfigDigest(NSDictionary *state) {
    return [NSString stringWithFormat:@"c%d n%d cpu%d mem%d bat%d fps%d v%d a%d w%d t%d rot%d hide%d lock%d a%.2f f%.1f",
            [state[@"compact"] boolValue],
            QFHudFlag(state, @"showNetwork", YES),
            QFHudFlag(state, @"showCPU", YES),
            QFHudFlag(state, @"showMemory", YES),
            QFHudFlag(state, @"showBattery", YES),
            QFHudFlag(state, @"showFPS", YES),
            QFHudFlag(state, @"showVoltage", YES),
            QFHudFlag(state, @"showAmpere", YES),
            QFHudFlag(state, @"showWatt", YES),
            QFHudFlag(state, @"showTemp", YES),
            QFHudFlag(state, @"followRotation", YES),
            QFHudFlag(state, @"hideInLandscape", NO),
            QFHudFlag(state, @"locked", NO),
            QFHudNumber(state, @"bgAlpha", QFHudDefaultBgAlpha),
            QFHudNumber(state, @"fontSize", QFHudDefaultFontSize)];
}

// 配置轮询（0.25 秒一次，另有 Darwin 通知做即时触发）。
//
// 这里刻意不写"值变了才应用"：一旦读到的还是旧字典，digest 就不会变，
// 应用逻辑永远不跑 —— 现场就是"通知收到了、界面不动"。
// 每拍无条件重推一次，属性赋同值本来就不产生重绘，成本可以忽略，
// 换来的是这条链路没有任何"条件"可以失效。
static void QFHudPollPreferences(void) {
    static NSString *appliedDigest;
    static BOOL sawEnabledOnce;

    NSDictionary *latest = QFPreferencesRead();

    // ★ 2.1.6：结束指令。
    //
    // 为什么不再靠 kill：HUD 是 App 用 posix_spawn 以 **uid=0** 拉起的（见 QFHudApplyPersona），
    // App 自己是 mobile。向 root 进程发 SIGKILL 必然 EPERM —— 真机日志里
    // "已结束 HUD 进程 pid=96595" 之后还跟着两次它的心跳，就是这个原因。
    // 所以改成"指令自杀"：App 写一个 killAt 时间戳，我读到就自己走 QFHudShutdown，
    // 顺带把 CAContext 注销掉，比硬杀干净得多。
    //
    // 只认"晚于我启动时间"的指令，否则新拉起的实例会被上一轮的旧时间戳秒掉。
    // 容差不给：QFHudSpawn 内部会先写 killAt 再立刻 spawn，新进程的启动时间一定更晚；
    // 反过来给个 -1 秒的宽容，等于把"刚被自己拉起的新实例"也一起杀了。
    double killAt = [latest[@"killAt"] doubleValue];
    if (killAt > 0 && gHudStartWall > 0 && killAt > gHudStartWall) {
        QFHudShutdown(@"收到 App 的结束指令");
        return;
    }

    // ★ 2.1.5：App 里按「关闭常驻浮窗」会写 enabled=0，这里自己收摊。
    //
    // 父进程 SIGKILL 也能把浮条弄没，但那是硬杀：进程来不及注销 CAContext、
    // 来不及清心跳和台账。屏幕上会留一块"冻结的贴图"，要把 App 卸载再 respring 才干净
    // —— 就是用户骂的那句"流氓"。自己走 QFHudShutdown 则一步到位。
    //
    // 判定条件放宽成两条任意满足：
    //   ① 曾经见过 enabled=1（正常流程，最准）；
    //   ② 已经跑满 4 秒（兜住"启动时偏好里还没有 enable 键"的情况）。
    // 只有"键存在且为 0"才算关闭；键不存在时不动，避免老版本/交接实例被误杀。
    id enabledFlag = latest[@"enabled"];
    BOOL explicitlyOff = enabledFlag != nil && ![enabledFlag boolValue];
    BOOL oldEnough = gHudStartWall > 0 &&
                     ([[NSDate date] timeIntervalSince1970] - gHudStartWall > 4.0);
    if (explicitlyOff && (sawEnabledOnce || oldEnough)) {
        QFHudShutdown(@"App 侧关闭了常驻浮窗");
        return;
    }
    if ([enabledFlag boolValue]) sawEnabledOnce = YES;

    NSString *digest = QFHudConfigDigest(latest);
    BOOL changed = (appliedDigest.length > 0) && ![digest isEqualToString:appliedDigest];
    appliedDigest = digest;
    if (!gHudBar) return;
    QFHudApplyPreferences();
    if (changed) QFLogFormat(@"配置已更新 %@", digest);
}

static void QFHudTick(void) {
    @autoreleasepool {
        [[QFMetrics shared] sample];
        QFHudRefreshText();

        static NSUInteger tickCount;
        static NSString *appliedDigest;
        tickCount++;

        QFHudPollPreferences();
        // 卸载检测：每拍都查，不再每 5 秒。
        // 用户卸载 App 之后，浮条会一直挂在屏幕上（进程还在内存里跑），
        // 得等注销 / 重启才消失 —— 这是最"流氓"的那种残留。
        // 每秒查一次，检测到就立刻摘窗口再退出，最多留 1 秒。
        if (!QFHudHostStillInstalled()) {
            QFHudShutdown(@"宿主 App 已被卸载");
            return;
        }
        // 心跳落盘（跨进程）：App 侧判断"浮窗在不在跑"靠它，不再只靠 kill 探活。
        QFWriteHudBeat();
        // 心跳：再出现"什么都没有"的时候，这一行能一次说清全部关键点。
        // ctx=0        → 窗口没拿到 CAContext（secure 上下文建不出来）
        // 注册=0       → SpringBoard 没收（权限问题）
        // 条=0x0 或 空 → UI 层面就是空的，跟合成无关
        if (tickCount % 30 == 0) {
            QFLogFormat(@"心跳 pid=%d hidden=%d alpha=%.2f ctx=%u 注册=%d 键窗=%d 条=%.0fx%.0f@(%.0f,%.0f) bg=%.2f 文字=\"%@\" 实例=%lu",
                        getpid(), gHudWindow.hidden, gHudWindow.alpha,
                        QFHudWindowContextId(gHudWindow),
                        gHudRegistered ? 1 : 0,
                        gHudWindow.isKeyWindow ? 1 : 0,
                        gHudBar.bounds.size.width, gHudBar.bounds.size.height,
                        gHudBar.center.x, gHudBar.center.y,
                        gBarBgAlpha, gHudBar.label.text ?: @"",
                        (unsigned long)QFHudLiveInstances().count);
            // 顺便把注册结果续一次：App 侧靠这个键决定前台要不要出兜底浮条，
            // 键要是过期了，App 就会以为常驻挂了、多画一条出来。
            QFWriteHudRegistered(gHudRegistered);
        }
    }
}

#pragma mark - 方向

static void QFHudApplyOrientation(UIInterfaceOrientation orientation, NSTimeInterval duration);

static void QFHudStartOrientationObserver(void) {
    // 注册失败会重建窗口，重建后又会调到这里 —— 别把观察者叠成两份。
    if (gHudOrientationStarted) return;
    gHudOrientationStarted = YES;

    QFHudLoadFrameworks();

    Class observerClass = objc_getClass("FBSOrientationObserver");
    if (observerClass) {
        id observer = [[observerClass alloc] init];
        SEL handlerSelector = NSSelectorFromString(@"setHandler:");
        if (observer && [observer respondsToSelector:handlerSelector]) {
            void (^handler)(id) = ^(id update) {
                NSInteger value = 0;
                double duration = 0.25;
                @try {
                    value = [[update valueForKey:@"orientation"] integerValue];
                    duration = [[update valueForKey:@"duration"] doubleValue];
                } @catch (__unused NSException *exception) {
                }
                UIInterfaceOrientation orientation = (UIInterfaceOrientation)value;
                dispatch_async(dispatch_get_main_queue(), ^{
                    QFHudApplyOrientation(orientation, duration);
                });
            };
            ((void (*)(id, SEL, id))objc_msgSend)(observer, handlerSelector, handler);
            gHudOrientationObserver = observer;   // 全局持有，否则 handler 随对象一起没了
            QFLogMessage(@"已挂 FBSOrientationObserver，浮条会跟着屏幕旋转");

            SEL activeSelector = NSSelectorFromString(@"activeOrientation");
            if ([observer respondsToSelector:activeSelector]) {
                NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(observer, activeSelector);
                if (value != 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        QFHudApplyOrientation((UIInterfaceOrientation)value, 0.0);
                    });
                }
            }
            return;
        }
    }

    // 兜底：没有 FBSOrientationObserver 就退回设备方向通知（某些系统上插件进程收不到，聊胜于无）。
    QFLogMessage(@"FBSOrientationObserver 不可用，退回 UIDevice 方向通知");
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
        switch ([UIDevice currentDevice].orientation) {
            case UIDeviceOrientationLandscapeLeft:  orientation = UIInterfaceOrientationLandscapeRight; break;
            case UIDeviceOrientationLandscapeRight: orientation = UIInterfaceOrientationLandscapeLeft;  break;
            case UIDeviceOrientationPortraitUpsideDown: orientation = UIInterfaceOrientationPortraitUpsideDown; break;
            default: orientation = UIInterfaceOrientationPortrait; break;
        }
        QFHudApplyOrientation(orientation, 0.25);
    }];
}

static void QFHudApplyOrientation(UIInterfaceOrientation orientation, NSTimeInterval duration) {
    if (!gHudWindow || !gHudRoot || !gHudBar) return;
    if (orientation == UIInterfaceOrientationUnknown) orientation = UIInterfaceOrientationPortrait;
    gHudDeviceOrientation = orientation;

    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    if (!gHudFollowRotation && landscape) {
        // 不跟随：横屏时保持竖屏排版，宁可侧着看也不让字倒过来（用户可换成"横屏隐藏"）。
        if (gHudHideInLandscape) {
            gHudBar.hidden = YES;
            gHudOrientation = orientation;
            gHudOrientationApplied = YES;
            QFLogFormat(@"屏幕转为横屏（不跟随），浮条隐藏");
            return;
        }
        orientation = UIInterfaceOrientationPortrait;
    }

    gHudBar.hidden = (gHudHideInLandscape && landscape);

    if (gHudOrientationApplied && orientation == gHudOrientation) return;
    gHudOrientation = orientation;
    gHudOrientationApplied = YES;

    CGRect bounds = QFHudOrientationBounds(orientation, gHudScreenBounds);
    UIView *root = gHudRoot.view;
    CGPoint center = CGPointMake(CGRectGetMidX(gHudWindow.bounds), CGRectGetMidY(gHudWindow.bounds));

    root.transform = CGAffineTransformIdentity;
    root.bounds = bounds;
    root.center = center;

    // 换完坐标系按归一化位置重新落点，避免浮条跑到屏幕外。
    QFHudPlaceBarFromPreferences(QFPreferencesRead());

    __weak UIView *weakRoot = root;
    [UIView animateWithDuration:(duration > 0.01 ? duration : 0.25)
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        weakRoot.transform = CGAffineTransformMakeRotation(QFHudOrientationAngle(orientation));
    } completion:nil];

    QFLogFormat(@"方向切换为 %ld（%@）视图尺寸 %.0fx%.0f",
                (long)orientation, landscape ? @"横屏" : @"竖屏",
                bounds.size.width, bounds.size.height);
}

#pragma mark - HID 触摸（窗口由 SpringBoard 合成，普通 UITouch 不会进来）

static Class QFHudAXEventClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        QFHudLoadFrameworks();
        cls = objc_getClass("AXEventRepresentation");
    });
    return cls;
}

static BOOL QFHudBoolMessage(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void QFHudApplyTouch(CGPoint windowPoint, NSInteger phase) {
    // phase: 0=down 1=move 2=up 3=cancel
    if (!gHudBar || !gHudWindow || !gHudRoot) return;
    // 手势通道已经能收到触摸了，这条 HID 备用路就让开，否则一次拖动会被处理两遍。
    if (gGestureEverWorked) return;
    UIView *root = gHudRoot.view;

    if (phase == 0) {
        CGRect frameInWindow = [gHudBar convertRect:gHudBar.bounds toView:gHudWindow];
        CGRect hitArea = CGRectInset(frameInWindow, -12.0, -12.0);
        BOOL inside = CGRectContainsPoint(hitArea, windowPoint);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gTouchCounter < 12 || now - gLastTouchLogTime > 2.0) {
            gLastTouchLogTime = now;
            QFLogFormat(@"触摸 down (%.0f,%.0f) 命中区 (%.0f,%.0f,%.0f,%.0f) %@",
                        windowPoint.x, windowPoint.y,
                        hitArea.origin.x, hitArea.origin.y, hitArea.size.width, hitArea.size.height,
                        inside ? @"命中" : @"未命中");
        }
        gTouchCounter++;
        if (!inside) return;
        CGPoint barPoint = [root convertPoint:windowPoint fromView:gHudWindow];
        gDragActive = YES;
        gDragMoved = NO;
        gLockHintShownThisDrag = NO;
        gDragStartWindowPoint = windowPoint;
        gDragStartTime = now;
        gDragOffset = CGPointMake(barPoint.x - gHudBar.center.x, barPoint.y - gHudBar.center.y);
        return;
    }

    if (!gDragActive) return;

    if (phase == 1) {
        if (fabs(windowPoint.x - gDragStartWindowPoint.x) > 6.0 ||
            fabs(windowPoint.y - gDragStartWindowPoint.y) > 6.0) {
            gDragMoved = YES;
        }
        if (gHudLocked) {
            if (gDragMoved) QFHudLockHint();
            return;
        }
        CGPoint barPoint = [root convertPoint:windowPoint fromView:gHudWindow];
        gHudBar.center = CGPointMake(barPoint.x - gDragOffset.x, barPoint.y - gDragOffset.y);
        QFHudClampBar();
        return;
    }

    // up / cancel
    gDragActive = NO;
    NSTimeInterval duration = [NSDate timeIntervalSinceReferenceDate] - gDragStartTime;
    if (!gDragMoved && duration < 0.45) {
        gHudCompact = !gHudCompact;
        QFHudRefreshText();
        QFLogFormat(@"HUD 点击 → %@模式", gHudCompact ? @"紧凑" : @"完整");
    } else if (!gDragMoved && duration >= 0.55) {
        // HID 通道没有手势识别器，按住不动 ≥0.55 秒当作长按：切换锁定。
        QFHudToggleLock();
    } else if (gDragMoved && !gHudLocked) {
        QFLogFormat(@"HUD 拖动结束 → (%.0f,%.0f)", gHudBar.center.x, gHudBar.center.y);
    }
    QFHudPersistPosition();
}

static void QFHudEventCallback(void *target, void *refcon, void *service, void *event) {
    @autoreleasepool {
        Class repClass = QFHudAXEventClass();
        if (!repClass || !event) return;

        SEL factory = NSSelectorFromString(@"representationWithHIDEvent:hidStreamIdentifier:");
        if (![repClass respondsToSelector:factory]) return;
        id representation = ((id (*)(id, SEL, void *, id))objc_msgSend)((id)repClass, factory,
                                                                      event, @"UIApplicationEvents");
        if (!representation) return;

        SEL locationSelector = NSSelectorFromString(@"location");
        if (![representation respondsToSelector:locationSelector]) return;
        CGPoint point = ((CGPoint (*)(id, SEL))objc_msgSend)(representation, locationSelector);

        NSInteger phase = -1;
        if (QFHudBoolMessage(representation, @"isTouchDown")) phase = 0;
        else if (QFHudBoolMessage(representation, @"isMove")) phase = 1;
        else if (QFHudBoolMessage(representation, @"isLift") ||
                 QFHudBoolMessage(representation, @"isInRangeLift")) phase = 2;
        else if (QFHudBoolMessage(representation, @"isCancel")) phase = 3;
        if (phase < 0) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            QFHudApplyTouch(point, phase);
        });
    }
}

#pragma mark - 建窗 + 注册到 SpringBoard

static unsigned int QFHudWindowContextId(UIWindow *window) {
    unsigned int contextId = 0;
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:contextSelector]) {
        NSMethodSignature *signature = [window methodSignatureForSelector:contextSelector];
        if (signature) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:window];
            [invocation setSelector:contextSelector];
            [invocation invoke];
            if (signature.methodReturnLength >= (NSUInteger)sizeof(unsigned int)) {
                [invocation getReturnValue:&contextId];
            }
        }
    }
    if (contextId == 0) {
        @try {
            contextId = (unsigned int)[[window valueForKey:@"_contextId"] unsignedIntValue];
        } @catch (__unused NSException *exception) {
        }
    }
    return contextId;
}

static BOOL QFHudRegisterWindow(UIWindow *window) {
    Class hostClass = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostClass) {
        QFLogMessage(@"未找到 SBSAccessibilityWindowHostingController，无法注册窗口");
        return NO;
    }

    unsigned int contextId = QFHudWindowContextId(window);
    if (contextId == 0) {
        // 这一行是"屏幕空白"的第一嫌疑人：窗口根本没拿到 CAContext。
        // 常见原因就是 secure 上下文建不起来（secure-mode 权限不认）。
        QFLogFormat(@"拿不到窗口的 _contextId（窗口没拿到 CAContext），注册中止 secure=%d",
                    gHudSecureContext ? 1 : 0);
        return NO;
    }

    double level = window.windowLevel;

    // ★ 1.9.0 第二个关键修复：托管控制器必须一直被强引用住。
    // 以前这里是局部变量 `id host = [[hostClass alloc] init]`，注册完函数返回，
    // ARC 立刻把它释放 —— 而 SBSAccessibilityWindowHostingController 一销毁，
    // 它替我们托管的窗口也跟着从 SpringBoard 那边撤掉。
    // 现象就是"注册成功的日志打了，屏幕上还是什么都没有"。TrollSpeed 用实例变量持有它。
    static id host;
    if (!host) host = [[hostClass alloc] init];
    if (!host) {
        QFLogMessage(@"SBSAccessibilityWindowHostingController 创建失败");
        return NO;
    }

    // 私有方法，参数是 unsigned int + double，返回 void：v@:Id
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:host];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&contextId atIndex:2];
    [invocation setArgument:&level atIndex:3];
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        QFLogFormat(@"注册窗口抛异常 %@", exception);
        return NO;
    }

    QFLogFormat(@"窗口已交给 SpringBoard 合成 ctx=%u level=%.0f secure=%d",
                contextId, level, gHudSecureContext ? 1 : 0);
    return YES;
}

// 偏好变化就重读一遍：显示项、紧凑、透明度、字号、旋转开关全都实时生效。
static void QFHudApplyPreferences(void) {
    NSDictionary *state = QFPreferencesRead();

    // 一次性迁移：≤1.6 的浮条上既看不出锁定状态也没有解锁入口，
    // 用户留下的 locked=1 就是"莫名拖不动"。升级后先自动解锁一次（只做一次，之后尊重用户选择）。
    if (![state[@"lockMigrated"] boolValue]) {
        NSMutableDictionary *migrated = [state mutableCopy] ?: [NSMutableDictionary dictionary];
        if ([migrated[@"locked"] boolValue]) {
            migrated[@"locked"] = @NO;
            QFLogMessage(@"已自动解除遗留的位置锁定（浮条上长按可再锁）");
        }
        migrated[@"lockMigrated"] = @YES;
        QFPreferencesWrite(migrated);
        state = migrated;
    }

    gHudCompact = [state[@"compact"] boolValue];
    gHudShowNetwork = QFHudFlag(state, @"showNetwork", YES);
    gHudShowCPU = QFHudFlag(state, @"showCPU", YES);
    gHudShowMemory = QFHudFlag(state, @"showMemory", YES);
    gHudShowBattery = QFHudFlag(state, @"showBattery", YES);
    gHudShowFPS = QFHudFlag(state, @"showFPS", YES);
    gHudShowVoltage = QFHudFlag(state, @"showVoltage", YES);
    gHudShowAmpere = QFHudFlag(state, @"showAmpere", YES);
    gHudShowWatt = QFHudFlag(state, @"showWatt", YES);
    gHudShowTemp = QFHudFlag(state, @"showTemp", YES);
    gHudFollowRotation = QFHudFlag(state, @"followRotation", YES);
    gHudHideInLandscape = QFHudFlag(state, @"hideInLandscape", NO);
    gHudLocked = QFHudFlag(state, @"locked", NO);

    double alpha = QFHudNumber(state, @"bgAlpha", QFHudDefaultBgAlpha);
    double fontSize = QFHudNumber(state, @"fontSize", QFHudDefaultFontSize);

    // ★ 2.0.2：背景不透明度设下限。
    // 现场日志第一次把真相打出来：`barAlpha=1.00 bg=0.00 文字="↓0B ↑0B"` ——
    // 浮条一直在屏幕上、位置尺寸都对、白色文字也在，但背景 alpha 是 0，
    // 73×22 的白字浮在桌面上就是"什么都没有"。用户把滑杆拉到底就等于把浮条删掉了。
    //
    // 读到 0 说明是老版本留下的值（那会儿滑杆允许全透明），直接回到默认 0.38，
    // 而不是掐到 0.18 —— 用户此刻要的是"能看见"，不是"勉强能看见"。
    if (alpha < QFHudMinBgAlpha) alpha = QFHudDefaultBgAlpha;
    alpha = MIN(1.0, alpha);

    if (gHudBar) {
        [gHudBar applyBackgroundAlpha:alpha fontSize:fontSize];
        gHudBar.hidden = (gHudHideInLandscape && UIInterfaceOrientationIsLandscape(gHudOrientation));
        QFHudRefreshText();
    }

    // 旋转相关的开关变了就直接重排一次，否则要等用户再转一次屏才生效。
    static BOOL previousFollow = YES;
    static BOOL previousHide = NO;
    if (previousFollow != gHudFollowRotation || previousHide != gHudHideInLandscape) {
        previousFollow = gHudFollowRotation;
        previousHide = gHudHideInLandscape;
        gHudOrientationApplied = NO;
        QFHudApplyOrientation(gHudDeviceOrientation, 0.2);
    }
}

// 只负责「建窗 + 注册」，返回是否注册成功。为什么单独拆出来：失败要能整窗销毁重来一次。
static BOOL QFHudCreateWindowAndRegister(BOOL secure) {
    gHudSecureContext = secure;

    QFHudWindow *window = [[QFHudWindow alloc] initWithFrame:gHudScreenBounds];
    QFHudRootController *controller = [QFHudRootController new];
    QFHudBarView *bar = [[QFHudBarView alloc] initWithFrame:CGRectMake(0, 0, 220, 24)];

    gHudWindow = window;
    gHudRoot = controller;
    gHudBar = bar;

    // ★ 顺序严格照抄 TrollSpeed 的 HUDMainApplicationDelegate：
    //   alloc/init → 交给 delegate 的 window 属性 → rootViewController → setWindowLevel
    //   → setHidden:NO → makeKeyAndVisible → 建 host controller → registerWindowWithContextID:atLevel:
    //
    // 这一步「交给 delegate」必须在 makeKeyAndVisible 之前。
    // makeKeyAndVisible 只有在窗口已经归属 UIApplication 时才真的把窗口挂上去；
    // 顺序反了（先 makeKey 再交给 delegate）它就是空转 —— 窗口对象各项参数全对，
    // SpringBoard 那边却没有任何东西可合成，屏幕一片空白且不报错。
    // 这个坑在 1.9.0 埋过一次：当时确实写在 makeKey 之前，但 2.0.0 一度误删，现恢复。
    id appDelegate = (id)[UIApplication sharedApplication].delegate;
    if (appDelegate) {
        @try {
            [appDelegate setValue:window forKey:@"window"];
        } @catch (__unused NSException *exception) {
            QFLogFormat(@"delegate.window 赋值抛异常 %@", exception);
        }
    }

    window.windowLevel = QFHudWindowLevel;
    // 三层都要彻底透明：窗口背景、窗口 layer、根视图。少一处就会看到一块黑底。
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.layer.opaque = NO;
    window.layer.backgroundColor = UIColor.clearColor.CGColor;

    // ★ 2.0.2：图层缩放必须手动给成屏幕的 scale。
    // 现场日志里 `layer=390x844 scale=1.00` —— 而 iPhone 12 Pro 是 3.00。
    // plugin 进程没有 windowScene，UIKit 不会自动把 contentsScale 继承过来，
    // 于是整个窗口按 1x 光栅化：390×844 像素铺满 1170×2532 的物理屏，
    // 字被放大三倍后又糊又淡，白色细字在浅色壁纸上基本等于隐形。
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 1.0) scale = 3.0;
    window.layer.contentsScale = scale;
    controller.view.contentScaleFactor = scale;
    controller.view.layer.contentsScale = scale;

    window.rootViewController = controller;
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.frame = window.bounds;
    [controller.view addSubview:bar];

    // 先把内容摆好再让它可见：反过来会有一帧空白，某些系统版本上那一帧会被
    // SpringBoard 当成"空窗口"记录下来，之后一直不重绘。
    NSDictionary *state = QFPreferencesRead();
    QFHudApplyPreferences();
    QFHudPlaceBarFromPreferences(state);
    [[QFMetrics shared] sample];
    QFHudRefreshText();

    window.hidden = NO;
    [window makeKeyAndVisible];
    [window layoutIfNeeded];

    BOOL registered = QFHudRegisterWindow(window);
    gHudRegistered = registered;
    return registered;
}

static void QFHudTeardownWindow(void) {
    if (gHudWindow) {
        @try {
            gHudWindow.hidden = YES;
            gHudWindow.rootViewController = nil;
        } @catch (__unused NSException *exception) {
        }
    }
    gHudWindow = nil;
    gHudRoot = nil;
    gHudBar = nil;
    gHudMounted = NO;
    gHudRegistered = NO;
    gHudOrientationApplied = NO;
}

static void QFHudMount(void) {
    if (gHudMounted && gHudWindow) return;

    // 屏幕信息要说清楚是"读到的"还是"猜的"。以前这里读到 0x0 就静默用 390x844 兜底，
    // 日志里看到 390x844 根本分不清是真的还是兜的 —— 而 plugin 进程读不到屏幕，
    // 意味着这块 CAContext 没有正确尺寸，窗口建出来也是空的。
    UIScreen *screen = [UIScreen mainScreen];
    CGRect rawBounds = screen ? screen.bounds : CGRectZero;
    QFLogFormat(@"屏幕自检 UIScreen=%@ bounds=%.0fx%.0f scale=%.2f nativeScale=%.2f",
                screen ? NSStringFromClass(screen.class) : @"nil",
                rawBounds.size.width, rawBounds.size.height,
                screen ? screen.scale : -1.0, screen ? screen.nativeScale : -1.0);

    gHudScreenBounds = rawBounds;
    if (gHudScreenBounds.size.width < 1.0 || gHudScreenBounds.size.height < 1.0) {
        gHudScreenBounds = CGRectMake(0, 0, 390, 844);
        QFLogMessage(@"屏幕读到 0x0，改用兜底尺寸 390x844");
    }

    // ★ 2.0.1：改回「先非 secure」。
    // 上一版先 secure（对齐 TrollSpeed），日志证明 ctx 能拿到、注册也成功（secure=1），
    // 说明 secure 上下文在这台机器上完全建得出来 —— 它不是瓶颈。
    // 而 secure 窗口进不了截屏，等于把唯一的自证手段封了：你看不到浮条，也无法截图证明它到底在不在。
    // 现在先非 secure：能截屏、能录屏、能自己确认。真出了 ctx=0 再自动升到 secure 重试一次。
    BOOL registered = QFHudCreateWindowAndRegister(NO);
    gHudMounted = YES;
    QFWriteHudRegistered(registered);

    QFLogFormat(@"HUD 已挂载 屏幕=%.0fx%.0f 位置=(%.0f,%.0f) 注册=%@ ctx=%u",
                gHudScreenBounds.size.width, gHudScreenBounds.size.height,
                gHudBar.center.x, gHudBar.center.y, registered ? @"成功" : @"失败",
                QFHudWindowContextId(gHudWindow));

    // 窗口内部的真实状态。前 8 个版本只能看到"窗口对象没毛病"，
    // 但这些值才是决定"看不看得见"的那一层：layer 有没有尺寸、有没有被光栅化、
    // 浮条背景 alpha 是不是被设置成 0、文字是不是空的。
    QFLogFormat(@"窗口自检 layer=%.0fx%.0f scale=%.2f 子层=%lu 根子视图=%lu "
                @"条=%.0fx%.0f barAlpha=%.2f bg=%.2f 文字=\"%@\"",
                gHudWindow.layer.bounds.size.width, gHudWindow.layer.bounds.size.height,
                gHudWindow.layer.contentsScale,
                (unsigned long)gHudWindow.layer.sublayers.count,
                (unsigned long)gHudRoot.view.subviews.count,
                gHudBar.bounds.size.width, gHudBar.bounds.size.height,
                gHudBar.alpha, gBarBgAlpha, gHudBar.label.text ?: @"");

    // 这一行是排查的起点：如果 winHosting=✗ 或 系统目录=不可写，
    // 那后面怎么写代码都没用，问题在签名上 —— 权限根本没被系统认下来。
    QFLogFormat(@"[权限自检] %@", QFEntitlementsSummary());
    if (!QFHasEntitlement(@"com.apple.springboard.accessibility-window-hosting")) {
        QFLogMessage(@"[权限自检] 缺少 accessibility-window-hosting，SpringBoard 会直接丢弃我们注册的窗口");
    }

    // 方向：先挂监听，再按当前方向压一次，保证横屏启动时也是正的。
    QFHudStartOrientationObserver();

    if (gHudTimer) [gHudTimer invalidate];
    gHudTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        QFHudTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gHudTimer forMode:NSRunLoopCommonModes];

    // ★ 2.1.4：配置单独用 0.25 秒的节拍盯。
    // 指标采样（CPU / 内存）留在 1 秒的 tick 里，避免四倍开销；
    // 开关这种"点完必须立刻看到"的东西，最坏 0.25 秒也必须落地。
    static NSTimer *configTimer;
    if (configTimer) [configTimer invalidate];
    configTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        QFHudPollPreferences();
    }];
    [[NSRunLoop mainRunLoop] addTimer:configTimer forMode:NSRunLoopCommonModes];

    // App 改设置 → 这里立刻生效；重置位置也走同一条通道。
    static int changeToken;
    notify_register_dispatch(QFChangeNotification, &changeToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        QFHudPollPreferences();
        QFLogMessage(@"收到设置变更，已即时应用");
    });
    static int resetToken;
    notify_register_dispatch(QFResetNotification, &resetToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        NSDictionary *latest = QFPreferencesRead();
        [gHudBar applyBackgroundAlpha:QFHudNumber(latest, @"bgAlpha", QFHudDefaultBgAlpha)
                             fontSize:QFHudNumber(latest, @"fontSize", QFHudDefaultFontSize)];
        QFHudPlaceBarFromPreferences(latest);
        QFLogMessage(@"收到重置位置");
    });

    // 注册失败（尤其是 ctx=0）→ 整窗销毁，换 secure 上下文再试一次，然后放弃并说清楚原因。
    if (!registered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            QFLogMessage(@"第一次注册失败，改用 secure 上下文重建一次");
            QFHudTeardownWindow();
            BOOL retried = QFHudCreateWindowAndRegister(YES);
            gHudMounted = YES;
            QFWriteHudRegistered(retried);
            QFLogFormat(@"重建完成（secure=1）注册=%@ ctx=%u",
                        retried ? @"成功" : @"失败", QFHudWindowContextId(gHudWindow));
            if (!retried) {
                QFLogMessage(@"两条路都注册不上：签名里的 accessibility-window-hosting 大概率没生效，"
                             @"请用 TrollStore 重新安装这一版 tipa");
            }
        });
    }

    // 注册成功也补一次：SpringBoard 的 accessibility hosting 层有时在我们注册的那一刻
    // 还没完全就绪（尤其是 SpringBoard 刚重启、进程刚开始接管的时候），第一次注册会被丢掉。
    // 1.5 秒后再提一次同一个 context 是无害的（幂等），但能把这类时序问题盖掉。
    if (registered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!gHudWindow) return;
            BOOL again = QFHudRegisterWindow(gHudWindow);
            QFLogFormat(@"补注册 ctx=%u 结果=%@", QFHudWindowContextId(gHudWindow),
                        again ? @"成功" : @"失败");
            QFWriteHudRegistered(again || QFReadHudRegistered());
        });
    }

    // 挂载 3 秒后自检：窗口要是被弄成 hidden 或全透明，重新提交一次并重新注册。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gHudWindow) return;
        if (gHudWindow.hidden || gHudWindow.alpha < 0.01) {
            QFLogFormat(@"自检：窗口不可见 hidden=%d alpha=%.2f，重新提交",
                        gHudWindow.hidden, gHudWindow.alpha);
            gHudWindow.hidden = NO;
            gHudWindow.alpha = 1.0;
            [gHudWindow makeKeyAndVisible];
            gHudRegistered = QFHudRegisterWindow(gHudWindow);
            QFWriteHudRegistered(gHudRegistered);
        } else {
            QFLogFormat(@"自检 hidden=%d alpha=%.2f center=(%.0f,%.0f) ctx=%u 注册=%@ 实例=%lu",
                        gHudWindow.hidden, gHudWindow.alpha,
                        gHudBar.center.x, gHudBar.center.y,
                        QFHudWindowContextId(gHudWindow),
                        gHudRegistered ? @"是" : @"否",
                        (unsigned long)QFHudLiveInstances().count);
        }
    });
}

#pragma mark - 应用代理

// 插件模式用的 UIApplication 子类。
//
// 这里必须做一件事：把 eventDispatcher 的 run loop 源装到主 run loop 上。
// 不装的话 backboardd 送过来的 HID 事件没人读，BKSHIDEventRegisterEventCallback 的回调
// 一次都不会触发 —— 浮条就变成"能看不能点"。TrollSpeed 的 HUDMainApplication 也是这么干的。
@interface QFHudApplication : UIApplication
@end

@implementation QFHudApplication

- (instancetype)init {
    if ((self = [super init])) {
        @try {
            id dispatcher = [self valueForKey:@"eventDispatcher"];
            BOOL installed = dispatcher ? [self qf_installEventSources:dispatcher] : NO;
            if (!installed) {
                QFLogFormat(@"eventDispatcher 没装成 dispatcher=%@ 有方法=%d",
                            dispatcher ?: @"nil",
                            dispatcher ? [dispatcher respondsToSelector:
                                          NSSelectorFromString(@"_installEventRunLoopSources:")] : 0);
                // 这个 iOS 版本上方法名不一样，把相关方法名列出来，下一版照着调。
                [self qf_dumpEventDispatcherMethods:dispatcher];
                QFLogMessage(@"UIKit 触摸通道不完整，改走 HID 备用通道");
            }
        } @catch (NSException *exception) {
            QFLogFormat(@"装事件源抛异常 %@", exception);
        }
    }
    return self;
}

// iOS 各版本方法名不一样，按可能性从高到低试。装上了才继续挂 fetcher ——
// 只挂 fetcher 不装源等于让 dispatcher 处于半初始化状态，比不装更糟。
- (BOOL)qf_installEventSources:(id)dispatcher {
    CFRunLoopRef runLoop = CFRunLoopGetMain();

    for (NSString *name in @[@"_installEventRunLoopSources:", @"installEventRunLoopSources:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:selector]) continue;
        ((void (*)(id, SEL, CFRunLoopRef))objc_msgSend)(dispatcher, selector, runLoop);
        QFLogFormat(@"事件 run loop 源已装上（%@）", name);
        [self qf_attachEventFetcher:dispatcher];
        return YES;
    }

    for (NSString *name in @[@"_installEventRunLoopSources", @"installEventRunLoopSources"]) {
        SEL selector = NSSelectorFromString(name);
        if (![dispatcher respondsToSelector:selector]) continue;
        ((void (*)(id, SEL))objc_msgSend)(dispatcher, selector);
        QFLogFormat(@"事件 run loop 源已装上（%@ 无参版）", name);
        [self qf_attachEventFetcher:dispatcher];
        return YES;
    }

    return NO;
}

- (void)qf_attachEventFetcher:(id)dispatcher {
    Class fetcherClass = objc_getClass("UIEventFetcher");
    if (!fetcherClass) {
        QFLogMessage(@"没有 UIEventFetcher，手势触摸可能收不到，靠 HID 备用通道");
        return;
    }
    id fetcher = [[fetcherClass alloc] init];
    [dispatcher setValue:fetcher forKey:@"eventFetcher"];
    SEL sink = NSSelectorFromString(@"setEventFetcherSink:");
    if ([fetcher respondsToSelector:sink]) {
        ((void (*)(id, SEL, id))objc_msgSend)(fetcher, sink, dispatcher);
    } else {
        [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
    }
    [self setValue:fetcher forKey:@"eventFetcher"];
    QFLogMessage(@"eventFetcher 已挂到 dispatcher（UIKit 触摸才进得来）");
}

- (void)qf_dumpEventDispatcherMethods:(id)dispatcher {
    if (!dispatcher) return;
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (Class cls = object_getClass(dispatcher);
         cls && cls != [NSObject class];
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            NSString *name = NSStringFromSelector(method_getName(methods[index]));
            if ([name rangeOfString:@"RunLoop" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [name rangeOfString:@"install" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [name rangeOfString:@"Source" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:[NSString stringWithFormat:@"%@@%@", name, NSStringFromClass(cls)]];
            }
        }
        if (methods) free(methods);
    }
    QFLogFormat(@"UIEventDispatcher 相关方法 %lu 个：%@",
                (unsigned long)hits.count,
                hits.count > 0 ? [hits componentsJoinedByString:@", "] : @"(没有)");
}

@end

@interface QFHudAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation QFHudAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    QFLogMessage(@"HUD 代理收到 didFinishLaunching");
    QFHudMount();
    self.window = gHudWindow;
    return YES;
}

@end

#pragma mark - 进程控制

static NSString *QFHudExecutablePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);
        if (size == 0) return;
        char *buffer = calloc(1, size + 1);
        if (!buffer) return;
        if (_NSGetExecutablePath(buffer, &size) == 0) {
            path = [NSString stringWithUTF8String:buffer];
        }
        free(buffer);
    });
    return path;
}

typedef int (*QFHudPersonaFn)(const posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*QFHudPersonaIdFn)(const posix_spawnattr_t *, uid_t);

static void QFHudApplyPersona(posix_spawnattr_t *attr) {
    QFHudPersonaFn setPersona = (QFHudPersonaFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    QFHudPersonaIdFn setUid = (QFHudPersonaIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    QFHudPersonaIdFn setGid = (QFHudPersonaIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!setPersona || !setUid || !setGid) return;
    setPersona(attr, 99, 1);   // POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
    setUid(attr, 0);
    setGid(attr, 0);
}

// 返回子进程 pid，失败返回 -1。detached = 独立进程组（父进程死了它不受影响）。
static pid_t QFHudSpawnArgument(NSString *argument, BOOL detached) {
    NSString *path = QFHudExecutablePath();
    if (path.length == 0) return -1;

    for (int attempt = 0; attempt < 2; attempt++) {
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        if (detached) {
            posix_spawnattr_setpgroup(&attr, 0);
            posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        }
        if (attempt == 0) QFHudApplyPersona(&attr);

        const char *executable = path.UTF8String;
        const char *args[] = { executable, argument.UTF8String, NULL };
        pid_t pid = 0;
        int result = posix_spawn(&pid, executable, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);

        if (result == 0) return pid;
        QFLogFormat(@"posix_spawn(%@) 第 %d 次失败：%s", argument, attempt + 1, strerror(result));
    }
    return -1;
}

BOOL QFHudIsAvailable(void) {
    return objc_getClass("SBSAccessibilityWindowHostingController") != NULL;
}

#pragma mark 实例台账（解决多实例叠加）

static NSString *QFHudExecutablePathForLog(void);

static NSString *QFHudExecutablePathForLog(void) {
    NSString *path = QFHudExecutablePath();
    return path.length > 0 ? path : @"(取不到)";
}

// 列出台账里还活着的实例 pid。
static NSArray<NSNumber *> *QFHudLiveInstances(void) {
    NSMutableArray<NSNumber *> *alive = [NSMutableArray array];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:@QFHudLedgerDir error:nil]) {
        pid_t pid = (pid_t)name.intValue;
        if (pid <= 0) continue;
        // ★ 2.1.1：EPERM 也当活着。
        // 沙盒里的 App 对浮窗进程发 0 号信号，系统常常回 EPERM（进程存在、只是没权限），
        // kill 返回 -1 —— 旧代码只看 ==0，于是把活着的实例判成死的：
        //   状态卡写「未运行」、App 以为没起、再拉起又会多一个实例。
        // ESRCH 才是"真的不在了"。
        if (kill(pid, 0) == 0 || errno == EPERM) {
            [alive addObject:@(pid)];
        }
    }
    return alive;
}

// 把自己登记进台账。
static void QFHudLedgerRegisterSelf(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:@QFHudLedgerDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *path = [@QFHudLedgerDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%d", getpid()]];
    [[NSString stringWithFormat:@"%.6f", now] writeToFile:path
                                              atomically:YES
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
}

// 启动时清理：凡是比自己早的实例，一律杀掉。
// 为什么要比时间而不是"先到先得"：SpringBoard 重启时每个旧实例都会 spawn 一个接班人，
// 靠新实例杀掉旧实例最省事，也天然保证屏幕上只剩最后那一条。
//
// 但这条规则有个致命的自增殖面：如果同一时刻被拉起好几个（比如交接通知被重复投递、
// 或者主 App 的探测恰好落在台账刷新之前），它们会互相残杀 —— 而每个被杀的进程如果是
// 在交接回调里死的，还会再拉起一个接班人。现场就是日志里那种每秒一个新进程、连着二十秒，
// 窗口刚注册好就被下一个顶掉，屏幕上那条浮条一直是"还没有内容的空壳"。
// 熔断：如果发现有兄弟实例跟我几乎同时启动（3 秒内），我直接让位，不建窗口、不再交接。
// 最终只有最早的那个活下来，链条在这里断掉。
static BOOL QFHudReapOlderInstances(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:@QFHudLedgerDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    pid_t selfPid = getpid();
    NSUInteger killed = 0;
    BOOL hasTwin = NO;

    for (NSString *name in [manager contentsOfDirectoryAtPath:@QFHudLedgerDir error:nil]) {
        pid_t pid = (pid_t)name.intValue;
        NSString *path = [@QFHudLedgerDir stringByAppendingPathComponent:name];
        if (pid <= 0) {
            [manager removeItemAtPath:path error:nil];
            continue;
        }
        if (pid == selfPid) continue;
        NSString *content = [NSString stringWithContentsOfFile:path
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
        double started = content.doubleValue;
        if (started > now) continue;      // 比我启动得还晚，留着让它活
        if (kill(pid, 0) != 0) {
            [manager removeItemAtPath:path error:nil];
            continue;
        }
        // 同一批起来的兄弟：让我先退出，别互相残杀。
        if (now - started < 3.0) {
            hasTwin = YES;
            continue;
        }
        kill(pid, SIGKILL);
        killed++;
        [manager removeItemAtPath:path error:nil];
    }

    if (killed > 0) {
        QFLogFormat(@"清理了 %lu 个旧浮窗实例（多实例会让多条浮条叠在一起）", (unsigned long)killed);
    }
    if (hasTwin) {
        QFLogMessage(@"检测到 3 秒内的兄弟实例，本次让位（防进程风暴）");
        return NO;
    }
    return YES;
}

// 上次拉起的时间点。放在文件作用域是为了让 QFHudTerminate() 能把它清零：
// 用户「关掉 → 马上又打开」如果落在这 8 秒冷却里，点击会被当成"刚拉起过"直接跳过，
// 表现就是开关按了没反应，而且两个方向都按不动。
static NSTimeInterval gLastSpawnAt;

BOOL QFHudSpawn(void) {
    // 冷却期：面板/主页按钮连点、探测慢半拍、SpringBoard 交接回调重复投递，
    // 都会让这里被连续调用。每调一次就是一个新进程，而新进程启动又会杀掉上一个 ——
    // 屏幕上那条浮条永远处于"刚挂上就被换掉"的状态，看起来就是空白、没有内容。
    //
    // 2.0.1 把条件收紧了：冷却期内**无条件跳过**。
    // 原来只在"实例还活着"时才跳过，可现场日志是这样的：
    //   14:22:22 拉起 12396 → 14:22:23 让位退出
    //   14:22:23 拉起 12398 → 14:22:24 让位退出
    //   14:22:24 拉起 12399
    //   14:22:31 拉起 12400
    // 让位退出的进程 pid 文件已经清掉，QFHudIsRunning() 立刻变 false，
    // 于是"还活着才跳过"这个条件形同虚设，9 秒里拉起 4 个，各自注册一个窗口互相顶。
    // 现在不看实例存活，冷却期一律不拉。
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gLastSpawnAt > 0 && now - gLastSpawnAt < 8.0) {
        // 冷却只拦"刚拉起的那一个还活着"的情况。它要是已经被关掉了
        // （用户刚点了关闭、马上又想打开），这里必须放行 ——
        // 否则一次点击会被当成重复拉起，直接报"已在运行"或"拉起失败"，
        // 开关两个方向都按不动。
        if (QFHudIsRunning()) {
            QFLogMessage(@"8 秒内刚拉起过，跳过本次拉起（防进程风暴）");
            return YES;
        }
        gLastSpawnAt = 0;
    }

    // 已经在跑就别再动它。
    // 原来这里无条件先 QFHudTerminate() 再拉起 —— 结果就是：只要用户打开一次 App，
    // 屏幕上那条浮条就被杀掉重建一次。重建过程中新进程要重新注册窗口、重新等第一次绘制，
    // 用户每次抬头看到的都是"刚挂上、还没内容"的空壳。
    if (QFHudIsRunning()) {
        QFLogMessage(@"浮窗已在运行，不重复拉起");
        return YES;
    }

    QFHudTerminate();   // 清掉残留的旧实例，避免两个进程抢同一个位置
    gLastSpawnAt = now; // 冷却从真正拉起这一刻算起（Terminate 内部会把计数器清零）
    pid_t pid = QFHudSpawnArgument(@"-hud", YES);
    if (pid <= 0) {
        QFLogFormat(@"拉起 HUD 进程失败，可执行文件=%@", QFHudExecutablePathForLog());
        return NO;
    }
    int unused = 0;
    waitpid(pid, &unused, WNOHANG);
    QFLogFormat(@"已拉起 HUD 进程 pid=%d", pid);
    return YES;
}

void QFHudTerminate(void) {
    // ★ 2.1.6：先下"结束指令"，再尽力硬杀。
    //
    // 真机日志（2026-10-31 15:26 / 15:32）证明硬杀从来没成功过：
    //   [15:26:05] 已结束 HUD 进程 pid=96595
    //   [15:26:29] 心跳 pid=96595 ...            ← 它还在
    // 原因在 QFHudApplyPersona：HUD 是用 posix_spawn 以 uid=0 拉起的，App 是 mobile，
    // kill 一个 root 进程必然 EPERM。可旧代码不看返回值，杀没杀成都打印"已结束"，
    // 于是 App 以为关掉了、屏幕上的浮条纹丝不动 —— 一句"点了没反应"就是这么来的。
    //
    // 现在主通道是偏好里的 killAt 时间戳：HUD 每 0.25 秒读一次，读到比自己启动更晚的
    // 时间戳就自己走 QFHudShutdown（注销 CAContext、销毁窗口、清心跳、删台账），
    // root 进程自己退出不需要任何权限。kill 只作为"万一它也读不到偏好"的兜底。
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"killAt"] = @([[NSDate date] timeIntervalSince1970]);
    // 注意：这里**不能**顺手写 enabled=0。
    // QFHudSpawn() 内部会先调 QFHudTerminate() 清残留，然后把新进程拉起来；
    // 新进程第一拍就会读到 enabled=0，按"用户关闭"的规则当场自杀 —— 永远起不来。
    // 开关状态由调用方（applyHudOverlayWanted / restartOverlay）自己写。
    QFPreferencesWrite(state);
    notify_post(QFChangeNotification);

    // 记下这一轮指令的时间戳，供调用方判断 HUD 是不是"没响应"。
    gLastKillRequestAt = [NSDate timeIntervalSinceReferenceDate];

    // 兜底硬杀：成了更好，不成也是预期内（EPERM），日志必须如实写。
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *pidSources = [NSMutableArray array];
    NSString *pidString = [NSString stringWithContentsOfFile:@QFHudPidPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (pidString.length > 0) [pidSources addObject:pidString];
    for (NSString *name in [manager contentsOfDirectoryAtPath:@QFHudLedgerDir error:nil]) {
        [pidSources addObject:name];
    }

    NSUInteger killed = 0, denied = 0;
    for (NSString *source in pidSources) {
        pid_t pid = (pid_t)source.intValue;
        if (pid <= 0) continue;
        if (kill(pid, SIGKILL) == 0) {
            int status = 0;
            waitpid(pid, &status, WNOHANG);   // 我们是父进程：顺手收尸，别留僵尸占着 pid
            killed++;
        } else {
            denied++;   // EPERM：它是 root，我们杀不动。指令通道会把它带走。
        }
    }
    if (killed > 0) QFLogFormat(@"已结束 %lu 个 HUD 进程（自行退出）", (unsigned long)killed);
    if (denied > 0) QFLogFormat(@"%lu 个 HUD 进程不接受信号（以 root 运行），已下发结束指令",
                                (unsigned long)denied);

    unlink(QFHudPidPath);
    for (NSString *name in [manager contentsOfDirectoryAtPath:@QFHudLedgerDir error:nil]) {
        [manager removeItemAtPath:[@QFHudLedgerDir stringByAppendingPathComponent:name] error:nil];
    }

    // 擦痕迹。硬杀成功时进程没机会清理；走指令通道时它自己会清，这里再做一次没有副作用。
    // 目的只有一个：别让 QFHudIsRunning() 继续用"12 秒内的心跳"骗 App 说它还活着。
    QFClearHudBeat();
    QFWriteHudRegistered(NO);
    gLastSpawnAt = 0;   // 关掉之后立刻允许再开，不被 8 秒冷却挡住
}

BOOL QFHudIsRunning(void) {
    // 台账文件只是"曾经登记过"，进程可能早就死了（让位退出、被 jetsam 清掉、
    // 或者宿主的 App 被卸载）。必须真的探一下进程在不在，否则残留的台账会让
    // App 一直以为浮窗活着 —— 既不再拉起，也不显示兜底浮条，两头落空。
    for (NSNumber *pid in QFHudLiveInstances()) {
        if (pid.intValue > 0) return YES;   // LiveInstances 已经做过 EPERM 容错
    }
    // ★ 2.1.1：心跳兜底。
    // 探活受沙盒权限影响（kill 可能拿 EPERM 也可能拿 ESRCH，取决于进程 uid 与沙盒档位），
    // 而 cfprefsd 跨进程一定读得到。HUD 进程每 5 秒写一次 hudbeat，
    // 12 秒内有心跳就说明它活着 —— 这一条比探活可靠得多。
    if (QFHudBeatAlive(12.0)) return YES;

    NSString *pidString = [NSString stringWithContentsOfFile:@QFHudPidPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    if (pidString.length == 0) return NO;
    pid_t pid = (pid_t)pidString.intValue;
    if (pid <= 0) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}

#pragma mark 旧二进制留下的孤儿（1.5.0 及更早没有台账）

#define QFProcAllPids 1
#define QFProcPathMax 4096

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// 同一条可执行文件，App 本体和浮窗进程长得一模一样，只能靠 argv[1] == "-hud" 区分，
// 不然清理孤儿的时候会把用户正在用的 App 一起杀了。
static BOOL QFHudPidLooksLikeHud(pid_t pid) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= 0) return NO;
    char *buffer = malloc(size);
    if (!buffer) return NO;

    BOOL isHud = NO;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) == 0) {
        int argc = 0;
        memcpy(&argc, buffer, sizeof(argc));
        char *cursor = buffer + sizeof(argc);
        char *end = buffer + size;
        while (cursor < end && *cursor != '\0') cursor++;   // 跳过可执行路径
        while (cursor < end && *cursor == '\0') cursor++;   // 跳过填充
        if (argc >= 2 && cursor < end) {
            isHud = strcmp(cursor, "-hud") == 0;
        }
    }
    free(buffer);
    return isHud;
}

static NSUInteger QFHudKillOtherHudProcesses(void) {
    int bytes = proc_listpids(QFProcAllPids, 0, NULL, 0);
    if (bytes <= 0) return 0;
    int capacity = bytes / (int)sizeof(pid_t) + 16;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return 0;

    int used = proc_listpids(QFProcAllPids, 0, pids, capacity * (int)sizeof(pid_t));
    int count = used > 0 ? used / (int)sizeof(pid_t) : 0;

    NSString *selfPath = QFHudExecutablePath();
    pid_t selfPid = getpid();
    NSUInteger killed = 0;

    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 0 || pid == selfPid) continue;
        char path[QFProcPathMax];
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        if (selfPath.length == 0 || strcmp(path, selfPath.UTF8String) != 0) continue;
        if (!QFHudPidLooksLikeHud(pid)) continue;
        kill(pid, SIGKILL);
        killed++;
    }

    free(pids);
    return killed;
}

#pragma mark - 插件模式主循环

int QFHudRunPlugin(void) {
    @autoreleasepool {
        // 第一件事：把比自己早的实例全部清掉。
        // 之前只靠一个 pid 文件管进程，文件被后来的实例覆盖，先前那些就变成永远杀不掉的孤儿 ——
        // 屏幕上会同时挂好几条浮条，日志里同一句话重复七八遍，就是它们各写了一次。
        NSUInteger otherInstances = 0;
        for (NSNumber *pid in QFHudLiveInstances()) {
            if (pid.intValue != getpid()) otherInstances++;
        }
        if (otherInstances == 0) {
            // 台账还是空的，说明屏幕上跑的可能是旧版（没有台账）留下的孤儿，扫一遍进程收掉。
            NSUInteger stale = QFHudKillOtherHudProcesses();
            if (stale > 0) {
                QFLogFormat(@"清掉 %lu 个没有台账记录的旧浮窗进程", (unsigned long)stale);
            }
        }
        if (!QFHudReapOlderInstances()) {
            // 让位：不登记台账、不建窗口、不注册交接监听，直接退出。
            // 走到这里说明自己是被进程风暴卷起来的，多留一个只会把前一个顶掉，
            // 屏幕上那条永远是"刚挂上就被换掉"的空壳。
            return EXIT_SUCCESS;
        }
        QFHudLedgerRegisterSelf();
        // ★ 2.1.6：记住自己的启动时刻（wall clock）。
        // App 想让我退的时候不会直接 kill（它杀不动，见 QFHudTerminate 的注释），
        // 而是往偏好里写一个 killAt 时间戳。只有"比我的启动时间更晚"的指令才是我该执行的，
        // 否则新拉起的实例会被上一轮的旧指令秒掉。
        gHudStartWall = [[NSDate date] timeIntervalSince1970];

        // 再落 pid，主 App 的 -exit / -check 靠它找到我们。
        NSString *pidString = [NSString stringWithFormat:@"%d", getpid()];
        [pidString writeToFile:@QFHudPidPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];
        QFLogFormat(@"HUD 进程启动 pid=%d 实例数=%lu 路径=%@",
                    getpid(), (unsigned long)QFHudLiveInstances().count,
                    QFHudExecutablePathForLog());
        // 进程一起来就记一条：万一后面崩在建窗那一步，这条也已经落盘了。
        QFLogFormat(@"[权限自检] %@", QFEntitlementsSummary());

        QFHudLoadFrameworks();
        [UIScreen initialize];
        CFRunLoopGetCurrent();

        QFHudVoidFn GSInitialize = (QFHudVoidFn)QFHudLookup("GSInitialize");
        QFHudVoidFn BKSDisplayServicesStart = (QFHudVoidFn)QFHudLookup("BKSDisplayServicesStart");
        QFHudVoidFn UIApplicationInitialize = (QFHudVoidFn)QFHudLookup("UIApplicationInitialize");
        QFHudSingletonFn UIApplicationInstantiateSingleton =
            (QFHudSingletonFn)QFHudLookup("UIApplicationInstantiateSingleton");
        QFHudHIDRegisterFn BKSHIDEventRegisterEventCallback =
            (QFHudHIDRegisterFn)QFHudLookup("BKSHIDEventRegisterEventCallback");
        QFHudUIntFn GSEventInitialize = (QFHudUIntFn)QFHudLookup("GSEventInitialize");
        QFHudModeFn GSEventPushRunLoopMode = (QFHudModeFn)QFHudLookup("GSEventPushRunLoopMode");

        if (!UIApplicationInitialize || !UIApplicationInstantiateSingleton) {
            QFLogMessage(@"UIKit 私有入口取不到，插件模式无法启动");
            unlink(QFHudPidPath);
            return EXIT_FAILURE;
        }

        if (GSInitialize) GSInitialize();
        else QFLogMessage(@"GSInitialize 不可用，跳过");
        if (BKSDisplayServicesStart) BKSDisplayServicesStart();
        else QFLogMessage(@"BKSDisplayServicesStart 不可用，跳过");

        UIApplicationInitialize();
        // QFHudApplication 的 init 里会装事件 run loop 源，必须在这一步之前实例化。
        UIApplicationInstantiateSingleton(objc_getClass("QFHudApplication"));

        UIApplication *application = [UIApplication sharedApplication];
        static QFHudAppDelegate *delegate = nil;
        delegate = [QFHudAppDelegate new];
        application.delegate = delegate;

        // 让自己登记为辅助功能宿主，否则后面注册窗口会被 SpringBoard 拒。
        SEL accessibilityInit = NSSelectorFromString(@"_accessibilityInit");
        if ([application respondsToSelector:accessibilityInit]) {
            ((void (*)(id, SEL))objc_msgSend)(application, accessibilityInit);
        } else {
            QFLogMessage(@"没有 _accessibilityInit，注册窗口大概率失败");
        }

        [NSRunLoop currentRunLoop];

        if (BKSHIDEventRegisterEventCallback) {
            BKSHIDEventRegisterEventCallback(QFHudEventCallback);
            QFLogMessage(@"HID 事件回调已注册");
        } else {
            QFLogMessage(@"HID 回调不可用，浮条将不能拖动");
        }

        if (GSEventInitialize) GSEventInitialize(0);
        if (GSEventPushRunLoopMode) GSEventPushRunLoopMode(kCFRunLoopDefaultMode);

        // 以 plugin 身份完成启动：不注册 scene、不进前台/后台状态机，因此没有"退后台即挂起"。
        SEL complete = NSSelectorFromString(@"__completeAndRunAsPlugin");
        if ([application respondsToSelector:complete]) {
            ((void (*)(id, SEL))objc_msgSend)(application, complete);
        } else {
            QFLogMessage(@"没有 __completeAndRunAsPlugin，退化为直接建窗");
            QFHudMount();
        }

        // 代理回调没来也要有窗口。
        if (!gHudMounted) {
            QFLogMessage(@"didFinishLaunching 未触发，直接建窗");
            QFHudMount();
        }

        // SpringBoard 重启后：旧窗口随 SB 一起没了，重启一个新实例再自杀。
        // 注意：这个通知在同一次 SB 重启里会被投递给"每一个"还活着的实例。
        // 若同时有 N 个实例，就会 N 个一起 spawn 接班人、再一起自杀，接班人又各自收到……
        // 日志里 20 秒起 20 个进程、每隔一秒换一条浮条，就是这么来的。
        // 所以交接必须节流：写一个时间戳，10 秒内只允许交接一次，其余实例直接退出。
        static int bootToken;
        notify_register_dispatch("SBSpringBoardDidLaunchNotification", &bootToken,
                                 dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            NSString *stampPath = @"/var/mobile/Library/Caches/com.wacljcr.qfspeed.handoff";
            double now = [NSDate timeIntervalSinceReferenceDate];
            double last = [[NSString stringWithContentsOfFile:stampPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil] doubleValue];
            if (now - last < 10.0) {
                QFLogMessage(@"交接节流：10 秒内已交接过一次，本实例直接退出");
                kill(getpid(), SIGKILL);
                return;
            }
            [[NSString stringWithFormat:@"%.6f", now] writeToFile:stampPath
                                                       atomically:YES
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            QFLogMessage(@"SpringBoard 已重启，交接给新实例");
            QFHudSpawnArgument(@"-hud", YES);
            kill(getpid(), SIGKILL);
        });

        CFRunLoopRun();
        return EXIT_SUCCESS;
    }
}
