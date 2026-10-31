# QFSpeed —— 全功能常驻浮窗（网速 / CPU / 信号 / 设置 / 图表）+ 全局拖动

完整移植自 QFSpeed 2.1.6 源码：浮窗**常驻显示**（切 App / 回桌面 / 锁屏都在）、**全局拖动**，
并显示实时**网速采样、CPU 监控、内存、电池**，带**设置面板**与**图表绘制**（PiP 浮条）。
全部功能保留，不再做解耦裁剪。

> 本仓库是「可直接在 GitHub Actions 上编译出 .tipa」的完整工程。
> 浮窗核心在 `QFSpeedApp/` 下，构建由 `QFSpeedApp/build-tipa.sh` 完成。

## 目录
- `QFShared.h` —— App 与浮窗进程共用的约定（共享偏好 / 心跳 / 权限自检 / 日志）
- `QFSpeedApp/main.m` —— 入口：`无参数` 跑主 App（设置 + 开关），`-hud` 跑插件进程
- `QFSpeedApp/QFHudPlugin.m` —— 常驻窗口托管 + 全局拖动 + 轮询主循环（核心，2004 行）
- `QFSpeedApp/QFMetrics.m` —— 性能采样（网速 / CPU / 内存 / 电池）
- `QFSpeedApp/QFPiPBar.m` —— PiP 浮条 + 图表绘制
- `QFSpeedApp/QFSettingsPanel.m` —— 设置面板
- `QFSpeedApp/QFFloatingBar.m` / `QFHostController.m` —— 浮条与宿主控制
- `QFSpeedApp/build-tipa.sh` —— clang arm64 + ldid 构建脚本（校验 entitlements）
- `QFSpeedApp/entitlements.plist` —— 常驻窗口 + 拖动 + 监听所需的完整权限
- `.github/workflows/build.yml` —— macOS runner 自动构建并上传 .tipa

## 浮窗交互（内置）
- 拖动 → 移动浮条位置（松手按归一化坐标记忆，旋转不丢）
- 轻点 → 切换紧凑 / 完整样式
- 长按 → 锁定位置

## 构建（GitHub Actions 自动完成）
推到 `main`（或到仓库 **Actions → Run workflow** 手动触发）后，macOS runner 会：
1. `brew install ldid`，`pip install Pillow`（图标生成）
2. `cd QFSpeedApp && bash build-tipa.sh` —— arm64 单架构编译 + ldid 签名 + 校验关键 entitlements + 打包 `QFSpeed-2.1.6.tipa`
3. 上传 Artifacts

> **关键约束**：只编 `arm64` 单架构。fat（arm64+arm64e）会让 entitlements blob 损坏，
> 后果是「日志全正常、屏幕什么都没有」。A12+ 设备跑 arm64 用户态二进制没问题。

## 本地推到 GitHub（用你给的 PAT）
```bash
cd QFOverlay-Build
git remote add origin https://<你的PAT>@github.com/1992-02-08/QFOverlay.git
git branch -M main
git push -u origin main
```
（`<你的PAT>` 换成你的 `ghp_...` token；仓库名 `QFOverlay` 可改。）

## 验证
TrollStore 安装 `.tipa` → 打开 QFSpeed → 启动浮窗 → 应看到浮条常驻且显示实时网速/CPU；
切到别的 App / 锁屏再回来浮条还在；可拖动、轻点切换、长按锁定。
浮条不出现先翻设备日志 `/var/mobile/Library/Logs/QFOverlay.log`，启动会打一份 `[权限自检]`
（platform / sandbox / winHosting / backboard / hid / 系统目录写入），一眼看出是权限缺还是窗口注册失败。

## 已知边界
- 参考的 v1.0 `QFSpeed.ipa` 二进制里**本来就没有浮窗代码**，所以这是「移植 2.1.6 完整源码」而非「在原包上修」；
  2.1.6 本身就是带全部功能的成熟版本，常驻 + 拖动机制即从此版本抽取。
- 真机编译需要 macOS + Xcode SDK + ldid，本仓库的 Actions 已配好；本地沙箱无法编译 iOS。
- 当前 App 身份为参考源码的 `com.wacljcr.qfspeed.host`（显示名 QFSpeed）。若要并入你自己工程，
  把 `QFSpeedApp/` 里的 `QFHudPlugin` / `QFMetrics` / `QFPiPBar` / `QFSettingsPanel` / `QFShared.h`
  作为源文件加入主二进制，并 `main.m` 保留 `-hud` 分流即可。
