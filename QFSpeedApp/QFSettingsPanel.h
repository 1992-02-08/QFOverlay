// QFSettingsPanel.h
// App 内的「浮窗设置」面板。
//
// 之前点「设置面板」只弹一句"没有设置面板"（因为 1.3.0 以为设置只能在越狱插件里做），
// 用户点了等于没反应。现在面板直接长在 App 里：写共享偏好 + 发通知，插件进程收到后实时生效。
// 越狱 deb 的 SpringBoard 浮窗读的是同一套键，所以两种模式共用这个面板。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface QFSettingsPanelController : UIViewController

// 开关常驻浮窗。参数是"想要的状态"，各模式动作不同（插件进程 spawn / SpringBoard 侧改偏好），交给宿主做。
@property (nonatomic, copy, nullable) void (^onToggleOverlay)(BOOL on);
// 重启浮窗进程（换签名后重新拉起 / 卡住时自救）。
@property (nonatomic, copy, nullable) void (^onRestartOverlay)(void);
// 面板打开时回填"常驻浮窗"开关的真实状态。
@property (nonatomic, copy, nullable) BOOL (^overlayVisibleProvider)(void);
// 是否有常驻浮窗可用（插件进程或越狱 deb）。没有就把开关置灰并说明原因。
@property (nonatomic, assign) BOOL overlaySupported;
@property (nonatomic, copy, nullable) NSString *overlayUnavailableReason;
// 任何设置变化后回调，宿主用来自刷界面。
@property (nonatomic, copy, nullable) void (^onChange)(void);

@end

NS_ASSUME_NONNULL_END
