# QFOverlay —— 全局拖动 + 常驻显示浮窗模块（自包含）

把 2.1.6 参考里的浮窗核心（常驻窗口托管 + 全局拖动）抽成自包含模块，数据来源解耦：
浮条显示什么文字由宿主工程通过 `+setOverlayText:` 喂入，模块本身不做任何网速/CPU 采样。

> 本仓库是「可直接在 GitHub Actions 上编译出 .tipa」的完整工程。
> `QFOverlay/` 是模块本体，`HostApp/` 只是验证用演示宿主（可整目录删掉换成你自己的 QFSpeed）。

## 目录
- `QFOverlay/QFOverlayHUD.h` / `.m` —— 浮窗模块（常驻 + 拖动全部逻辑）
- `QFOverlay/entitlements.plist` —— 常驻窗口 + 拖动所需关键权限
- `HostApp/` —— 演示 App（按钮拉起浮窗 + 每秒喂一条假网速）
- `build-tipa.sh` —— clang arm64 + ldid 构建脚本
- `.github/workflows/build.yml` —— macOS runner 自动构建并上传 .tipa

## 模块公开接口
```objc
[QFOverlayHUD runPlugin];        // main 里 argv[1]=="-hud" 时调用，永不返回
[QFOverlayHUD spawn];           // 拉起浮窗子进程（posix_spawn 同一二进制 + "-hud"）
[QFOverlayHUD setOverlayText:];  // 宿主喂文字（网速/CPU 等自己算好传进来）
[QFOverlayHUD setEnabled:];
[QFOverlayHUD terminate];
[QFOverlayHUD isRunning];
[QFOverlayHUD resetPosition];
[QFOverlayHUD setLocked:];  [QFOverlayHUD isLocked];
```
浮条交互（模块内，不碰宿主其他功能）：拖动移位置 / 轻点切紧凑·完整 / 长按锁定位置。

## 接入你自己的 QFSpeed（其他不要动）
1. 把 `QFOverlay/` 整目录复制进你的工程。
2. 在你的 `main.m` 加 `-hud` 分流（见 `HostApp/main.m`）：
   ```objc
   if (argc > 1 && strcmp(argv[1], "-hud") == 0) { [QFOverlayHUD runPlugin]; }
   ```
3. 把 `QFOverlay/entitlements.plist` 里的 `application-identifier` 改成你 app 的 bundle id，
   并把这些权限合并进你工程已有的 entitlements（缺 `com.apple.springboard.accessibility-window-hosting`
   或 `platform-application` 时，浮窗常驻会失效，但日志正常）。
4. 把 `QFOverlayHUD.m` 加进主可执行文件的编译源（它是被 `-hud` 子进程复用同一个二进制的）。
5. 在你原来的「开关」逻辑里调 `[QFOverlayHUD spawn]` / `[QFOverlayHUD setOverlayText:...]` / `[QFOverlayHUD terminate]`。
6. `HostApp/` 可整目录删除。

## 本地推到 GitHub（用你给的 PAT）
当前编写环境无外网，仓库已在本地建好并提交，到你**有网的机器**上执行：
```bash
cd QFOverlay-Build
git remote add origin https://<你的PAT>@github.com/1992-02-08/QFOverlay.git
git branch -M main
git push -u origin main
```
（`<你的PAT>` 换成你给我的那个 `ghp_...` token；仓库名 `QFOverlay` 可改。）

## 触发构建
推上去后，到 GitHub 仓库的 **Actions → Build QFOverlay .tipa → Run workflow** 手动触发，
或任意一次 push 到 `main` 会自动触发。产物 `.tipa` 在 Artifacts 里下载，用 TrollStore 安装。

## 验证
装上后打开 App → 点「启动浮窗」→ 应看到浮条常驻；切到别的 App / 锁屏再回来浮条还在；
可拖动、轻点切换、长按锁定。浮条不出现先翻设备日志
`/var/mobile/Library/Logs/QFOverlay.log`，启动时会打一份权限自检。

## 已知边界
- v1.0 的 QFSpeed.ipa 二进制里**本来就没有浮窗代码**，所以这是「移植模块」而非「在原包上修」；
  模块对宿主零侵入，共享偏好走独立域 `com.qfoverlay.module`。
- 真机编译需要 macOS + Xcode SDK + ldid，本仓库的 Actions 已配好；本地沙箱无法编译 iOS。
