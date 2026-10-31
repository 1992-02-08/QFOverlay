#import "QFHostController.h"
#import "QFMetrics.h"
#import "QFFloatingBar.h"
#import "QFPiPBar.h"
#import "QFHudPlugin.h"
#import "QFSettingsPanel.h"
#import "../QFShared.h"

#import <notify.h>

#define QFColorBackground [UIColor colorWithRed:0.035 green:0.035 blue:0.043 alpha:1.0]
#define QFColorCard       [UIColor colorWithRed:0.086 green:0.086 blue:0.098 alpha:1.0]
#define QFColorCardEdge   [UIColor colorWithRed:0.145 green:0.145 blue:0.165 alpha:1.0]
#define QFColorPrimary    [UIColor colorWithRed:0.039 green:0.518 blue:1.000 alpha:1.0]
#define QFColorGreen      [UIColor colorWithRed:0.188 green:0.820 blue:0.345 alpha:1.0]
#define QFColorDim        [UIColor colorWithRed:0.557 green:0.557 blue:0.576 alpha:1.0]
#define QFColorBody       [UIColor colorWithWhite:1.0 alpha:0.96]

#pragma mark - 自绘按钮

// 不用 UIButton：iOS 15 起默认 configuration 会把图标和文字排成另一副样子，
// 自绘反而跨版本一致，也省得跟系统样式打架。
@interface QFActionButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *textLabel;
+ (instancetype)title:(NSString *)title icon:(NSString *)symbol background:(UIColor *)background;
- (void)setTitleText:(NSString *)title symbol:(NSString *)symbol;
@end

@implementation QFActionButton

+ (instancetype)title:(NSString *)title icon:(NSString *)symbol background:(UIColor *)background {
    QFActionButton *button = [[QFActionButton alloc] initWithFrame:CGRectZero];
    button.backgroundColor = background;
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIImage *image = [UIImage systemImageNamed:symbol];
    button.iconView = [[UIImageView alloc] initWithImage:image];
    button.iconView.tintColor = UIColor.whiteColor;
    button.iconView.contentMode = UIViewContentModeScaleAspectFit;
    button.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    button.iconView.userInteractionEnabled = NO;

    button.textLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    button.textLabel.text = title;
    button.textLabel.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
    button.textLabel.textColor = UIColor.whiteColor;
    button.textLabel.translatesAutoresizingMaskIntoConstraints = NO;
    button.textLabel.userInteractionEnabled = NO;

    [button addSubview:button.iconView];
    [button addSubview:button.textLabel];

    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintEqualToConstant:50.0],
        [button.textLabel.centerXAnchor constraintEqualToAnchor:button.centerXAnchor constant:11.0],
        [button.textLabel.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [button.iconView.trailingAnchor constraintEqualToAnchor:button.textLabel.leadingAnchor constant:-8.0],
        [button.iconView.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [button.iconView.widthAnchor constraintEqualToConstant:19.0],
        [button.iconView.heightAnchor constraintEqualToConstant:19.0],
    ]];
    return button;
}

- (void)setTitleText:(NSString *)title symbol:(NSString *)symbol {
    self.textLabel.text = title;
    if (symbol) self.iconView.image = [UIImage systemImageNamed:symbol];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 注意：这里不能调 [super touchesBegan:]。UIControl 自己在 touchesEnded 里就会发
    // UIControlEventTouchUpInside，再手动发一次等于按两下 —— 开关类按钮按两下就等于没按，
    // 现场表现就是"按钮是死的"。所以超类那套追踪直接不用，自己发。
    [UIView animateWithDuration:0.12 animations:^{
        self.alpha = 0.72;
        self.transform = CGAffineTransformMakeScale(0.985, 0.985);
    }];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    }];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    }];
}

@end

#pragma mark - 主控制器

@interface QFHostController ()
@property (nonatomic, strong) UILabel *windowValue;
@property (nonatomic, strong) UILabel *lockValue;
@property (nonatomic, strong) UILabel *edgeValue;
@property (nonatomic, strong) UILabel *itemValue;
@property (nonatomic, strong) UILabel *uptimeValue;
@property (nonatomic, strong) UILabel *modeLabel;
@property (nonatomic, strong) QFActionButton *primaryButton;
@property (nonatomic, strong) QFActionButton *lockButton;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL remoteAvailable;   // SpringBoard 侧（越狱 deb）在线
@property (nonatomic) BOOL hudMode;            // 插件进程模式：窗口由 SpringBoard 合成
@property (nonatomic) BOOL usePiP;             // 兜底：系统画中画（只有插件模式不可用才用）
@property (nonatomic) BOOL overlayEnabled;
// 刚拉起进程时的乐观窗口：HUD 从 fork 到写好 pid 文件要几百毫秒，
// 这段时间状态卡若照实写「未运行」，用户会以为按钮又没反应，再点一次。
@property (nonatomic) NSTimeInterval optimisticUntil;
@property (nonatomic) BOOL everStarted;   // 画中画至少浮起过一次
@property (nonatomic) BOOL locked;
@end

