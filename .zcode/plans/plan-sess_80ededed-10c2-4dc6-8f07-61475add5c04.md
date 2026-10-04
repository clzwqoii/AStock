# A股规则选股软件 · 编程语言选型方案

> 假设说明：你未确认平台与背景，以下按「四个端都要（Windows/macOS 桌面 + 安卓/iOS）、「编程背景未知」给出；核心是一张按背景选型的决策表。

## 结论

推荐 **Flutter（Dart）**：一套代码覆盖四端，在「移动 + 桌面都生产级可用」的单代码库方案里生态和中文资料最全（2026 年官方仍积极投入，见 [Flutter & Dart 2026 roadmap](https://flutter.dev/blog/flutter-darts-2026-roadmap)）。国内大厂（闲鱼等）大量使用。

关键架构判断：A股日线选股的计算量（约 5400 只股票 × 技术指标）**手机本地就能跑完**，不需要自建服务端，架构可以很简单——这消除了大多数跨端方案的复杂性顾虑。

## 为什么不是其他方案

- **四端各写原生**（Swift + Kotlin + WPF + …）：工作量 ×4，个人/小团队不现实
- **React Native**：移动端成熟，但桌面端（react-native-windows/macos）生态弱一档，资料少
- **Kotlin Compose Multiplatform**：iOS 已 stable（2025-05 起），完全可行；但桌面走 JVM 打包体积大、中文资料比 Flutter 少。**如果你主用 Kotlin，直接选它**
- **.NET MAUI**：Windows/安卓尚可，macOS 支持一直是短板
- **Electron/Tauri + 手机端**：需要维护两套 UI（桌面 web + 移动），Tauri 移动端偏新

## 按你的编程背景选（选型的最大决定因素）

| 你的背景 | 推荐方案 |
|---|---|
| 新手 / 都不熟 | **Flutter**（单语言、学习资源最多） |
| Python 为主 | **Python 做数据+规则引擎**（直接用 akshare/tushare 生态）+ Flutter 只做四端 UI；或先做纯 Web 版验证选股规则，再套壳 |
| JS/TS 为主 | **Expo (React Native) 移动端 + Tauri 桌面端**，TS 共享核心逻辑；K线图用 echarts 现成 |
| Kotlin/Java 为主 | **Kotlin Compose Multiplatform** 四端 |

## 推荐架构（Flutter 路线）

1. **数据源**：tushare pro HTTP API（注册领 token，日线免费档够用）；备选东方财富公开接口。akshare 是爬虫实现、仅 Python 且易失效，不作主源
2. **本地存储**：SQLite（Dart 用 drift 库）。全市场日线约每年 130 万行，单机无压力
3. **规则引擎**：独立纯 Dart 模块（不依赖 UI），输入行情、输出信号；按 TDD 开发（MA/MACD/量比等指标先写测试再实现）
4. **UI**：筛选条件构建器 + 结果列表 + 个股 K 线（fl_chart 或 CustomPainter 自绘）
5. 桌面端先行（开发调试方便），手机端复用同一核心、只调布局

## 实施步骤（v1 全职约 2–3 周；业余时间 ×2–3）

1. 脚手架：初始化 Flutter 项目，四端跑通 hello world —— 半天
2. 数据层：拉全市场日线 → SQLite，支持增量更新 —— 1–2 天
3. 规则引擎（TDD）：3–5 个常用指标 + 规则组合筛选 —— 2–3 天
4. UI v1：条件配置 + 选股结果页 + K 线查看 —— 3–5 天
5. 打包：Windows 安装包 / macOS dmg / 安卓 apk / iOS TestFlight —— 1–2 天

## 风险与合规

- **商业化前注意**：对外提供荐股/投资建议服务在国内需证券投资咨询业务资格；自用、纯个人分析工具不涉及。iOS 上架金融类 app 审核更严
- 分发成本：Apple Developer $99/年（iOS/macOS 签名必需）；安卓国内应用市场上架需软件著作权
- 未来若要做全市场回测或分钟级数据，再引入 Python 服务端做重计算，客户端不变

## 下一步

批准后执行第 1 步：在 `/Users/chenliang/Sites/stock` 初始化 Flutter 项目并四端跑通（若本机未装 Flutter SDK，我会先用 brew 安装，约 10 分钟）。