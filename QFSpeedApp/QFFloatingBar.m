#import "QFFloatingBar.h"

static NSString *const QFBarXKey = @"bar.x";
static NSString *const QFBarYKey = @"bar.y";

@interface QFBarWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation QFBarWindow

// 只有落在浮条上的点才由这个窗口接收，其余全部透传，不然整个 App 都点不动。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = self.interactiveView;
    if (target && target.window == self && !target.hidden && target.alpha > 0.01) {
        CGPoint local = [target convertPoint:point fromView:self];
        if ([target pointInside:local withEvent:event]) {
            return [super hitTest:point withEvent:event];
        }
    }
    return nil;
}

@end

@interface QFBarView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@end

@implementation QFBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // IPA 样式：胶囊形 + 毛玻璃
        self.layer.cornerRadius = frame.size.height / 2.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        self.layer.masksToBounds = YES;
        self.userInteractionEnabled = YES;

        _blurView = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.97];
        _label.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
    self.label.frame = CGRectInset(self.bounds, 14.0, 3.0);
}

- (void)sizeToText {
    CGSize fitted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGPoint center = self.center;
    CGRect bounds = self.bounds;
    bounds.size = CGSizeMake(MAX(ceil(fitted.width) + 28.0, 80.0), MAX(ceil(fitted.height) + 10.0, 28.0));
    self.bounds = bounds;
    self.center = center;
    [self setNeedsLayout];
}

@end

@interface QFFloatingBar () <UIGestureRecognizerDelegate>
@end

@implementation QFFloatingBar {
    QFBarWindow *_window;
    QFBarView *_bar;
    UIPanGestureRecognizer *_pan;
}

+ (QFFloatingBar *)shared {
    static QFFloatingBar *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [QFFloatingBar new];
    });
    return instance;
}

- (BOOL)isVisible {
    return _window != nil && !_window.hidden;
}

- (UIWindowScene *)hostScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (void)show {
    if (self.isVisible) {
        _window.hidden = NO;
        return;
    }
    UIWindowScene *scene = [self hostScene];
    if (!scene) return;

    if (!_window) {
        _window = [[QFBarWindow alloc] initWithWindowScene:scene];
        _window.windowLevel = 1000001.0;
        _window.backgroundColor = UIColor.clearColor;
        _window.opaque = NO;
        _window.rootViewController = [UIViewController new];
        _window.rootViewController.view.backgroundColor = UIColor.clearColor;

        _bar = [[QFBarView alloc] initWithFrame:CGRectMake(0, 0, 200, 26)];
        NSDictionary *ia = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.97]};
        _bar.label.attributedText = [[NSAttributedString alloc] initWithString:@"0B \u2502 0B" attributes:ia];
        [_bar sizeToText];
        [_window.rootViewController.view addSubview:_bar];
        _window.interactiveView = _bar;

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [_bar addGestureRecognizer:_pan];
        [_bar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)]];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        double savedX = [defaults doubleForKey:QFBarXKey];
        double savedY = [defaults doubleForKey:QFBarYKey];
        CGSize screen = [UIScreen mainScreen].bounds.size;
        _bar.center = (savedX > 1 && savedY > 1) ? CGPointMake(savedX, savedY)
                                                 : CGPointMake(screen.width / 2.0, 96.0);
    } else {
        _window.windowScene = scene;
    }

    _window.hidden = NO;
    [_window layoutIfNeeded];
    [self clampBar];
}

- (void)hide {
    _window.hidden = YES;
}

- (void)toggle {
    if (self.isVisible) {
        [self hide];
    } else {
        [self show];
    }
}

- (void)updateText:(NSAttributedString *)text {
    if (!_bar) return;
    _bar.label.attributedText = text;
    [_bar sizeToText];
    [self clampBar];
}

- (void)resetPosition {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    _bar.center = CGPointMake(screen.width / 2.0, 96.0);
    [self persistPosition];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    self.compact = !self.compact;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"QFFloatingBarTapped" object:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!_bar || self.locked) return;
    CGPoint translation = [gesture translationInView:_window];
    CGPoint center = _bar.center;
    center.x += translation.x;
    center.y += translation.y;
    _bar.center = center;
    [gesture setTranslation:CGPointZero inView:_window];
    [self clampBar];
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [self persistPosition];
    }
}

- (void)clampBar {
    if (!_bar || !_window) return;
    CGRect bounds = _window.bounds;
    if (bounds.size.width < 1) return;
    UIEdgeInsets safe = _window.safeAreaInsets;
    CGSize size = _bar.bounds.size;
    CGPoint center = _bar.center;
    center.x = MAX(size.width / 2.0 + safe.left + 2.0,
                   MIN(bounds.size.width - size.width / 2.0 - safe.right - 2.0, center.x));
    center.y = MAX(size.height / 2.0 + safe.top + 2.0,
                   MIN(bounds.size.height - size.height / 2.0 - safe.bottom - 2.0, center.y));
    _bar.center = center;
}

- (void)persistPosition {
    if (!_bar) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:_bar.center.x forKey:QFBarXKey];
    [defaults setDouble:_bar.center.y forKey:QFBarYKey];
    [defaults synchronize];
}

@end