@implementation QFHostController

// 定义在下方（文案拼装处），这里先声明，供模式探测提前使用。
static BOOL QFHostFlag(NSDictionary *state, NSString *key, BOOL fallback);

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFColorBackground;
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    self.locked = NO;
    [self buildInterface];
    [self detectRemoteOverlay];
    [self startTimer];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(floatingBarTapped)
                                                 name:@"QFFloatingBarTapped"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePiPStopped)
                                                 name:@"QFPiPDidStop"
                                               object:nil];
}

// 点浮条切紧凑：把结果写回共享偏好。
// 以前这里只切本地属性，下一秒 refresh 又按老配置覆盖回去 —— 用户看到的就是"点了没反应"。
- (void)floatingBarTapped {
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"compact"] = @([QFFloatingBar shared].compact);
    QFPreferencesWrite(state);
    notify_post(QFChangeNotification);
    [self refresh];
}

- (void)handlePiPStopped {
    if (!self.usePiP) return;
    // 用户在画中画窗口上点了关闭，界面要跟着回到"已关闭"，否则状态是假的。
    self.overlayEnabled = NO;
    [self refresh];
}

- (void)dealloc {
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 界面

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIView *)card {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = QFColorCard;
    card.layer.cornerRadius = 18.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    return card;
}

- (UIView *)statusRow:(NSString *)title valueLabel:(UILabel *)value {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *name = [self label:title size:15.0 weight:UIFontWeightRegular color:QFColorBody];
    [row addSubview:name];
    [row addSubview:value];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:34.0],
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:12.0],
    ]];
    return row;
}

