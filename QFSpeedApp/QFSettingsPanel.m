// QFSettingsPanel.m

#import "QFSettingsPanel.h"
#import "QFMetrics.h"
#import "../QFShared.h"

#import <notify.h>

#define QFSPBackground [UIColor blackColor]
#define QFSPCard       [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]
#define QFSPAccent     [UIColor colorWithRed:0.039 green:0.518 blue:1.000 alpha:1.0]
#define QFSPBody       [UIColor whiteColor]
#define QFSPDim        [UIColor colorWithWhite:0.55 alpha:1.0]
#define QFSPLine       [UIColor colorWithWhite:1.0 alpha:0.08]
#define QFSPCheck      [UIColor whiteColor]

#pragma mark - 偏好小工具

static double QFSPNumber(NSDictionary *state, NSString *key, double fallback) {
    id value = state[key];
    return value ? [value doubleValue] : fallback;
}

static BOOL QFSPFlag(NSDictionary *state, NSString *key, BOOL fallback) {
    id value = state[key];
    return value ? [value boolValue] : fallback;
}

// 预览用的文案：与 QFHostComposeText（App 内浮条）、QFHudComposeText（HUD 进程）
// 三处保持同一套规则 —— 有一处不一致，用户就会看到「面板预览是对的、浮条不是」。
static NSString *QFPreviewText(NSDictionary *state) {
    QFMetrics *metrics = [QFMetrics shared];
    BOOL compact = QFSPFlag(state, @"compact", NO);
    BOOL showNetwork = QFSPFlag(state, @"showNetwork", YES);
    BOOL showCPU = QFSPFlag(state, @"showCPU", YES);
    BOOL showMemory = QFSPFlag(state, @"showMemory", YES);
    BOOL showBattery = QFSPFlag(state, @"showBattery", YES);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (showNetwork) {
        NSString *down = [QFMetrics shortRateText:metrics.downloadRate];
        NSString *up = [QFMetrics shortRateText:metrics.uploadRate];
        [parts addObject:compact ? [NSString stringWithFormat:@"↓%@ ↑%@", down, up]
                                 : [NSString stringWithFormat:@"↓%@/s ↑%@/s", down, up]];
    }
    if (showCPU) {
        [parts addObject:compact ? [NSString stringWithFormat:@"%.0f%%", metrics.cpuPercent]
                                 : [NSString stringWithFormat:@"CPU %.0f%%", metrics.cpuPercent]];
    }
    if (showMemory) {
        [parts addObject:[NSString stringWithFormat:@"%.1fG", metrics.memoryGB]];
    }
    if (showBattery) {
        [parts addObject:compact ? [NSString stringWithFormat:@"%ld%%", (long)metrics.batteryPercent]
                                 : [NSString stringWithFormat:@"电量 %ld%%", (long)metrics.batteryPercent]];
    }
    if (parts.count == 0) return @"无显示项";
    return [parts componentsJoinedByString:compact ? @" " : @"  "];
}

// 面板每次写偏好都通过它回报结果：写没写进去是"按了没反应"的第一分岔口，
// 不回报就只能靠猜。设为 nil 时静默（面板关闭后）。
static void (^QFSPWriteFeedback)(BOOL ok, NSString *key);

static BOOL QFSPWrite(NSString *key, id value) {
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[key] = value;
    QFPreferencesWrite(state);
    notify_post(QFChangeNotification);

    // 写完立刻回读。插件进程唯一的信息来源就是这份共享偏好，
    // 一旦写不进去（权限/沙盒/cfprefsd 缓存），浮条永远看不到改动。
    id back = QFPreferencesRead()[key];
    BOOL ok = NO;
    if (back && value) {
        if ([value isKindOfClass:NSNumber.class] && [back isKindOfClass:NSNumber.class]) {
            ok = fabs([back doubleValue] - [value doubleValue]) < 0.001;
        } else {
            ok = [back isEqual:value];
        }
    }
    if (QFSPWriteFeedback) QFSPWriteFeedback(ok, key);
    return ok;
}

#pragma mark - 行：开关

@interface QFSwitchRow : UIView
@property (nonatomic, strong, readonly) UISwitch *toggle;
@property (nonatomic, copy) void (^onChange)(BOOL on);
+ (instancetype)title:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value;
- (void)setOn:(BOOL)on;
- (void)setEnabled:(BOOL)enabled;
@end

@implementation QFSwitchRow

+ (instancetype)title:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value {
    QFSwitchRow *row = [[QFSwitchRow alloc] initWithFrame:CGRectZero];
    [row buildWithTitle:title subtitle:subtitle value:value];
    return row;
}

