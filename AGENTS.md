# stock — A股规则选股软件（Flutter 四端）

按规则筛选 A 股：tushare pro 日线 → 本地 SQLite → 纯 Dart 规则引擎 →（开发中）Flutter UI（Windows/macOS/安卓/iOS 四端单代码库）。

## 常用命令（终端，项目根目录执行）

- 测试（交付前必须全绿）：`flutter test`
- 静态检查（必须 0 issue）：`flutter analyze`
- 同步数据（每日收盘后增量）：`dart run bin/sync.dart 120`
- 命令行选股（多规则 = AND 组合）：`dart run bin/screen.dart <规则id...>`；不带参数列出全部规则 id
- 运行 macOS demo：`flutter run -d macos`
- 正式构建：`flutter build apk --release`（签名读 android/key.properties，已 gitignore；口令勿写进任何文档）
- 正式构建：`flutter build macos --release`；dmg：`hdiutil create -volname A股选股台 -srcfolder build/dmg -format UDZO build/A股选股台.dmg`

## 中国网络环境必配

终端不走系统代理。pub/flutter 相关命令必须带国内镜像，否则卡死：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 配置

- 配置文件：项目根目录 `.env`（KEY=VALUE），已被 .gitignore 排除；模板见 `.env.example`
- 键：`TUSHARE_TOKEN`（必填，tushare.pro 注册）、`STOCK_DB_PATH`（可选，默认 `~/.stock/stock.db`）
- 读取逻辑在 `lib/config.dart`；进程环境变量优先于 .env 文件
- **token 只允许出现在 .env / 环境变量，任何代码和文档不得硬编码**
- **路径分工**：桌面（macOS/Windows）数据与配置固定在 `~/.stock/`（与 CLI 共享）；移动端沙盒强制隔离，由 `lib/app_paths.dart` + path_provider 解析到应用支持目录。新增读写路径的代码必须走 AppConfig/paths，不得再直接拼 `~` 路径
- **签名密钥**：android/app/*.jks 与 android/key.properties 严禁提交（已在 .gitignore）；release 与 debug 同 bundle id，同时运行会互相抢前台

## 架构分层（依赖方向：bin → data/core → core）

- `lib/core/` 规则引擎：纯 Dart、零 IO/UI 依赖。`models`（Bar/StockData）→ `indicators`（指标纯函数）→ `rules`（IndicatorSnapshot + builtInRules）→ `screener`（screen 顶层函数，单规则=列表传一条，组合=多条 AND）
- `lib/data/` 数据层：`tushare_client`（HTTP 协议/翻页/错误码）、`bar_repository`（SQLite，sqlite3 包非 drift）、`sync_service`（增量同步编排）
- `lib/app_logic.dart`：App/CLI 共用重活（runScreening 后台 isolate、runSync）；`lib/ui/` Flutter 界面（选股页/设置页）
- `bin/` 命令行胶水层，无业务逻辑；`test/` 测试；`docs/` 项目文档

## 开发规则

1. **TDD 强制**：core/data 层任何新逻辑先写失败测试再实现；指标期望值必须来自独立 oracle（`test/fixtures.dart` 顶部注释记录了 python 基准值），不允许用实现自身算期望值
2. **Widget 测试注意**：flutter_test 的 testWidgets 主体在 FakeAsync 区，真实 IO 与 Isolate.run 的完成事件永远等不到——临时目录一律在 setUp 建；页面把引擎调用/文件写入/同步都做成可注入参数（screenFn/writeConfig/runSyncFn），测试注入假实现；TextField 光标闪烁会让 pumpAndSettle 永不收敛，改用固定步进 pump
3. 新增指标/规则时：实现 + 测试 + 同步登记到 `builtInRules` + 更新 `docs/project-structure.md`
4. UI 字符串用简体中文；代码注释只写代码本身看不出的约束
5. tushare 低积分限频很紧（实测：daily 50次/分、stock_basic 1次/分、trade_cal 1次/时）：保持 40203 重试（65 秒/次）与「日历降级为工作日候选 + 节假日空结果自愈」机制，不要直接删掉重试/降级逻辑
6. 本机环境：Java 用 sdkman 的 17（`flutter config --jdk-dir` 已指向，当前 sdkman 默认是 11，不要改回）；Android cmdline-tools 在 `~/Library/Android/sdk/cmdline-tools/latest`（brew cask 的符号链接）；Windows 包只能在 Windows 机器上构建
7. 数据库文件（默认 `~/.stock/stock.db`）是用户数据，测试一律用 `Directory.systemTemp` 临时库，不得读写真实库