- (void)buildInterface {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 13.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:10.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
    ]];

    UILabel *title = [self label:@"QFSpeed" size:34.0 weight:UIFontWeightBold color:UIColor.whiteColor];
    UILabel *subtitle = [self label:@"悬浮性能条 · 独立 App 宿主" size:15.0 weight:UIFontWeightRegular color:QFColorDim];
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:subtitle];
    [stack setCustomSpacing:20.0 afterView:subtitle];

    // 状态卡
    UIView *statusCard = [self card];
    [stack addArrangedSubview:statusCard];

    UIStackView *statusStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    statusStack.axis = UILayoutConstraintAxisVertical;
    statusStack.spacing = 0.0;
    statusStack.translatesAutoresizingMaskIntoConstraints = NO;
    [statusCard addSubview:statusStack];
    [NSLayoutConstraint activateConstraints:@[
        [statusStack.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:14.0],
        [statusStack.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16.0],
        [statusStack.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-16.0],
        [statusStack.bottomAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:-14.0],
    ]];

    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *statusIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chart.bar.xaxis"]];
    statusIcon.tintColor = QFColorDim;
    statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *statusTitle = [self label:@"状态" size:15.0 weight:UIFontWeightRegular color:QFColorDim];
    [header addSubview:statusIcon];
    [header addSubview:statusTitle];
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:30.0],
        [statusIcon.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [statusIcon.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [statusIcon.widthAnchor constraintEqualToConstant:15.0],
        [statusIcon.heightAnchor constraintEqualToConstant:13.0],
        [statusTitle.leadingAnchor constraintEqualToAnchor:statusIcon.trailingAnchor constant:8.0],
        [statusTitle.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    [statusStack addArrangedSubview:header];

    self.windowValue = [self label:@"显示中" size:15.0 weight:UIFontWeightRegular color:QFColorGreen];
    self.lockValue = [self label:@"可拖动" size:15.0 weight:UIFontWeightRegular color:QFColorGreen];
    self.edgeValue = [self label:@"关闭" size:15.0 weight:UIFontWeightRegular color:QFColorBody];
    self.itemValue = [self label:@"6 / 6" size:15.0 weight:UIFontWeightRegular color:QFColorBody];
    self.uptimeValue = [self label:@"0 s" size:15.0 weight:UIFontWeightRegular color:QFColorBody];
    for (UILabel *value in @[self.windowValue, self.lockValue, self.edgeValue,
                             self.itemValue, self.uptimeValue]) {
        value.textAlignment = NSTextAlignmentRight;
    }

    [statusStack addArrangedSubview:[self statusRow:@"悬浮窗" valueLabel:self.windowValue]];
    [statusStack addArrangedSubview:[self statusRow:@"位置锁定" valueLabel:self.lockValue]];
    [statusStack addArrangedSubview:[self statusRow:@"贴边隐藏" valueLabel:self.edgeValue]];
    [statusStack addArrangedSubview:[self statusRow:@"显示项目" valueLabel:self.itemValue]];
    [statusStack addArrangedSubview:[self statusRow:@"运行时长" valueLabel:self.uptimeValue]];

    // 主按钮
    self.primaryButton = [QFActionButton title:@"隐藏悬浮窗" icon:@"eye.slash" background:QFColorPrimary];
    [self.primaryButton addTarget:self action:@selector(toggleOverlay) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.primaryButton];

    QFActionButton *settingsButton = [QFActionButton title:@"设置面板" icon:@"slider.horizontal.3"
                                               background:QFColorCard];
    [settingsButton addTarget:self action:@selector(openSettingsPanel) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:settingsButton];

    self.lockButton = [QFActionButton title:@"锁定位置" icon:@"lock" background:QFColorCard];
    [self.lockButton addTarget:self action:@selector(toggleLock) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.lockButton];

    self.modeLabel = [self label:@"" size:12.5 weight:UIFontWeightRegular color:QFColorDim];
    self.modeLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.modeLabel];

    [stack setCustomSpacing:18.0 afterView:self.modeLabel];

    // 调试提示卡
    UIView *tipsCard = [self card];
    [stack addArrangedSubview:tipsCard];

    UILabel *tipsTitle = [self label:@"调试提示" size:14.0 weight:UIFontWeightSemibold color:QFColorBody];
    UILabel *tipsBody = [self label:
        @"• 浮条由系统合成，回桌面、切 App、锁屏都在；拖动它就能换位置\n"
        @"• 点一下浮条在「紧凑 / 完整」之间切换，长按拖动不会误触\n"
        @"• 横屏看视频时浮条会转正；不想看就在设置里开「横屏时隐藏」\n"
        @"• 透明度、字号、显示项都在「设置面板」里调，改完立刻生效"
        size:13.0 weight:UIFontWeightRegular color:QFColorDim];
    tipsBody.numberOfLines = 0;
    [tipsCard addSubview:tipsTitle];
    [tipsCard addSubview:tipsBody];
    [NSLayoutConstraint activateConstraints:@[
        [tipsTitle.topAnchor constraintEqualToAnchor:tipsCard.topAnchor constant:16.0],
        [tipsTitle.leadingAnchor constraintEqualToAnchor:tipsCard.leadingAnchor constant:16.0],
        [tipsTitle.trailingAnchor constraintEqualToAnchor:tipsCard.trailingAnchor constant:-16.0],
        [tipsBody.topAnchor constraintEqualToAnchor:tipsTitle.bottomAnchor constant:8.0],
        [tipsBody.leadingAnchor constraintEqualToAnchor:tipsCard.leadingAnchor constant:16.0],
        [tipsBody.trailingAnchor constraintEqualToAnchor:tipsCard.trailingAnchor constant:-16.0],
        [tipsBody.bottomAnchor constraintEqualToAnchor:tipsCard.bottomAnchor constant:-16.0],
    ]];
}

#pragma mark 模式探测

- (void)detectRemoteOverlay {
    // 给 SpringBoard 侧发 ping：只有装了 deb 的越狱设备会回应（写 sbpong）。
    NSTimeInterval sentAt = [[NSDate date] timeIntervalSince1970];
    notify_post(QFPingNotification);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        double pong = QFReadPong();
        BOOL debOnline = pong >= sentAt - 0.5;
        BOOL pluginAvailable = QFHudIsAvailable();

        // ★ 2.1.0：插件通道优先于越狱 deb。
        // 之前是 deb 优先：只要旧 deb 还在手机上（它照样回 sbpong），这里就判定「越狱侧接管」，
        // 立刻 QFHudTerminate() 杀掉自己的插件进程，然后 hudMode=NO。
        // 后果有两个，都很难查：
        //   ① 状态卡显示「悬浮窗 已隐藏」，可心跳还在打 —— 因为 App 一按按钮又重新拉起进程；
        //   ② 每开一次 App，浮条就被杀掉重建一次，用户看到的永远是刚挂上还没画完的空壳。
        // 现在：只要本机插件通道可用，就以 tipa 自带的为准，debud 那条让它自己让位。
        self.remoteAvailable = (!pluginAvailable && debOnline);

        if (pluginAvailable) {
            self.hudMode = YES;
            // ★ 2.1.2：上次是开启状态就把进程拉回来。
            // 以前这里只读 QFHudIsRunning()，从不主动拉起：用户明明开着浮窗，
            // 重启 App 后状态卡就写「未运行」，屏幕上只剩 App 内兜底那条 ——
            // 「常驻」变成了「每次都得再点一次按钮」。这里按持久化的 enabled 自动恢复，
            // 用户主动关过的（enabled=NO）不会自己冒出来。
            BOOL wanted = QFHostFlag(QFPreferencesRead(), @"enabled", NO);
            // ★ 2.1.6：自动恢复只做一次。
            // 这个 block 每次页面出现都会跑（从设置面板返回、切后台再回来）。
            // 以前每次都试一遍拉起，一旦 enabled 的写入因为任何原因没落地，
            // 用户刚关掉的浮窗就会被这里反复拉回来 —— 日志里 97267→97269→97271
            // 那个循环，每一次都紧跟在"退出浮窗"后面。
            static BOOL autoResumed;
            if (!autoResumed && wanted && !QFHudIsRunning()) {
                autoResumed = YES;
                QFHudSpawn();
                self.optimisticUntil = [NSDate timeIntervalSinceReferenceDate] + 4.0;
            }
            // 同样取"想开 && 真在跑"，别让一次探测把关闭状态翻回去。
            self.overlayEnabled = wanted && QFHudIsRunning();
            [[QFPiPBar shared] stop];
            if (debOnline) {
                QFLogMessage(@"检测到越狱 deb 也在响应：本次以 tipa 内置插件进程为准。"
                             @"建议卸载 com.wacljcr.qfoverlay，否则屏幕上会有两条浮条。");
            }
            [self refresh];
            return;
        }

        if (self.remoteAvailable) {
            // 越狱侧接管，本机的 PiP 和 App 内浮条都让位，避免同一块屏上出现两份。
            // 插件进程是独立进程，切模式不会自己消失；不显式杀掉它，屏幕上就会同时有
            // SpringBoard 那条和插件进程那条，叠在一起。
            if (QFHudIsRunning()) {
                QFHudTerminate();
            }
            self.hudMode = NO;
            [[QFPiPBar shared] stop];
            [[QFFloatingBar shared] hide];
        } else {
            // 连插件模式都不可用才退到画中画，再不行才退到 App 内。
            UIWindowScene *scene = self.view.window.windowScene;
            self.usePiP = scene ? [[QFPiPBar shared] prepareWithScene:scene] : NO;
            if (self.usePiP) {
                // 画中画一旦启动就是把 App 推到后台、浮窗浮起来，所以不自动起，
                // 等用户点按钮——否则一打开 App 就被"踢"出去，很怪。
                self.overlayEnabled = NO;
            } else {
                [[QFFloatingBar shared] show];
                self.overlayEnabled = YES;
            }
        }
        [self refresh];
    });
}