- (void)buildWithTitle:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    name.textColor = QFSPBody;

    UIStackView *texts = [[UIStackView alloc] initWithFrame:CGRectZero];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3.0;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [texts addArrangedSubview:name];

    if (subtitle.length > 0) {
        UILabel *detail = [[UILabel alloc] initWithFrame:CGRectZero];
        detail.text = subtitle;
        detail.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        detail.textColor = QFSPDim;
        detail.numberOfLines = 0;
        [texts addArrangedSubview:detail];
    }

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = QFSPAccent;
    toggle.on = value;
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    _toggle = toggle;

    [self addSubview:texts];
    [self addSubview:toggle];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:52.0],
        [texts.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [texts.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
        [texts.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12.0],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12.0],
        [toggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [toggle.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

- (void)toggleChanged:(UISwitch *)sender {
    if (self.onChange) self.onChange(sender.isOn);
}

- (void)setOn:(BOOL)on {
    self.toggle.on = on;
}

- (void)setEnabled:(BOOL)enabled {
    self.toggle.enabled = enabled;
    self.alpha = enabled ? 1.0 : 0.42;
}

@end

#pragma mark - 行：可点开关（IPA 原生 iOS Settings.app 风格：图标 + 标签 + 白色勾选圆圈）

// ★ IPA SwiftUI 设置面板样式：每行左侧 SF Symbol 图标（灰色），中间标签（白色 16pt），
//   右侧 checkmark.circle.fill（白色实心圆+对勾）或 circle（空心圆）。
//   无副标题，高度 44pt，完全对齐 iOS Settings.app 列表行。
//   保持整行可点（UITapGestureRecognizer），不依赖 UIControl 事件分发。
@interface QFToggleRow : UIView
@property (nonatomic, copy) void (^onChange)(BOOL on);
@property (nonatomic, assign, readonly) BOOL on;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *onText;
@property (nonatomic, copy) NSString *offText;
+ (instancetype)title:(NSString *)title value:(BOOL)value;
+ (instancetype)title:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
- (void)setSubtitle:(NSString *)subtitle;
- (void)setEnabledRow:(BOOL)enabled;
@end

@implementation QFToggleRow {
    UIImageView *_iconView;
    UILabel *_nameLabel;
    UILabel *_detailLabel;
    UIImageView *_checkIcon;
    UILabel *_toggleLabel;
    BOOL _on;
}

+ (instancetype)title:(NSString *)title value:(BOOL)value {
    return [self title:title subtitle:nil value:value];
}

+ (instancetype)title:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value {
    QFToggleRow *row = [[QFToggleRow alloc] initWithFrame:CGRectZero];
    [row buildWithTitle:title subtitle:subtitle value:value];
    return row;
}

- (void)setIconName:(NSString *)iconName {
    _iconName = [iconName copy];
    if (iconName.length > 0) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIFontWeightRegular];
        _iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
        _iconView.hidden = NO;
    } else {
        _iconView.hidden = YES;
    }
}

- (void)buildWithTitle:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL)value {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.userInteractionEnabled = YES;

    // 左侧图标：灰色 SF Symbol，17pt
    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.hidden = YES;

    // 标签：白色 16pt Regular
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.text = title;
    _nameLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    _nameLabel.textColor = QFSPBody;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // 右侧勾选圆圈
    _checkIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _checkIcon.contentMode = UIViewContentModeScaleAspectFit;
    _checkIcon.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:_iconView];
    [self addSubview:_nameLabel];
    [self addSubview:_checkIcon];

    // IPA 标准行高 44pt
    CGFloat height = 44.0;
    NSMutableArray *constraints = [NSMutableArray arrayWithObjects:
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:height],
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22.0],
        [_iconView.heightAnchor constraintEqualToConstant:22.0],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12.0],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkIcon.leadingAnchor constant:-10.0],
        [_checkIcon.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [_checkIcon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_checkIcon.widthAnchor constraintEqualToConstant:24.0],
        [_checkIcon.heightAnchor constraintEqualToConstant:24.0],
        nil];

    if (subtitle.length > 0) {
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.text = subtitle;
        _detailLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        _detailLabel.textColor = QFSPDim;
        _detailLabel.numberOfLines = 0;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_detailLabel];
        [constraints addObjectsFromArray:@[
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10.0],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2.0],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkIcon.leadingAnchor constant:-10.0],
            [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-10.0],
        ]];
    } else {
        [constraints addObject:[_nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]];
    }

    [NSLayoutConstraint activateConstraints:constraints];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(handleTap)]];
    [self setOn:value animated:NO];
}

