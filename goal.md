# SimLab 演进目标（goal.md）

本文档定义 `SimLab` 的下一阶段演进方案，聚焦于**依赖与三台模拟器的极限剪枝优化**以及**开箱即用的引导与 Web MultiSim 启动流程**。

---

## 一、优化：依赖包与三台模拟器剪枝至最小可启动可用状态

### 1. 宿主依赖包剪枝（Minimal Host Dependencies）
将运行 `MultiSim`（Android + iPhone 16 Pro + iPhone Duo）所需的外部与内置依赖收敛为最小集合，剔除冗余工具链：
- **Android 最小工具链**：
  - 仅保留 `platform-tools`（仅需 `adb`）、`emulator`（剔除未使用的 x86_64/测试二进制与多余皮肤资源）、`cmdline-tools`（精简或由内置 AVD 模板生成逻辑替代 `avdmanager` + Java 依赖，直接生成 `.ini` 与 `config.ini` 以彻底移除对本地 `JDK / JAVA_HOME` 的强依赖）。
  - 系统镜像固定为单一 `arm64-v8a` 镜像（`google_apis` 替代庞大且含大量后台套件的 `google_apis_playstore`，或对镜像执行预瘦身快照）。
- **iOS 最小工具链与内置资源**：
  - 复用宿主 Xcode 的 `CoreSimulator.framework`、`SimulatorKit.framework` 与单一目标 iOS Runtime。
  - 将 `V68.usdz`（或预转换的 `V68.glb`）与 2D 机壳（`phone12/14/15`）提取为内置轻量资源包，预编译内置 `hinge_helper` 二进制（免去首次启动调用 `clang` 编译）。
  - Swift Package 依赖剪枝：仅保留 `swift-nio` 核心模块（HTTP1 + WebSocket）用于 gRPC 与 Web 服务，移除未使用的测试与扩展 target。

### 2. 三台模拟器运行时剪枝（Minimal Bootable & Usable Simulators）
在现有 `Balanced` 模式基础上，默认以**最小可用配置 + 预热快照（QuickBoot Snapshot）**启动三台模拟器：
- **Android 模拟器（Primary Android）**：
  - **硬件收敛**：RAM 限制为 `2048~3072 MB`、CPU `4 核`、禁用音频后端（`-no-audio`）、禁用引导动画（`-no-boot-anim`）、无窗口头模式（`-qt-hide-window` / `-no-window`）。
  - **系统包深度剪枝（`AndroidSlimClient`）**：在首次冷启动构建快照前，禁用 Wellbeing、Assistant、Wallpaper、YouTube Music、PrintService、Dreams、Backup/Restore、Settings Intelligence 等非核心系统包，随后保存为只读 `default_boot` 快照，后续秒级恢复。
- **iPhone 16 Pro & iPhone Duo（CoreSimulator）**：
  - **默认激活 `SimSlim` 强化配置**：在 `boot` 前直接写入 `launchd` override（`SimLabBalanced.json` + 进阶剪枝），默认禁用 Spotlight 索引（`searchd`/`mds`）、Siri（`assistantd`）、照片分析（`photoanalysisd`）、健康/健身守护进程、iCloud 后台同步（`bird`/`cloudd` 非必需项）、诊断日志收集（`diagnosticd`/`logd` 降级）。
  - **保留核心能力**：保留 SpringBoard、BackBoard（HID 触控 / `CMAngleManager` 铰链传感器）、网络栈、WebKit、Keychain 与 App 调试所需服务，单台 iOS 模拟器常驻内存控制在 `~1.2 GB` 以内。

---

## 二、流程：零配置依赖引导、默认 MultiSim 与 Web 服务一键启动

### 1. 启动时依赖检测与一键下载流程（Dependency Check & Onboarding）
新电脑首次打开 `SimLab.app` 时，自动执行环境扫描并汇总缺失项：
1. **自动检测清单**：
   - Xcode Command Line Tools / CoreSimulator Runtime（是否包含支持 iPhone 16 Pro 与 iPhone Duo 的 iOS Runtime）
   - Android `platform-tools`（`adb`）
   - Android `emulator`
   - Android 目标 `system-image`（`arm64-v8a`）与预置精简 AVD 快照包
   - 内置辅助组件（`SimSlim`、`hinge_helper`、3D 模型与机壳资源）
2. **弹窗确认与下载进度条**：
   - 检测完成后，若存在缺失项，展示汇总卡片：**“检测到缺少 X 个依赖项，是否立即下载并配置？”**（列出缺失项名称与预计体积）。
   - 用户点击**“确定”**后，显示总体进度条（百分比 + 已下载/总大小 + 当前子项进度），支持并发分块下载与校验解压。
   - 全部依赖就绪后自动切入主工作区。

### 2. 默认创建三合一 MultiSim 工作区（Default MultiSim Workspace）
依赖检查/下载完成后进入主界面时：
- 若本地尚无工作区，自动创建并选中默认 `MultiSim` 工作区，默认包含三台标准设备并按序排列：
  1. **Android**（默认精简 AVD）
  2. **iPhone 16 Pro**
  3. **iPhone Duo**（支持 `0°~180°` 3D 铰链折叠与双屏切换）
- 三台设备创建时自动套用第一部分的最小化剪枝策略。

### 3. Header 右上角“启动本地 Web MultiSim 服务”按钮与实时状态栏
将 App 顶部 Header 右上方的操作区替换为 **Web MultiSim 本地服务启动控件**：
- **交互形态**：
  - **未启动态**：显示 `Start Web Service`（或“启动本地服务”）按钮。
  - **启动中态**：点击按钮后，依次拉起三台模拟器与内置 NIO Web/WebSocket 推流服务；按钮区域左侧展示**圆形进度条（Circular Progress，0%~100%）**，右侧紧跟**单行实时日志（Single-line Live Log）**，滚动刷新当前最新阶段（例如：`[1/4] 正在应用 SimSlim 剪枝配置…` → `[2/4] 正在启动 iPhone Duo (85%)…` → `[3/4] 正在建立 IOSurface 视频流通道…` → `[4/4] Web 服务已就绪 http://127.0.0.1:8080`）。
  - **运行中态**：圆形进度条变为绿色运行指示点 + 一键打开/复制本地 Web 地址按钮 + `Stop` 按钮，右侧单行日志继续显示最新运行状态或端口信息。