#pragma mark 状态

// 常驻那条到底在不在屏幕上？
//
// QFHudIsRunning() 只说明进程活着。1.4.0~1.8.1 的现场日志里，进程一直活着、
// 窗口的 hidden / alpha / center 各项也全对，可屏幕就是空的 —— 因为窗口没被
// SpringBoard 合成。真正能说明问题的是 HUD 进程调 registerWindowWithContextID:atLevel:
// 的返回值（HUD 进程写在 hudreg 这个键里）。
//
// 所以这里做兜底：进程在跑、但注册没成功，就把 App 内浮条顶上去。
// 至少用户看得见、拖得动、数值在跳，而不是对着一个"点了没反应"的界面。
static BOOL gFallbackBarShown = NO;

static BOOL QFHostFlag(NSDictionary *state, NSString *key, BOOL fallback) {
    id value = state[key];
    return value ? [value boolValue] : fallback;
}

// ★ 2.1.2：这条浮条的文案以前是写死的 —— 不管开关怎么按，永远是
// 「↓ ↑ CPU xx% x.xG 电量 xx%」。当屏幕上是 App 内浮条或画中画条时
// （插件窗口没被 SpringBoard 收下的兜底路径），用户按四个开关当然一点反应都没有：
// 偏好写进去了、日志也打了，可这条文字根本不读偏好。
// 现在逐项按开关拼，规则与 HUD 进程里的 QFHudComposeText 完全一致：
// 紧凑模式只省略单位与标签，不吞项目。
// IPA 样式：图标 + 数值 归因字符串
static NSAttributedString *QFHostIconText(NSString *iconName, NSString *text,
                                          NSDictionary *textAttrs, CGFloat fontSize) {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:fontSize * 0.88 weight:UIFontWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:iconName withConfiguration:config];
    if (!icon) return [[NSAttributedString alloc] initWithString:text attributes:textAttrs];
    UIColor *tint = textAttrs[NSForegroundColorAttributeName] ?: UIColor.whiteColor;
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