- (void)handleTap {
    [self setOn:!_on animated:YES];
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    if (self.onChange) self.onChange(_on);
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    BOOL useText = (self.onText.length > 0 || self.offText.length > 0);
    void (^apply)(void) = ^{
        if (useText) {
            // 文字胶囊模式：显示「开启/关闭」文字，藏在右侧
            self->_checkIcon.hidden = YES;
            if (!self->_toggleLabel) {
                self->_toggleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
                self->_toggleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
                self->_toggleLabel.textAlignment = NSTextAlignmentRight;
                self->_toggleLabel.translatesAutoresizingMaskIntoConstraints = NO;
                [self addSubview:self->_toggleLabel];
                [NSLayoutConstraint activateConstraints:@[
                    [self->_toggleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
                    [self->_toggleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                ]];
            }
            self->_toggleLabel.text = on ? (self.onText ?: @"开启") : (self.offText ?: @"关闭");
            self->_toggleLabel.textColor = on ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.45];
        } else {
            // IPA 勾选圆圈：白色实心圆+对勾（开）/ 灰色空心圆（关）
            self->_checkIcon.hidden = NO;
            self->_toggleLabel.hidden = YES;
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIFontWeightMedium];
            self->_checkIcon.image = [UIImage systemImageNamed:(on ? @"checkmark.circle.fill" : @"circle")
                                            withConfiguration:config];
            self->_checkIcon.tintColor = on ? [UIColor whiteColor] : [UIColor colorWithWhite:1.0 alpha:0.25];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.16 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)setSubtitle:(NSString *)subtitle {
    if (!_detailLabel && subtitle.length > 0) {
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        _detailLabel.textColor = QFSPDim;
        _detailLabel.numberOfLines = 0;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_detailLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2.0],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkIcon.leadingAnchor constant:-10.0],
        ]];
    }
    _detailLabel.text = subtitle;
}

- (void)setEnabledRow:(BOOL)enabled {
    self.userInteractionEnabled = enabled;
    self.alpha = enabled ? 1.0 : 0.45;
}

@end

#pragma mark - 行：滑杆（IPA 风格：标签+数值同一行，滑杆在下方）

@interface QFSliderRow : UIView
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, copy) NSString *(^formatter)(double value);
@property (nonatomic, copy) void (^onChange)(double value);
@property (nonatomic, assign) double pendingValue;
+ (instancetype)title:(NSString *)title minimum:(double)minimum maximum:(double)maximum value:(double)value;
- (void)setValue:(double)value;
@end

@implementation QFSliderRow

+ (instancetype)title:(NSString *)title minimum:(double)minimum maximum:(double)maximum value:(double)value {
    QFSliderRow *row = [[QFSliderRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    name.textColor = QFSPBody;
    name.translatesAutoresizingMaskIntoConstraints = NO;

    row.valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    row.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
    row.valueLabel.textColor = QFSPDim;
    row.valueLabel.textAlignment = NSTextAlignmentRight;
    row.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.minimumValue = (float)minimum;
    slider.maximumValue = (float)maximum;
    slider.value = (float)value;
    slider.minimumTrackTintColor = QFSPAccent;
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:row action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    row.slider = slider;

    [row addSubview:name];
    [row addSubview:row.valueLabel];
    [row addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:12.0],
        [row.valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [row.valueLabel.centerYAnchor constraintEqualToAnchor:name.centerYAnchor],
        [row.valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:10.0],
        [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14.0],
        [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [slider.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:6.0],
        [slider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10.0],
    ]];

    row.formatter = ^NSString *(double value) { return [NSString stringWithFormat:@"%.1f", value]; };
    [row setValue:value];
    return row;
}

- (void)sliderChanged:(UISlider *)sender {
    double value = (double)sender.value;
    [self refreshLabel:value];
    self.pendingValue = value;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(commitPendingValue)
                                               object:nil];
    [self performSelector:@selector(commitPendingValue) withObject:nil afterDelay:0.25];
}

- (void)commitPendingValue {
    if (self.onChange) self.onChange(self.pendingValue);
}

- (void)refreshLabel:(double)value {
    self.valueLabel.text = self.formatter ? self.formatter(value) : [NSString stringWithFormat:@"%.1f", value];
}

- (void)setValue:(double)value {
    self.slider.value = (float)value;
    [self refreshLabel:value];
}

@end

#pragma mark - 行：可点

@interface QFTapRow : UIView
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, strong) UILabel *textLabel;
+ (instancetype)title:(NSString *)title symbol:(NSString *)symbol destructive:(BOOL)destructive;
@end

