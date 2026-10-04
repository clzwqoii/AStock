# A股选股台（Stock）

按规则筛选 A 股的跨平台应用（Flutter 单代码库：Windows · macOS · 安卓 · iOS）。

## 功能

- **7 条选股规则**：收盘价站上MA20、MA5上穿MA10、MACD金叉、RSI超买/超卖、量比>2、当日涨幅>3%
  - 单规则选股：勾选一条；组合选股：勾多条，全部满足才入选（AND）
- **自动增量同步**：打开 App 自动检查并补齐缺失交易日；数据齐全时零请求空跑
- **个股详情**：日K蜡烛图 + 成交量 + MA5/10/20 均线 + RSI/量比/MA20 数值
- **多数据源自动降级**：日线 tushare → 腾讯 → 新浪 → 网易；股票名单 tushare → 东方财富 → 逐股回填；交易日历 tushare → 工作日候选自愈
- **主题色**：红 / 深 / 蓝 / 绿，设置页即时切换并持久化
- **命令行工具**：`bin/sync.dart`（同步）、`bin/screen.dart`（选股），与 App 共用同一份本地库

## 数据与配置

| 端 | 数据库 | 配置文件 |
|---|---|---|
| 桌面（Windows/macOS） | `~/.stock/stock.db` | `~/.stock/.env` |
| 移动端（iOS/安卓） | 应用支持目录（沙盒内） | 同目录 `.env` |

`.env` 键：`TUSHARE_TOKEN`（tushare.pro 注册获取）、`STOCK_DB_PATH`（可选）、`THEME_ACCENT`（red/charcoal/blue/green）。App 设置页与命令行共用该文件；桌面版开发时也读项目根目录 `.env`。

## 开发

国内网络建议先设镜像（否则 pub/flutter 会卡住）：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

常用命令（项目根目录）：

```bash
flutter test                 # 全量测试（交付门槛：必须全绿）
flutter analyze              # 静态检查（必须 0 issue）
flutter run -d macos         # 桌面运行（菜单栏：关于 / 检查更新 ⌘U / 设置 ⌘, / 退出 ⌘Q）
dart run bin/sync.dart 120   # 命令行同步（首次/回填 120 个交易日）
dart run bin/screen.dart macd_golden_cross                # 单规则选股
dart run bin/screen.dart close_above_ma20 volume_surge     # 组合选股
```

## 构建发布

```bash
# Android（正式签名：读 android/key.properties，已 gitignore）
flutter build apk --release            # build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --split-per-abi   # 按 ABI 拆分，单包体积约 1/3

# macOS
flutter build macos --release          # build/macos/Build/Products/Release/ASTock.app
hdiutil create -volname A股选股台 -srcfolder build/dmg -format UDZO build/A股选股台.dmg
```

- 签名密钥：`android/app/*.jks` 与 `android/key.properties`，**禁止提交**；口令见 key.properties
- release 与 debug 同 bundle id，**一次只运行一个**；手机上从 debug 版切 release 需先卸载（签名不同）

### 一键发版（双平台发行版自动上传）

```bash
tool/release.sh 1.1.0 --dry-run   # 仅本地构建与版本号校验，不推送
tool/release.sh 1.1.0             # 全自动：构建 → 提交推送双平台 → GitHub + Gitee 双发行版
```

发版前需在三处同步版本号（脚本会校验，不一致直接报错）：`pubspec.yaml`、`lib/app_logic.dart` 的 `kAppVersion`、`update.json`。发行说明自动取 [RELEASE_NOTES.md](RELEASE_NOTES.md) 中对应版本段落。

**Gitee 发行版需要一个私人令牌**（https://gitee.com/profile/personal_access_tokens 新建，勾选 `projects` 权限），二选一配置：

```bash
security add-generic-password -s gitee-release -a clzwqoii -w <令牌>   # 存钥匙串（推荐）
GITEE_TOKEN=<令牌> tool/release.sh 1.1.0                          # 或临时环境变量
```

GitHub 发行版无需额外配置（`gh` 已认证）。

## 检查更新（多源自动分流）

菜单栏「检查更新…」会**并发请求所有候选源，第一个响应的胜出**（15 秒超时）：国内网络自动命中 Gitee，境外命中 GitHub，被墙的源直接被忽略、不拖慢检查。候选源在 `lib/app_logic.dart` 的 `kUpdateCheckUrls`（建仓库后替换为你的地址）：

```dart
const kUpdateCheckUrls = <String>[
  'https://gitee.com/clzwqoii/astock/raw/main/update.json',              // 国内优先
  'https://raw.githubusercontent.com/clzwqoii/AStock/main/update.json',
  'https://cdn.jsdelivr.net/gh/clzwqoii/AStock@main/update.json',        // GitHub CDN 镜像
];
```

> 说明：更新清单就放在**本仓库根目录**的 `update.json`（两个平台是同一份文件的镜像，无需另开仓库）；仓库需为**公开**（私有仓库的 raw 文件需鉴权）。若默认分支名不是 `main`，请同步修改上述地址。

发布新版本流程：

1. 更新本仓库根目录的 `update.json`（推到 Gitee 与 GitHub 两边）：

   ```json
   { "version": "1.1.0", "url": "https://…下载页…" }
   ```

   若希望境外用户更快，可把同一文件同步一份到 GitHub 公开仓库——App 自动择优。
2. `flutter build ... --build-name=1.1.0` 出包，并把 `pubspec.yaml` 与 `lib/app_logic.dart` 的 `kAppVersion` 同步为新版本
3. 在 [Releases](https://github.com/clzwqoii/AStock/releases) 新建版本标签（如 `v1.1.0`）并上传安装包（`A股选股台.dmg`、`app-release.apk`），发布说明复制 [RELEASE_NOTES.md](RELEASE_NOTES.md) 的对应段落

### 下载安装包

两个平台都挂了发行版（版本说明 + 安装包附件）：

- **Gitee**（`update.json` 的下载链接指向此处，国内优先）：https://gitee.com/clzwqoii/astock/releases
- **GitHub**（镜像，境外访问快）：https://github.com/clzwqoii/AStock/releases

附件命名统一为 `AStock-<版本>-macOS.dmg` / `AStock-<版本>-Android.apk`，由 `tool/release.sh` 自动上传两个平台。

## 开源协议

[MIT](LICENSE)——允许任何人使用、修改、分发（含闭源商用），只要求保留版权声明；个人项目最省心、对商业化最友好。若你希望「衍生作品必须开源」选 GPL-3.0（本项目不适用，会阻止别人闭源打包发布）。

## 技术栈与架构

Flutter + Dart。分层：`lib/core/`（规则引擎，纯 Dart 零 IO）、`lib/data/`（数据源与 SQLite）、`lib/ui/`（桌面工作台 + 移动原生两套布局，窄屏 <768 自动切换）、`lib/app_paths.dart`（端相关路径）。详见 [AGENTS.md](AGENTS.md)（开发约定）、[docs/project-structure.md](docs/project-structure.md)（结构说明）与 [docs/design/](docs/design/)（UI/图标设计稿）。

> 网络提示：若本机使用 Clash 类代理（fake-ip 198.18.x 段），**iOS 模拟器/部分模拟器内无法直连外网**（模拟器不走宿主 TUN 且 Dart HTTP 不读系统代理）；桌面端与真机不受影响，接口均已设 15 秒超时，失败会给出明确提示而非长时间等待。