static NSAttributedString *QFHostComposeText(NSDictionary *state, QFMetrics *metrics) {
    BOOL compact = QFHostFlag(state, @"compact", NO);
    BOOL showNetwork = QFHostFlag(state, @"showNetwork", YES);
    BOOL showCPU = QFHostFlag(state, @"showCPU", YES);
    BOOL showMemory = QFHostFlag(state, @"showMemory", YES);
    BOOL showBattery = QFHostFlag(state, @"showBattery", YES);
    BOOL showFPS = QFHostFlag(state, @"showFPS", YES);
    BOOL showVoltage = QFHostFlag(state, @"showVoltage", YES);
    BOOL showAmpere = QFHostFlag(state, @"showAmpere", YES);
    BOOL showWatt = QFHostFlag(state, @"showWatt", YES);
    BOOL showTemp = QFHostFlag(state, @"showTemp", YES);

    CGFloat fontSize = state[@"fontSize"] ? [state[@"fontSize"] doubleValue] : 11.5;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:fontSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.96],
    };
    NSDictionary *sepA = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:fontSize * 0.82 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.28],
    };
    NSAttributedString *sep = [[NSAttributedString alloc] initWithString:@"  " attributes:sepA];
    NSMutableArray<NSAttributedString *> *items = [NSMutableArray array];

    NSString *down = [QFMetrics shortRateText:metrics.downloadRate];
    NSString *up = [QFMetrics shortRateText:metrics.uploadRate];

    if (showNetwork) {
        [items addObject:QFHostIconText(@"arrow.up", compact ? up : [NSString stringWithFormat:@"%@/s", up], attrs, fontSize)];
        [items addObject:QFHostIconText(@"arrow.down", compact ? down : [NSString stringWithFormat:@"%@/s", down], attrs, fontSize)];
    }
    if (showCPU) {
        [items addObject:QFHostIconText(@"cpu", [NSString stringWithFormat:@"%.0f%%", metrics.cpuPercent], attrs, fontSize)];
    }
    if (showMemory) {
        [items addObject:QFHostIconText(@"memorychip", [NSString stringWithFormat:@"%.1fG", metrics.memoryGB], attrs, fontSize)];
    }
    if (showBattery) {
        [items addObject:QFHostIconText(@"battery.100", [NSString stringWithFormat:@"%ld%%", (long)metrics.batteryPercent], attrs, fontSize)];
    }
    if (showFPS) {
        [items addObject:QFHostIconText(@"gauge", [NSString stringWithFormat:@"%.0f", metrics.fps], attrs, fontSize)];
    }
    if (showVoltage) {
        [items addObject:QFHostIconText(@"bolt", [NSString stringWithFormat:@"%.2fV", metrics.voltage], attrs, fontSize)];
    }
    if (showAmpere) {
        [items addObject:QFHostIconText(@"waveform.path.ecg", [NSString stringWithFormat:@"%.0fmA", metrics.amperage], attrs, fontSize)];
    }
    if (showWatt) {
        [items addObject:QFHostIconText(@"bolt.fill", [NSString stringWithFormat:@"%.1fW", metrics.wattage], attrs, fontSize)];
    }
    if (showTemp) {
        [items addObject:QFHostIconText(@"thermometer", [NSString stringWithFormat:@"%.1f°C", metrics.temperature], attrs, fontSize)];
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

- (void)syncFallbackBar {
    if (!self.hudMode) return;          // 非插件模式时 App 内浮条由别处管，别插手

    BOOL running = QFHudIsRunning();
    BOOL registered = running ? QFReadHudRegistered() : NO;
    // 注册键在 1.5 秒补注册、3 秒自检后才会被写成 1。启动最初那一两秒读到的还是 0，
    // 这时先别急着弹兜底条，等 HUD 进程把结果写出来（下面 3 秒宽限）。
    static NSTimeInterval hudFirstSeen = 0;
    if (running && hudFirstSeen == 0) hudFirstSeen = [NSDate timeIntervalSinceReferenceDate];
    if (!running) hudFirstSeen = 0;
    BOOL grace = hudFirstSeen > 0 && ([NSDate timeIntervalSinceReferenceDate] - hudFirstSeen) < 3.5;

    // ★ 2.1.6：用户明确关掉（enabled=0）时，绝不补兜底条。
    // 日志 15:32:26 那条「常驻窗口未被 SpringBoard 收下，先用 App 内浮条兜底」，
    // 就是关闭瞬间 hudreg 被清 0、进程还没退干净造成的 —— 屏幕上会突然多出一条，
    // 看着就像"关不掉、还多了一条"。
    BOOL wantOn = QFHostFlag(QFPreferencesRead(), @"enabled", NO);
    BOOL shouldShow = wantOn && running && !registered && !grace;
    if (shouldShow == gFallbackBarShown) return;
    gFallbackBarShown = shouldShow;
    if (shouldShow) {
        [[QFFloatingBar shared] show];
        QFLogMessage(@"常驻窗口未被 SpringBoard 收下，先用 App 内浮条兜底");
    } else {
        [[QFFloatingBar shared] hide];
    }
}

- (void)startTimer {
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [[QFMetrics shared] sample];
        [self refresh];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    [self syncFallbackBar];

    QFMetrics *metrics = [QFMetrics shared];
    // 锁定状态以共享偏好为准：面板里也能改，不跟着面板走会出现"显示已锁定其实能拖"。
    NSDictionary *state = QFPreferencesRead();
    if (state[@"locked"]) self.locked = [state[@"locked"] boolValue];
    // ★ 2.1.0：hudMode 优先判可见性。
    // 之前 remoteAvailable 排第一，只要旧 deb 在手机上回 pong，这里就永远读 deb 的开关，
    // 状态卡一直写「已隐藏」，而屏幕上其实有插件进程那条 —— 用户只会觉得坏了。
    BOOL visible;
    if (self.hudMode) {
        // ★ 2.1.5：「想开」和「真在跑」两个条件都成立才算运行中。
        //
        // 只认 QFHudIsRunning() 会有一段尴尬的窗口：用户刚点「关闭常驻浮窗」，
        // 进程正按自己的节奏注销窗口、退出（几百毫秒），这段时间 IsRunning 仍是 YES，
        // 状态卡立刻翻回「运行中」，按钮也写回「关闭常驻浮窗」——
        // 在用户眼里就是"我点了，它没动"。
        // 以持久化的 enabled 为意图，进程存活为事实，两者取交集。
        BOOL wanted = QFHostFlag(state, @"enabled", NO);
        BOOL running = QFHudIsRunning();
        if (running) self.optimisticUntil = 0;
        // 刚点「开启」的那几秒，进程还在启动，允许乐观显示，别让用户以为又失败了。
        BOOL optimistic = [NSDate timeIntervalSinceReferenceDate] < self.optimisticUntil;
        visible = wanted && (running || optimistic);
        self.overlayEnabled = visible;
    }
    else if (self.remoteAvailable) visible = self.overlayEnabled;
    else if (self.usePiP) visible = self.overlayEnabled;
    else visible = [QFFloatingBar shared].isVisible;

    // 常驻模式下「已隐藏」这个说法会被误读成没工作，改成直说进程在不在。
    self.windowValue.text = self.hudMode ? (visible ? @"运行中" : @"未运行")
                                         : (visible ? @"显示中" : @"已隐藏");
    self.windowValue.textColor = visible ? QFColorGreen : QFColorDim;

    self.lockValue.text = self.locked ? @"已锁定" : @"可拖动";
    self.lockValue.textColor = self.locked ? QFColorDim : QFColorGreen;
    // 画中画窗口由系统接管位置，锁定/拖动在这里没有意义，直接置灰免得误导。
    self.lockButton.enabled = !self.usePiP;
    self.lockButton.alpha = self.usePiP ? 0.45 : 1.0;

    NSTimeInterval uptime = [NSDate timeIntervalSinceReferenceDate] - self.startedAt;
    self.uptimeValue.text = [NSString stringWithFormat:@"%.0f s", uptime];

    NSString *showTitle = (self.usePiP || self.hudMode)
        ? (visible ? @"关闭常驻浮窗" : @"开启常驻浮窗")
        : (visible ? @"隐藏悬浮窗" : @"显示悬浮窗");
    [self.primaryButton setTitleText:showTitle
                              symbol:(visible ? @"eye.slash" : @"eye")];
    [self.lockButton setTitleText:(self.locked ? @"解锁位置" : @"锁定位置")
                           symbol:(self.locked ? @"lock.open" : @"lock")];
    [QFFloatingBar shared].locked = self.locked;

    // 浮条的紧凑状态以共享偏好为准（点浮条切换时会写回去）。
    [QFFloatingBar shared].compact = QFHostFlag(state, @"compact", NO);
    NSAttributedString *text = QFHostComposeText(state, metrics);
    [[QFFloatingBar shared] updateText:text];
    [[QFPiPBar shared] updateText:text];

    if (self.remoteAvailable) {
        self.modeLabel.text = @"运行模式：SpringBoard 常驻 —— 浮窗不在本 App 里，退出、锁屏都还在。";
        self.modeLabel.textColor = QFColorDim;
    } else if (self.hudMode) {
        if (gFallbackBarShown) {
            // 说清楚现在的处境，别再说"回桌面也在" —— 那条其实没成。
            self.modeLabel.text = @"运行模式：前台兜底 —— 常驻窗口没被系统收下，现在这条浮条只在本 App 内有效，"
                                  @"退出 App 就没了。打开「设置 → 日志」看第一屏的 ctx 和 注册= 就能定位。";
            self.modeLabel.textColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.25 alpha:1.0];
        } else {
            self.modeLabel.text = @"运行模式：常驻浮窗（插件进程）—— 窗口由 SpringBoard 合成，"
                                  @"回桌面、切 App、锁屏都在。浮条可拖动、点击切紧凑，"
                                  @"长按 0.55 秒锁定/解锁位置。";
            self.modeLabel.textColor = QFColorDim;
        }
    } else if (self.usePiP) {
        NSString *error = [QFPiPBar shared].lastError;
        if (error.length > 0) {
            self.modeLabel.text = [NSString stringWithFormat:
                @"运行模式：画中画浮窗 —— %@。按 Home 键再试一次。", error];
            self.modeLabel.textColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.25 alpha:1.0];
        } else if (!self.overlayEnabled) {
            self.modeLabel.text = @"运行模式：画中画浮窗 —— 点上面的「开启常驻浮窗」，"
                                  @"浮条会浮到桌面和任何 App 之上。";
            self.modeLabel.textColor = QFColorDim;
        } else if ([QFPiPBar shared].running) {
            self.everStarted = YES;
            self.modeLabel.text = @"运行模式：画中画浮窗 —— 已浮起。回桌面、切 App 都在；"
                                  @"锁屏会被 iOS 自动收起（系统行为）。";
            self.modeLabel.textColor = QFColorDim;
        } else if (self.everStarted) {
            // 回到本 App 时系统会把画中画收回来，这不是关闭，别显示"正在启动"吓人。
            self.modeLabel.text = @"运行模式：画中画浮窗 —— 已开启。切到别的 App 或回桌面就会浮起来。";
            self.modeLabel.textColor = QFColorDim;
        } else {
            self.modeLabel.text = @"运行模式：画中画浮窗 —— 正在启动，一两秒后自动浮起；"
                                  @"如果一直没动，按一下 Home 键。";
            self.modeLabel.textColor = QFColorDim;
        }
    } else {
        self.modeLabel.text = @"运行模式：仅本应用内 —— 这台设备既没有越狱插件，画中画也不可用，"
                              @"退出本 App 浮条即消失。";
        self.modeLabel.textColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.25 alpha:1.0];
    }
}

