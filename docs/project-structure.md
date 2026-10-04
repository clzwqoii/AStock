# 项目结构说明

> 更新日期：2026-10-02。配合根目录 `AGENTS.md`（开发约定）阅读。

## 目录树

```
stock/
├── AGENTS.md                  # Agent/协作开发约定（命令、规则、环境坑）
├── pubspec.yaml               # 依赖清单：http（HTTP）、sqlite3（数据库）、sqlite3_flutter_libs（移动端内置 SQLite）
├── .env                       # 本地配置（含 token，已被 .gitignore 排除，不提交）
├── .env.example               # 配置模板（可提交）
├── lib/
│   ├── main.dart              # 入口：读配置 → 挂载 StockApp
│   ├── config.dart            # 配置加载：环境变量 → 配置文件 → 默认值；configPath 记录设置页写入位置
│   ├── app_paths.dart         # 启动配置：桌面沿用 ~/.stock（与 CLI 共享），移动端用 path_provider 应用支持目录
│   ├── app_logic.dart         # App/CLI 共用重活：runScreening（后台 isolate 选股）、runSync（增量同步，进度可回调）、checkForUpdate（版本比较）
│   ├── core/                  # ── 规则引擎（纯 Dart，零 IO/UI 依赖，可独立测试）──
│   │   ├── models.dart        #   Bar（一根日K：开高低收/量）与 StockData（一只股票的日线序列）
│   │   ├── indicators.dart    #   指标纯函数：sma/smaSeries/emaSeries/macd/rsi/volumeRatio/pctChange
│   │   ├── rules.dart         #   IndicatorSnapshot（末日指标快照）+ Rule + builtInRules（7 条内置规则）+ ruleById
│   │   └── screener.dart      #   screen(stocks, rules)：筛选入口；单规则=传一条，组合=多条 AND；历史不足 20 根自动跳过
│   └── data/                  # ── 数据层（网络与存储）──
│       ├── tushare_client.dart#   tushare pro HTTP 客户端：请求构造、offset 翻页、错误码翻译（TushareException）
│       ├── eastmoney_client.dart#  东方财富公开接口（免 token）：股票代码+名称名单，tushare stock_basic 限频时的自动降级源
│       ├── tencent_client.dart #  腾讯股票名称（fqkline 响应自带 qt 块；日K仅前复权，禁止进日线链路）
│       ├── sina_client.dart    #  新浪日K（免 token，scale=240，不复权，vol 股→手，不含北交所）
│       ├── bar_repository.dart#   SQLite 读写：stocks / daily_bars 表，upsert 幂等，loadAllStocks 供引擎消费
│       └── sync_service.dart  #   增量同步编排：交易日历（失败退化为工作日候选）→ 待拉日期 → 逐日入库；40203 限频自动重试
│   ├── ui/                    # ── Flutter 界面 ──
│       ├── candle_chart.dart  #   日K蜡烛图（CustomPainter 自绘：蜡烛+成交量+MA5/10/20）；十字光标（桌面悬停/移动拖动）与读数浮层
│       ├── candle_chart_math.dart # K线图纯计算：ChartGeometry（像素↔索引/价格双向换算）、priceRange、CandleReadout、formatVolume；不依赖绘制，可独立单测
│       ├── stock_detail_page.dart # 个股详情页（指标数值 + K线），桌面/移动共用
│       ├── onboarding.dart     #   首次启动引导（无 token 时弹三步：注册→填token→开始），url_launcher 跳转注册页
│       ├── colors.dart        #   AppColors 静态中性色 + AccentColor 枚举（红/深/蓝/绿）+ AccentScope 继承作用域
│       ├── stock_app.dart     #   应用外壳：启动自动增量同步（数据齐全=零请求）+ 主题色切换（持久化 THEME_ACCENT）+ 选股/设置页签
│       ├── mobile_home.dart   #   移动原生布局（窄屏<768 自动启用，docs/design/mobile-native.html）：渐变头部+统计卡
│       │                      #   +折叠规则面板+结果卡片+底部导航；统计卡下方展示同步状态/失败原因
│       ├── screening_page.dart#   选股页·方案C高密度工作台（docs/design/c-compact-workbench.html）：侧栏规则开关分组
│       │                      #     + 工具栏（组合条件/同步徽章/开始按钮）+ 密集表格（涨跌/涨跌幅/量比/成交额/MA20）
│       │                      #     + 底部状态栏；窄屏(<768)侧栏折叠为横向胶囊条；引擎调用可注入（screenFn）
│       └── settings_page.dart #   设置页：token 保存 + 主题色色板（4 色即点即换）+ 手动同步按钮；IO 可注入
├── bin/                       # ── 命令行工具（胶水层，无业务逻辑）──
│   ├── sync.dart              #   dart run bin/sync.dart [回填天数=120] [db路径]：拉数据入库
│   └── screen.dart            #   dart run bin/screen.dart <规则id...>：用本地库选股；不带参数列出规则
├── test/                      # 测试（flutter test 全绿为交付门槛）
│   ├── fixtures.dart          #   测试行情序列 + 独立 python oracle 基准值注释
│   ├── indicators_test.dart   #   指标函数（MACD/RSI 与 oracle 对齐到 1e-9）
│   ├── rules_test.dart        #   IndicatorSnapshot + 7 条内置规则（金叉只在交叉日为真等）
│   ├── screener_test.dart     #   组合 AND / 单规则 / 空规则报错 / 短历史跳过
│   ├── tushare_client_test.dart#  请求构造、翻页、错误码（MockClient 假 HTTP）
│   ├── bar_repository_test.dart#  upsert 幂等、maxTradeDate、分组加载（临时目录真 SQLite）
│   ├── sync_service_test.dart #   首次回填 / 增量 / 盘中不拉当日 / 限频重试 / 日历降级（有状态假 HTTP）
│   ├── app_logic_test.dart    #   runScreening 隔离区选股 / runSync 注入客户端同步 / 版本比较
│   ├── mobile_ui_test.dart    #   窄屏：底部导航、规则开关、结果卡片、详情页K线、主题色持久化
│   ├── ui_test.dart           #   组件测试：规则勾选传参、空库提示、保存 token、同步按钮（引擎/IO/同步均可注入）
│   ├── config_test.dart       #   .env 解析与多文件合并
│   └── widget_test.dart       #   应用启动 smoke
├── docs/
│   ├── project-structure.md   # 本文档
│   └── design/                # UI 与应用图标设计稿（HTML 源稿 + PNG，Chrome headless 渲染）
│       ├── 移动端-当前自适应.png / 移动端-原生升级提案.png  # 移动端两版样机（已选原生升级版）
│       └── 图标方案-h.png     # 已选定图标（白底立体蜡烛，第三轮方案 H）；其余 g/i 与三轮历史稿在同目录
├── build/…                    # 构建产物（gitignore）：flutter-apk/app-release.apk（56.5MB 签名包）
│                               #   macos/Build/Products/Release/ASTock.app（46.8MB）、A股选股台.dmg（21MB）
├── android/key.properties      # Android 正式签名配置（gitignore；口令勿外传）
└── android/  ios/  macos/  windows/   # Flutter 四端平台壳
    ├── macos/Runner/MainFlutterWindow.swift  # 原生菜单（Swift 构建 NSMenu）+ platform_menu MethodChannel
    ├── macos/Runner/Configs/AppInfo.xcconfig  # PRODUCT_NAME=ASTock（应用显示名 A股选股台 在 Info.plist）
    └── macos/Runner/*.entitlements    # 已移除 App Sandbox（桌面直发需访问 ~/.stock 共享数据；
                                       # 上架 Mac App Store 时恢复沙盒并用 path_provider 迁移数据进容器）
```

