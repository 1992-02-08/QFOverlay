// QFHostController —— QFSpeed 主界面。
//
// 两种运行模式：
//   1. 设备装了 com.wacljcr.qfoverlay（越狱）→ 浮窗由 SpringBoard 画，切 App / 锁屏都在，
//      这里的按钮只是遥控器；
//   2. 没装（只有 TrollStore）→ 退化成在本 App 内画浮条，退出 App 就没了。
// 启动时 ping 一下 SpringBoard 侧，有回应走 1，没回应走 2。

#import <UIKit/UIKit.h>

@interface QFHostController : UIViewController
@end
