// QFSpeed 独立 App（tipa）入口。
//
// 同一个可执行文件有两种身份，靠 argv[1] 分流（照 TrollSpeed 的做法）：
//   无参数     → 正常 App（设置界面 + 开关）
//   -hud       → 插件进程：不申请 scene，自建系统窗口交给 SpringBoard 合成，所以退后台/锁屏都还在
//   -exit      → 让 HUD 进程退出（主 App 用）
//   -check     → 探测 HUD 是否在跑，用退出码回传（主 App 用）

#import <UIKit/UIKit.h>
#import <string.h>

#import "QFHostController.h"
#import "QFHudPlugin.h"
#import "../QFShared.h"

@interface QFAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation QFAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // App 和浮窗进程是同一个二进制、同一份签名，所以这里读到的权限就是浮窗进程的权限。
    // 先把结论写进日志：万一浮条不出现，第一眼就能分清是权限问题还是窗口问题。
    QFLogFormat(@"App 启动 %@ 权限自检：%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                QFEntitlementsSummary());

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    QFHostController *controller = [QFHostController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.navigationBarHidden = YES;
    navigation.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            if (strcmp(argv[1], "-hud") == 0) {
                return QFHudRunPlugin();
            }
            if (strcmp(argv[1], "-exit") == 0) {
                QFHudTerminate();
                return EXIT_SUCCESS;
            }
            if (strcmp(argv[1], "-check") == 0) {
                return QFHudIsRunning() ? EXIT_FAILURE : EXIT_SUCCESS;
            }
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(QFAppDelegate.class));
    }
}