## 数据流

```
tushare pro HTTP ──> TushareClient（翻页/错误码）
                        │
                        ▼
                   SyncService（哪些日期要拉？增量 + 已收盘 + 限频重试 + 日历降级）
                        │
                        ▼
                   BarRepository ──> ~/.stock/stock.db（SQLite：daily_bars 表，主键 (ts_code, trade_date)）
                        │
                        ▼ loadAllStocks() → List<StockData>
                   Screener.screen(stocks, rules) ──> 入选股票列表
                        ▲
              builtInRules（UI/CLI 从这里枚举可选规则）
```

## 数据库表结构

- `stocks(ts_code PK, name)` —— 股票名单（低积分限频下可能为空，可选）
- `daily_bars(ts_code, trade_date, open, high, low, close, vol, amount; PK(ts_code, trade_date))` —— 日线；`trade_date` 为 `YYYYMMDD` 字符串，字典序即时间序；已同步进度 = `MAX(trade_date)`（无单独状态表）

## 指标与规则的关系（选股按规则，不直接按指标）

- **指标**（`indicators.dart`）是计算器：输入行情序列输出数值，不判断。当前 5 个：MA(5/10/20)、MACD(12,26,9)、RSI14(Wilder)、量比（当日量/前5日均量）、当日涨跌幅
- **规则**（`rules.dart`）是判断器：拿某只股票末日指标快照（`IndicatorSnapshot`，含前一日值用于金叉/上穿判断）做布尔运算
- 内置 7 条规则 ↔ 指标对应：

