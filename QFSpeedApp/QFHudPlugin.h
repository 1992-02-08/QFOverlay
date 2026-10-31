// QFHudPlugin.h —— 「插件进程」模式的常驻浮窗（纯 TrollStore，无需越狱）。
//
// 机制来源：TrollSpeed（ch.xxtou.hudapp）。核心不是「App 在后台活着」，
// 而是一个被 posix_spawn 拉起的第二进程，以 plugin 身份启动（不申请 scene），
// 自建系统窗口，再把窗口的 CAContext 交给 SpringBoard 的辅助功能窗口托管层去合成。
// 细节见 TrollSpeed-Study/TrollSpeed-全局悬浮机制.md。

#import <Foundation/Foundation.h>

// 本机是否具备跑 HUD 插件进程的条件（相关私有类/函数存在）。
BOOL QFHudIsAvailable(void);

// 拉起 `-hud` 子进程（已脱离进程组，父进程退出不影响它）。返回是否成功。
BOOL QFHudSpawn(void);

// 关掉子进程（读 pid 文件 → SIGKILL）。
void QFHudTerminate(void);

// 子进程是否在跑（pid 文件 + kill(pid, 0)）。
BOOL QFHudIsRunning(void);

// 插件模式主循环，由 main() 的 `-hud` 分支调用，正常不返回。
int QFHudRunPlugin(void);