#pragma mark 动作

// 插件模式下的「开 / 关」，两个方向都必须真的落地。
//
// 原来这里收尾是：杀完进程立刻 `self.overlayEnabled = QFHudIsRunning();`。
// 可 SIGKILL 之后 HUD 进程来不及清自己的 hudbeat 心跳，12 秒内心跳都算"活着"，
// 这次复查必然读回 YES —— 按下「关闭常驻浮窗」按钮文字不变、状态卡还写「运行中」，
// 用户看到的就是"点了没反应"。再想开一次时，QFHudSpawn 里"已在运行，不重复拉起"
// 又把请求挡回去，两个方向一起失灵。
//
// 现在改成先礼后兵：
//   ① 先把 enabled=0 写进去并推一条通知，HUD 0.25 秒内自己走 QFHudShutdown ——
//      注销 CAContext、销毁窗口、清心跳，屏幕上不留"冻结的贴图"；
//   ② 1 秒后它要是还赖着，再 SIGKILL 兜底，并由 QFHudTerminate 替它把痕迹擦干净。
- (void)applyHudOverlayWanted:(BOOL)wantOn {
    // ★ 2.1.6：1 秒防连点。
    // 真机日志里 97267 → 97269 → 97271 三个进程连着起，就是"关掉之后按钮立刻变回
    // 开启、用户以为没生效又点一下"造成的。重复点按直接忽略，界面只跟第一次走。
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    static NSTimeInterval lastApplyAt;
    if (now - lastApplyAt < 1.0) {
        QFLogMessage(@"1 秒内重复点按，已忽略");
        return;
    }
    lastApplyAt = now;

    self.overlayEnabled = wantOn;

    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"enabled"] = @(wantOn);
    QFPreferencesWrite(state);

    if (wantOn) {
        BOOL spawned = QFHudSpawn();
        self.overlayEnabled = spawned;
        if (spawned) {
            // 进程从 fork 到登记 pid 有几百毫秒，这段时间先按"运行中"显示，
            // 免得用户以为没成又点一次。
            self.optimisticUntil = [NSDate timeIntervalSinceReferenceDate] + 4.0;
        } else {
            self.optimisticUntil = 0;
            [self alertTitle:@"拉起浮窗失败"
                     message:@"插件进程没能启动。多半是签名里的 platform-application 或 "
                             @"accessibility-window-hosting 未被系统接受。\n\n"
                             @"日志：/var/mobile/Library/Logs/QFOverlay.log"];
        }
    } else {
        self.optimisticUntil = 0;
        // 下"结束指令"，不是硬杀 —— HUD 以 root 运行，App 杀不动它（见 QFHudTerminate）。
        QFHudTerminate();
    }

    // 先按"这一刻的意图"刷一次界面：按钮文字、状态卡、面板胶囊当场翻转。
    [self refresh];

    __weak typeof(self) weakSelf = self;
    if (!wantOn) {
        // ★ 2.1.6：关掉之后要复查，不能发完指令就当成了。
        // HUD 每秒写一次心跳，指令生效的话它 1 秒内就不写了；
        // 若是它还在写，说明指令没送到（或它卡住了），再下一次，并把话说给用户听。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (QFHudBeatAlive(2.5) || QFHudIsRunning()) {
                QFLogMessage(@"HUD 未响应结束指令，再下发一次");
                QFHudTerminate();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) inner = weakSelf;
                    if (!inner) return;
                    if (QFHudBeatAlive(2.5) || QFHudIsRunning()) {
                        [inner alertTitle:@"浮窗进程没能退出"
                                  message:@"已下发两次结束指令，浮窗进程仍在运行。\n\n"
                                          @"这说明偏好通道没送达（App 与浮窗进程读写的不是同一份配置），"
                                          @"不是按钮没接上。\n\n"
                                          @"临时办法：用「重启浮窗」后再关一次，或在 TrollStore 里"
                                          @"结束 QFSpeed 后重新打开。日志里搜「结束指令」可以看到下发的时刻。"];
                    }
                    [inner refresh];
                });
            }
            [strongSelf refresh];
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    }
}