| 规则 id | 含义 | 依赖指标 |
|---|---|---|
| close_above_ma20 | 收盘价站上MA20 | MA20 |
| ma5_golden_ma10 | MA5上穿MA10 | MA5、MA10（含前一日） |
| macd_golden_cross | MACD金叉 | MACD（含前一日 DIF/DEA） |
| rsi_oversold | RSI14<30 | RSI14 |
| rsi_overbought | RSI14>70 | RSI14 |
| volume_surge | 量比>2 | 量比 |
| pct_change_up | 当日涨幅>3% | 涨跌幅 |

- 选股永远调用 `screen(stocks, 选中的规则列表)`：单规则选股传一条，组合选股传多条（全部满足才入选）。想按指标本身选（比如 MA20 数值区间），就是再加一条规则的事

## 当前状态与下一步

- ✅ 脚手架（四端）、规则引擎（TDD）、数据层（TDD）、CLI、.env 配置、UI v1（规则勾选选股 + 启动自动同步 + 设置页保存 token + 手动同步按钮）
- ✅ UI 重设计为方案 C 高密度工作台（2026-10-03，三方案设计稿在 docs/design/，用户选定 C）：ScreenRow 展示行（涨跌/涨跌幅/量比/成交额万/MA20）、Bar 增加 amount 字段、stockNames() 名称查询（缺失降级显示 —）
- ✅ 数据库已开 WAL 模式：自动同步（写）与选股（读）并发不互锁
- ✅ 真数据：120 交易日 / 62.4 万行已入库，端到端选股已验证（CLI 与引擎层）
- ⏳ UI 待做：K 线图查看个股、选股结果展示股票名称（依赖 stock_basic 恢复拉取）、真机/桌面端视觉验收
- ✅ HTTP 超时：tushare/腾讯/新浪/东财 全部 15 秒超时（可注入），超时抛 TushareException(408)「请求超时（15秒）：接口名」，避免界面长时间「同步中」
- ✅ Android 模拟器端到端验证（2026-10-04）：release APK 安装启动、debug 版沙盒路径注入 62 万行、自动同步（真实网络成功）、勾规则选股（5586→1800）、卡片进入 K 线详情（真实名称+均线+成交量）全通过；AVD 名 stock_test（无头启动 `-no-window -no-audio -no-snapshot -gpu swiftshader_indirect`）
- ✅ iOS 模拟器验证（2026-10-04）：移动布局/主题/沙盒路径/本地数据/同步状态展示均正常；**模拟器内网络受宿主机代理 fake-ip（198.18.x）影响不可用（非代码问题，真机正常）**
- ⏳ 数据源备份：✅ 日线双源 **tushare(按日全市场) → 新浪（逐股，与主源同口径：不复权/手）**；✅ 股票名单/名称三级链 **tushare stock_basic → 东财 clist → 腾讯/东财逐股名称回填**（东财 push2 域名在部分网络被拦时自动走逐股，一次性约 10 分钟，只补缺失名称）；交易日历 tushare → 工作日候选自愈
- ⏳ macOS/iOS 桌面构建需先完成 Xcode 许可初始化（三条 sudo 命令，须分行执行）
