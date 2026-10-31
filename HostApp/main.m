// HostApp 入口：同一个二进制两种身份，靠 argv[1] 分流。
//   无参数  → 正常 App（演示界面）
//   -hud    → 浮窗插件进程（自建系统窗口交给 SpringBoard 合成，退后台/锁屏都还在）
//
// 接入你自己的 QFSpeed 时，把这段 -hud 判断合并进你的 main.m 即可，
// 其余逻辑完全不动。

#import <UIKit/UIKit.h>
#import <string.h>
#import "QFOverlayHUD.h"
#import "AppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) {
            [QFOverlayHUD runPlugin];   // 永不返回
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