// 面板与主页按钮共用的入口：按"想要的状态"设置，而不是盲目取反。
// 盲目取反在两边状态不同步时会变成"点一下没反应，再点一下才动"。
- (void)setOverlayOn:(BOOL)on {
    if (self.hudMode) {
        BOOL wanted = QFHostFlag(QFPreferencesRead(), @"enabled", NO);
        BOOL running = QFHudIsRunning();
        // 想开但进程还没起（半死状态）时也要放行，让它重新拉一次。
        if (on == (wanted && running) && !(on && !running)) {
            [self refresh];
            return;
        }
        [self applyHudOverlayWanted:on];
        return;
    }
    if (on == self.overlayEnabled) {
        [self refresh];
        return;
    }
    [self toggleOverlay];
}

- (void)toggleOverlay {
    if (self.remoteAvailable) {
        self.overlayEnabled = !self.overlayEnabled;
        NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"enabled"] = @(self.overlayEnabled);
        QFPreferencesWrite(state);
        notify_post(QFChangeNotification);
    } else if (self.hudMode) {
        [self applyHudOverlayWanted:!QFHudIsRunning()];
    } else if (self.usePiP) {
        self.overlayEnabled = !self.overlayEnabled;
        if (self.overlayEnabled) {
            [[QFPiPBar shared] start];
        } else {
            [[QFPiPBar shared] stop];
        }
        // 画中画启动是异步的，隔一下再读真实状态。
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    } else {
        [[QFFloatingBar shared] toggle];
    }
    [self refresh];
}

