// QFOverlayHUD.h —— 全局拖动 + 常驻显示的浮窗模块（自包含，可并入任意 App）
//
// 设计目标：只负责两件事——「常驻显示」和「全局拖动」。浮条显示什么文字由宿主工程
// 通过 +setOverlayText: 喂进来，模块本身不做任何网速/CPU 采样，也不碰你工程的其他功能。
//
// 常驻原理：模块在 App 进程内用 posix_spawn 拉起「同一个可执行文件、-hud 参数」的子进程
// （以 root 身份），子进程自建系统窗口（windowLevel=10000000，_isSystemWindow），
// 用 SBSAccessibilityWindowHostingController 把 CAContext 交给 SpringBoard 合成
// —— 切 App / 回桌面 / 锁屏都还在。
//
// 拖动原理：窗口 hitTest: 只把浮条矩形（外扩 12pt）交出去，其余返回 nil 透传；
// 浮条挂 UIPanGestureRecognizer，translationInView: 算位移，clamp 限制在屏内，
// 松手按归一化坐标 nx/ny 记入共享偏好，旋转不丢。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface QFOverlayHUD : NSObject

/// 在 main() 里判断：若 argv[1] == "-hud" 则调用此方法，永不返回。
+ (void)runPlugin;

/// 设备是否支持 SpringBoard 窗口托管（TrollStore / 越狱）。不支持时常驻失效，回退由宿主自行决定。
+ (BOOL)isAvailable;

/// 宿主调用：拉起浮窗子进程（posix_spawn 同一可执行文件 + "-hud"），并写 enabled=YES。返回是否成功发起。
+ (BOOL)spawn;

/// 宿主调用：关闭浮窗。优先发「结束指令」让子进程自清（干净注销窗口），再尽力硬杀。
+ (void)terminate;

/// 浮窗进程是否在运行（台账 + 心跳双判定）。
+ (BOOL)isRunning;

/// 宿主设置浮条显示的文字（网速/CPU 等由你的工程自己算好传进来）。
+ (void)setOverlayText:(NSString *)text;

/// 宿主设置是否开启（写共享偏好 enabled）。
+ (void)setEnabled:(BOOL)enabled;

/// 读取/设置锁定状态（也可在浮条上长按切换）。
+ (BOOL)isLocked;
+ (void)setLocked:(BOOL)locked;

/// 重置浮条位置到默认（下次刷新生效）。
+ (void)resetPosition;

@end

NS_ASSUME_NONNULL_END