@implementation QFTapRow

+ (instancetype)title:(NSString *)title symbol:(NSString *)symbol destructive:(BOOL)destructive {
    QFTapRow *row = [[QFTapRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.userInteractionEnabled = YES;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = destructive ? [UIColor colorWithRed:0.95 green:0.36 blue:0.34 alpha:1.0] : QFSPBody;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat red = 0.95, green = 0.36, blue = 0.34;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    label.textColor = destructive ? [UIColor colorWithRed:red green:green blue:blue alpha:1.0] : QFSPBody;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    row.textLabel = label;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;

    [row addSubview:icon];
    [row addSubview:label];
    [row addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:52.0],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:18.0],
        [icon.heightAnchor constraintEqualToConstant:18.0],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12.0],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:8.0],
        [chevron.heightAnchor constraintEqualToConstant:13.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10.0],
    ]];

    [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:row action:@selector(handleTap)]];
    return row;
}

- (void)handleTap {
    [UIView animateWithDuration:0.1 animations:^{
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            self.backgroundColor = UIColor.clearColor;
        }];
    }];
    if (self.action) self.action();
}

@end

#pragma mark - 日志查看

@interface QFLogViewController : UIViewController
@end

@implementation QFLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFSPBackground;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"运行日志";
    title.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = QFSPDim;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.backgroundColor = QFSPCard;
    textView.textColor = QFSPBody;
    textView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    textView.editable = NO;
    textView.layer.cornerRadius = 14.0;
    textView.layer.cornerCurve = kCACornerCurveContinuous;
    textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.text = [self logTail];
    [self.view addSubview:textView];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制" forState:UIControlStateNormal];
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    [copy addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copy];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    [clear setTitleColor:[UIColor colorWithRed:0.95 green:0.36 blue:0.34 alpha:1.0] forState:UIControlStateNormal];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14.0],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [close.widthAnchor constraintEqualToConstant:32.0],
        [close.heightAnchor constraintEqualToConstant:32.0],

        [copy.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [copy.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [clear.centerYAnchor constraintEqualToAnchor:copy.centerYAnchor],
        [clear.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],

        [textView.topAnchor constraintEqualToAnchor:copy.bottomAnchor constant:10.0],
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16.0],
    ]];
}

- (NSString *)logTail {
    // 主路径（/var/mobile/Library/Logs）和沙盒兜底合并读：设备上沙盒没放开时只有后者有内容，
    // 以前只读主路径，于是"根本没有日志"，连排查入口都没有。
    NSString *content = QFLogReadAll();
    if (content.length == 0) {
        return @"（还没有日志）\n\n"
               @"这条信息本身就是结论：浮窗进程一次都没成功启动，或者启动后被系统立刻杀掉。\n"
               @"先回主页点一次「开启常驻浮窗」，再回来看这一页。";
    }
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    if (lines.count > 400) {
        lines = [lines subarrayWithRange:NSMakeRange(lines.count - 400, 400)];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string = [self logTail];
    for (UIView *view in self.view.subviews) {
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            if ([button titleForState:UIControlStateNormal].length > 0 &&
                ![[button titleForState:UIControlStateNormal] isEqualToString:@"清空"]) {
                [button setTitle:@"已复制 ✓" forState:UIControlStateNormal];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [button setTitle:@"复制" forState:UIControlStateNormal];
                });
            }
        }
    }
}

- (void)clearLog {
    [[NSFileManager defaultManager] removeItemAtPath:@QFLogFilePath error:nil];
    NSString *fallbackPath = QFLogFallbackPath();
    if (fallbackPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:fallbackPath error:nil];
    }
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 面板

@interface QFSettingsPanelController ()
@property (nonatomic, strong) UISwitch *overlayToggle;
@property (nonatomic, strong) QFToggleRow *compactSwitch;
// 常驻浮窗那一行：点完要用真实状态回填，不能只靠本地翻转。
@property (nonatomic, strong) QFToggleRow *overlayRow;
@property (nonatomic, strong) QFSliderRow *alphaRow;
@property (nonatomic, strong) QFSliderRow *fontRow;
@property (nonatomic, strong) UILabel *feedbackLabel;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UILabel *digestLabel;
@property (nonatomic, strong) NSMutableDictionary *editing;
@property (nonatomic, assign) NSUInteger feedbackGeneration;
@end

