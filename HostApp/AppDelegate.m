#import "AppDelegate.h"
#import "QFOverlayHUD.h"

// 这是一个「验证用宿主」：只负责两件事——拉起浮窗、喂文字。
// 真实接入时把 QFOverlay/ 放进你自己的 QFSpeed 工程，删掉整个 HostApp/ 即可，
// 只在你的 main.m 里加 -hud 分流（见 README）和调用 [QFOverlayHUD spawn]/setOverlayText:。

@interface DemoVC : UIViewController
@property (nonatomic, strong) NSTimer *feedTimer;
@end

@implementation DemoVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIStackView *sv = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 280, 160)];
    sv.axis = UILayoutConstraintAxisVertical;
    sv.spacing = 16;
    sv.alignment = UIStackViewAlignmentCenter;
    sv.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    sv.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:sv];

    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
    [start setTitle:@"启动浮窗" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(startHUD) forControlEvents:UIControlEventTouchUpInside];

    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"关闭浮窗" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(stopHUD) forControlEvents:UIControlEventTouchUpInside];

    [sv addArrangedSubview:start];
    [sv addArrangedSubview:stop];

    UILabel *hint = [[UILabel alloc] init];
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = [QFOverlayHUD isAvailable]
        ? @"已支持 SpringBoard 窗口托管：浮窗切 App / 锁屏都在。浮条可拖动、轻点切紧凑、长按锁定。"
        : @"当前设备不支持窗口托管（需 TrollStore / 越狱），浮窗常驻会失效。";
    [sv addArrangedSubview:hint];
}

- (void)startHUD {
    [QFOverlayHUD spawn];
    [self startFeeding];
}

- (void)stopHUD {
    [QFOverlayHUD terminate];
    [self.feedTimer invalidate];
    self.feedTimer = nil;
}

// 模拟「宿主算好网速再喂给浮条」——模块本身不做任何采样，文字完全由宿主决定。
- (void)startFeeding {
    [self.feedTimer invalidate];
    self.feedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        double mbps = (double)(arc4random_uniform(9000)) / 1000.0;
        [QFOverlayHUD setOverlayText:[NSString stringWithFormat:@"↓ %.2f MB/s", mbps]];
    }];
}

@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[DemoVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