- (void)alertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleLock {
    self.locked = !self.locked;
    // 插件进程的浮条也读这个键，锁上之后外面那条就拖不动了。
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"locked"] = @(self.locked);
    QFPreferencesWrite(state);
    notify_post(QFChangeNotification);
    [self refresh];
}

- (void)openSettingsPanel {
    QFSettingsPanelController *panel = [QFSettingsPanelController new];
    panel.overlaySupported = (self.remoteAvailable || self.hudMode);
    panel.overlayUnavailableReason = self.usePiP
        ? @"当前是画中画兜底模式，常驻浮窗不可用"
        : @"这台设备没有可用的常驻浮窗通道";
    __weak typeof(self) weakSelf = self;
    panel.overlayVisibleProvider = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        // 状态必须来自"真实探测"，不能读宿主内存里的开关变量：
        // 浮条是独立进程画的，App 被重启 / 从后台恢复过，内存里那个 BOOL 早就和现实脱钩，
        // 于是面板显示「已停止」而屏幕上明明有浮条 —— 用户当然认为面板是假的。
        //
        // ★ 2.1.5：插件模式下要「意图」与「进程」同时成立。
        // 只认进程存活的话，刚点完关闭、进程还在收摊的那几百毫秒里，
        // 面板会把胶囊弹回「开启」，看着像没关掉。
        if (strongSelf.hudMode) {
            BOOL wanted = QFHostFlag(QFPreferencesRead(), @"enabled", NO);
            return wanted && QFHudIsRunning();
        }
        if (strongSelf.remoteAvailable) return strongSelf.overlayEnabled;
        return strongSelf.overlayEnabled;
    };
    panel.onToggleOverlay = ^(BOOL on) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setOverlayOn:on];
    };
    panel.onRestartOverlay = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf restartOverlay];
    };
    panel.onChange = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refresh];
    };

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    navigation.navigationBarHidden = YES;
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigation.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:navigation animated:YES completion:nil];
}

// 面板里的「重启浮窗进程」：杀掉再拉起，换签名或卡住时自救。
- (void)restartOverlay {
    if (self.hudMode) {
        // 用户点「重启浮窗」= 我要它开着。不写这一句的话，关闭状态下重启会立刻又自杀。
        NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"enabled"] = @(YES);
        QFPreferencesWrite(state);
        self.overlayEnabled = YES;
        QFHudTerminate();
        BOOL spawned = QFHudSpawn();
        self.overlayEnabled = spawned;
        if (spawned) self.optimisticUntil = [NSDate timeIntervalSinceReferenceDate] + 4.0;
        if (!spawned) {
            [self alertTitle:@"重启失败" message:@"插件进程没能启动，日志见「查看运行日志」。"];
            return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    } else if (self.remoteAvailable) {
        notify_post(QFResetNotification);
    }
    [self refresh];
}

@end