@implementation QFSettingsPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFSPBackground;

    // 写偏好的结果统一回显：写进去了 / 没写进去，用户当场就能看见。
    __weak typeof(self) panelWeak = self;
    QFSPWriteFeedback = ^(BOOL ok, NSString *key) {
        __strong typeof(panelWeak) panel = panelWeak;
        if (!panel) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            panel.feedbackGeneration++;
            NSUInteger generation = panel.feedbackGeneration;
            panel.feedbackLabel.textColor = ok
                ? [UIColor colorWithRed:0.24 green:0.78 blue:0.45 alpha:1.0]
                : [UIColor colorWithRed:0.95 green:0.36 blue:0.34 alpha:1.0];
            panel.feedbackLabel.text = ok
                ? [NSString stringWithFormat:@"✔︎ 已写入 %@ · 浮条 1 秒内更新", key]
                : [NSString stringWithFormat:@"✗ %@ 没写进去，改动不会生效", key];
            if (!ok) QFLogFormat(@"面板写入失败 key=%@", key);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (panel.feedbackGeneration != generation) return;
                panel.feedbackLabel.text = @"";
            });
        });
    };

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = YES;
    // ★ 2.1.3：这两行是"开关按不动"的系统性原因，不是可选项。
    // delaysContentTouches 默认 YES：手指落在滚动视图里的控件上时，系统先等约 150ms
    // 判断这是不是一次滚动，期间的点击事件不会送给控件。开关（尤其 UISwitch）
    // 因此经常整次点击都被吞掉。关掉它，控件优先拿到触摸。
    scroll.delaysContentTouches = NO;
    scroll.canCancelContentTouches = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    // 面板自己的配置副本：预览要"点一下立刻变"，不能等偏好回读。
    self.editing = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24.0],
    ]];

    // 标题栏
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"QFSpeed";
    title.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.text = @"浮窗设置 · 改完立刻生效";
    subtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitle.textColor = QFSPDim;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;

    // 每次改动都回显结果：写进去了 / 没写进去，用户不用猜，也不用等下一版问"为什么没反应"。
    UILabel *feedback = [[UILabel alloc] initWithFrame:CGRectZero];
    feedback.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    feedback.textColor = QFSPAccent;
    feedback.text = @"";
    feedback.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:feedback];
    self.feedbackLabel = feedback;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];

    [header addSubview:title];
    [header addSubview:subtitle];
    [header addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:8.0],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [feedback.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:3.0],
        [feedback.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [feedback.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8.0],
        [feedback.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [close.widthAnchor constraintEqualToConstant:30.0],
        [close.heightAnchor constraintEqualToConstant:30.0],
    ]];
    [stack addArrangedSubview:header];
    [stack setCustomSpacing:18.0 afterView:header];

    NSDictionary *state = QFPreferencesRead();
    __weak typeof(self) weakSelf = self;

    // ── 常驻浮窗：只显示状态。
    // 开关放在主页那一个按钮上就够了，这里再来一个开关等于同一件事有两个入口，
    // 两边状态一旦不同步就是"点了看不出变化"，所以面板里不重复放开关。
    [stack addArrangedSubview:[self sectionTitle:@"常驻浮窗"]];

    // ── 常驻浮窗：这里就是开关本身。
    //
    // 2.1.4 之前这一行只写"运行状态"，开关只放在主页那个按钮上。
    // 用户进到设置页看到「常驻浮窗」四个字，下意识就去点它 —— 点不动，又是一次"没反应"。
    // 现在这行自己就是开关：右侧胶囊「开启 / 关闭」，点完整行翻转，和主页按钮走同一个动作。
    BOOL running = self.overlayVisibleProvider ? self.overlayVisibleProvider() : NO;
    NSString *statusText;
    if (!self.overlaySupported) {
        statusText = self.overlayUnavailableReason.length > 0
            ? self.overlayUnavailableReason
            : @"当前设备没有可用的常驻浮窗通道";
    } else if (running) {
        statusText = @"运行中 —— 点右侧「关闭」，浮条立刻消失";
    } else {
        statusText = @"已停止 —— 点右侧「开启」，浮条立刻出现";
    }
    QFToggleRow *overlayRow = [QFToggleRow title:@"常驻浮窗" subtitle:statusText value:running];
    overlayRow.iconName = @"rectangle.dashed.badge.record";
    overlayRow.onText = @"开启";
    overlayRow.offText = @"关闭";
    [overlayRow setEnabledRow:self.overlaySupported];
    overlayRow.onChange = ^(BOOL on) {
        if (weakSelf.onToggleOverlay) weakSelf.onToggleOverlay(on);
        // 1.4 秒后按真实状态回填。拉起进程 / 让它退出都需要一点时间，
        // 只信本地翻转会出现"胶囊写着开启、屏幕上其实什么都没有"。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf.overlayRow || !strongSelf.overlayVisibleProvider) return;
            BOOL now = strongSelf.overlayVisibleProvider();
            [strongSelf.overlayRow setOn:now animated:YES];
            [strongSelf.overlayRow setSubtitle:(now
                ? @"运行中 —— 点右侧「关闭」，浮条立刻消失"
                : @"已停止 —— 点右侧「开启」，浮条立刻出现")];
        });
    };
    self.overlayRow = overlayRow;

    // 1.9.0：把"系统到底认没认我们的权限"直接摊在面板上。
    // 浮条不显示时，90% 的原因在这一行就写死了 —— 不用再去翻日志。
    BOOL hosting = QFHasEntitlement(@"com.apple.springboard.accessibility-window-hosting");
    NSString *permissionText = QFEntitlementsSummary();
    if (!hosting) {
        permissionText = [permissionText stringByAppendingString:
                          @"\n缺少窗口托管权限：浮条注册会被 SpringBoard 直接丢弃"];
    }
    UIView *permissionRow = [self infoRow:@"权限自检"
                                    value:permissionText
                                    color:hosting ? [UIColor colorWithWhite:0.42 alpha:1.0]
                                                  : [UIColor systemRedColor]];

    NSString *hint = self.overlaySupported
        ? @"这里和主页那个按钮是同一个开关，点哪个都行。"
        : (self.overlayUnavailableReason.length > 0
              ? self.overlayUnavailableReason
              : @"当前设备没有可用的常驻浮窗通道");
    [stack addArrangedSubview:[self cardWithRows:@[overlayRow, permissionRow, [self noteRow:hint]]]];

    // ── 显示内容
    [stack addArrangedSubview:[self sectionTitle:@"显示项目"]];

    QFToggleRow *compactRow = [QFToggleRow title:@"紧凑模式"
                                        subtitle:@"只省略单位与标签，不隐藏项目"
                                           value:QFSPFlag(state, @"compact", NO)];
    compactRow.iconName = @"text.alignleft";
    compactRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"compact" value:@(on)];
    };
    self.compactSwitch = compactRow;

    QFToggleRow *netRow = [QFToggleRow title:@"网速"
                                      value:QFSPFlag(state, @"showNetwork", YES)];
    netRow.iconName = @"wifi";
    netRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showNetwork" value:@(on)];
    };

    QFToggleRow *cpuRow = [QFToggleRow title:@"CPU 占用"
                                      value:QFSPFlag(state, @"showCPU", YES)];
    cpuRow.iconName = @"cpu";
    cpuRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showCPU" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *memRow = [QFToggleRow title:@"内存占用"
                                      value:QFSPFlag(state, @"showMemory", YES)];
    memRow.iconName = @"memorychip";
    memRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showMemory" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *batteryRow = [QFToggleRow title:@"电池电量"
                                          value:QFSPFlag(state, @"showBattery", YES)];
    batteryRow.iconName = @"battery.100";
    batteryRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showBattery" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *fpsRow = [QFToggleRow title:@"FPS 帧率"
                                       value:QFSPFlag(state, @"showFPS", YES)];
    fpsRow.iconName = @"gauge";
    fpsRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showFPS" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *voltRow = [QFToggleRow title:@"电压"
                                        value:QFSPFlag(state, @"showVoltage", YES)];
    voltRow.iconName = @"bolt";
    voltRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showVoltage" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *ampRow = [QFToggleRow title:@"电流"
                                       value:QFSPFlag(state, @"showAmpere", YES)];
    ampRow.iconName = @"waveform.path.ecg";
    ampRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showAmpere" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *wattRow = [QFToggleRow title:@"瓦特"
                                        value:QFSPFlag(state, @"showWatt", YES)];
    wattRow.iconName = @"bolt.fill";
    wattRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showWatt" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    QFToggleRow *tempRow = [QFToggleRow title:@"温度"
                                        value:QFSPFlag(state, @"showTemp", YES)];
    tempRow.iconName = @"thermometer";
    tempRow.onChange = ^(BOOL on) {
        [weakSelf writeKey:@"showTemp" value:@(on)];
        if (on) [weakSelf leaveCompactMode];
    };

    [stack addArrangedSubview:[self cardWithRows:@[compactRow, cpuRow, fpsRow, netRow, memRow, batteryRow, voltRow, ampRow, wattRow, tempRow]]];
    [self refreshPreview];

    // ── 外观
    [stack addArrangedSubview:[self sectionTitle:@"外观"]];

    // 下限 0.18 而不是 0：之前允许拉到 0，拉到底的后果就是浮条完全消失
    // （日志实测 bg=0.00，屏幕上看不到任何东西）。全透明没有使用意义。
    QFSliderRow *alphaRow = [QFSliderRow title:@"背景不透明度" minimum:0.18 maximum:1.0
                                         value:QFSPNumber(state, @"bgAlpha", 0.38)];
    alphaRow.formatter = ^NSString *(double value) {
        return [NSString stringWithFormat:@"%.0f%%", value * 100.0];
    };
    alphaRow.onChange = ^(double value) { QFSPWrite(@"bgAlpha", @(value)); };
    [alphaRow setValue:QFSPNumber(state, @"bgAlpha", 0.38)];
    self.alphaRow = alphaRow;

    QFSliderRow *fontRow = [QFSliderRow title:@"字体大小" minimum:8.0 maximum:20.0
                                        value:QFSPNumber(state, @"fontSize", 11.5)];
    fontRow.formatter = ^NSString *(double value) { return [NSString stringWithFormat:@"%.1f pt", value]; };
    fontRow.onChange = ^(double value) { QFSPWrite(@"fontSize", @(value)); };
    [fontRow setValue:QFSPNumber(state, @"fontSize", 11.5)];
    self.fontRow = fontRow;

    [stack addArrangedSubview:[self cardWithRows:@[alphaRow, fontRow]]];

    // ── 行为
    [stack addArrangedSubview:[self sectionTitle:@"行为"]];

    QFToggleRow *rotateRow = [QFToggleRow title:@"跟随屏幕旋转"
                                        subtitle:@"横屏看视频时浮条跟着转正"
                                           value:QFSPFlag(state, @"followRotation", YES)];
    rotateRow.iconName = @"arrow.triangle.2.circlepath";
    rotateRow.onChange = ^(BOOL on) { [weakSelf writeKey:@"followRotation" value:@(on)]; };

    QFToggleRow *hideRow = [QFToggleRow title:@"横屏时隐藏"
                                      subtitle:@"全屏看电影时自动收起浮条"
                                         value:QFSPFlag(state, @"hideInLandscape", NO)];
    hideRow.iconName = @"eye.slash";
    hideRow.onChange = ^(BOOL on) { [weakSelf writeKey:@"hideInLandscape" value:@(on)]; };

    QFToggleRow *lockRow = [QFToggleRow title:@"锁定位置"
                                      subtitle:@"锁住后拖不动；浮条上长按 0.55 秒可随时切换"
                                         value:QFSPFlag(state, @"locked", NO)];
    lockRow.iconName = @"lock";
    lockRow.onChange = ^(BOOL on) { [weakSelf writeKey:@"locked" value:@(on)]; };

    [stack addArrangedSubview:[self cardWithRows:@[rotateRow, hideRow, lockRow]]];

    // ── 操作
    [stack addArrangedSubview:[self sectionTitle:@"操作"]];

    QFTapRow *resetRow = [QFTapRow title:@"重置浮条位置" symbol:@"arrow.counterclockwise" destructive:NO];
    resetRow.action = ^{
        NSMutableDictionary *mutable = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
        [mutable removeObjectForKey:@"nx"];
        [mutable removeObjectForKey:@"ny"];
        [mutable removeObjectForKey:@"x"];
        [mutable removeObjectForKey:@"y"];
        QFPreferencesWrite(mutable);
        notify_post(QFResetNotification);
        if (weakSelf.onChange) weakSelf.onChange();
    };

    QFTapRow *restartRow = [QFTapRow title:@"重启浮窗进程" symbol:@"arrow.triangle.2.circlepath" destructive:NO];
    restartRow.action = ^{
        if (weakSelf.onRestartOverlay) weakSelf.onRestartOverlay();
        if (weakSelf.onChange) weakSelf.onChange();
    };

    QFTapRow *logRow = [QFTapRow title:@"查看运行日志" symbol:@"doc.text.magnifyingglass" destructive:NO];
    logRow.action = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        QFLogViewController *log = [QFLogViewController new];
        log.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:log animated:YES completion:nil];
    };

    [stack addArrangedSubview:[self cardWithRows:@[resetRow, restartRow, logRow]]];

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectZero];
    footer.text = @"提示：浮条拖动后位置会记住；横竖屏各存一份比例位置，转屏不会跑出屏幕。";
    footer.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    footer.textColor = QFSPDim;
    footer.numberOfLines = 0;
    [stack addArrangedSubview:footer];
}

#pragma mark 构建小件

#pragma mark 写入与预览

// 所有开关走这一条路：先更新面板自己的副本（预览立刻变），再写共享偏好，
// 最后通知宿主重绘。任何一步失败都会在 feedbackLabel 上写明，不靠猜。
- (void)writeKey:(NSString *)key value:(id)value {
    if (!self.editing) self.editing = [NSMutableDictionary dictionary];
    self.editing[key] = value;
    QFSPWrite(key, value);
    [self refreshPreview];
    if (self.onChange) self.onChange();
}

// 想看 CPU / 内存 / 电量就别停在紧凑里：紧凑是"更短"，不是"只剩网速"。
- (void)leaveCompactMode {
    if (![self.editing[@"compact"] boolValue]) return;
    [self.compactSwitch setOn:NO animated:YES];
    [self writeKey:@"compact" value:@(NO)];
}

- (UIView *)previewRow {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectZero];
    caption.text = @"浮条预览";
    caption.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    caption.textColor = QFSPDim;
    caption.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
    value.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    value.textColor = QFSPBody;
    value.numberOfLines = 0;
    value.text = @"";
    value.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewLabel = value;

    [row addSubview:caption];
    [row addSubview:value];
    [NSLayoutConstraint activateConstraints:@[
        [caption.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [caption.topAnchor constraintEqualToAnchor:row.topAnchor constant:12.0],
        [value.leadingAnchor constraintEqualToAnchor:caption.leadingAnchor],
        [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [value.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:6.0],
        [value.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12.0],
    ]];
    return row;
}

- (void)refreshPreview {
    NSDictionary *state = self.editing ?: QFPreferencesRead();
    if (self.previewLabel) self.previewLabel.text = QFPreviewText(state);
    if (self.digestLabel) {
        NSMutableString *digest = [NSMutableString string];
        for (NSString *key in @[@"showNetwork", @"showCPU", @"showMemory", @"showBattery", @"compact"]) {
            id value = state[key];
            [digest appendFormat:@"%@=%@  ", key, value ? [value stringValue] : @"空"];
        }
        self.digestLabel.text = digest;
    }
}

- (UIView *)digestRow {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = @"读到配置";
    name.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    name.textColor = QFSPDim;
    name.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
    value.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    value.textColor = [UIColor colorWithWhite:0.44 alpha:1.0];
    value.numberOfLines = 0;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    self.digestLabel = value;

    [row addSubview:name];
    [row addSubview:value];
    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:10.0],
        [value.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
        [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [value.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:4.0],
        [value.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10.0],
    ]];
    return row;
}

- (UILabel *)sectionTitle:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.textColor = QFSPDim;
    label.text = [NSString stringWithFormat:@"  %@", text];
    return label;
}

- (UIView *)infoRow:(NSString *)title value:(NSString *)value color:(UIColor *)color {
    UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    name.textColor = QFSPBody;
    name.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectZero];
    detail.text = value;
    detail.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    detail.textColor = color ?: QFSPBody;
    detail.textAlignment = NSTextAlignmentRight;
    detail.translatesAutoresizingMaskIntoConstraints = NO;

    [row addSubview:name];
    [row addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:48.0],
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16.0],
        [detail.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:10.0],
    ]];
    return row;
}

- (UIView *)noteRow:(NSString *)text {
    UIView *wrapper = [[UIView alloc] initWithFrame:CGRectZero];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    label.textColor = QFSPDim;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:wrapper.topAnchor constant:2.0],
        [label.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor constant:16.0],
        [label.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor constant:-16.0],
        [label.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor constant:-14.0],
    ]];
    return wrapper;
}

- (UIView *)cardWithRows:(NSArray<UIView *> *)rows {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = QFSPCard;
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (NSUInteger index = 0; index < rows.count; index++) {
        if (index > 0) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectZero];
            line.backgroundColor = QFSPLine;
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
            UIView *wrapper = [[UIView alloc] initWithFrame:CGRectZero];
            wrapper.translatesAutoresizingMaskIntoConstraints = NO;
            [wrapper addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor constant:16.0],
                [line.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
                [line.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
                [line.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
            ]];
            [stack addArrangedSubview:wrapper];
        }
        [stack addArrangedSubview:rows[index]];
    }
    return card;
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
