/// 「更新已完成」提示的状态机：靠 build 号变化判定，纯 Dart 无原生依赖。
///
/// ## 为什么不用安装广播
///
/// Android 11（API 30）起，`REPLACE_EXISTING_PACKAGES` 让系统在替换安装时
/// **直接结束旧进程**。于是两种常见做法都收不到事件：
/// - `PackageInstaller` 的会话回调（需要进程活着）；
/// - `ACTION_MY_PACKAGE_REPLACED` 广播（进程已被杀，收不到）。
///
/// 唯一可靠的观察点是**下一次冷启动**：上次启动记住 build 号，本次发现变了
/// 就说明中间装过更新，提示一次并立刻写回新号（保证同一次更新只提示一次）。
///
/// 这也解释了 macOS 为什么不用这套：那边是脚本替换 + `open` 重启，
/// 进程由我们自己控制，能在替换后主动做点什么。
library;

import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'config.dart';

/// [lastSeen]（上次启动记下的 build 号）与 [current]（本次的）不同则需要提示。
///
/// - [lastSeen] 为 null/空 = 首次启动，不提示（没什么可说的）；
/// - build 号变小 = 降级安装，同样提示——用户确实换了版本。
bool shouldShowUpdateNotice({required String? lastSeen, required String current}) {
  if (lastSeen == null || lastSeen.isEmpty) return false;
  if (current.isEmpty) return false;
  return lastSeen != current;
}

/// 上次启动时记录的 build 号。
abstract class LastSeenStore {
  String? get value;
  void write(String v);
}

/// 消费式判定：返回 true 表示「这次该提示」，并已把 [current] 写回。
///
/// 「消费式」是关键：提示过后立刻写回，否则同一次更新会在每次冷启动都弹。
class UpdateNoticeStore {
  UpdateNoticeStore(this._store);

  final LastSeenStore _store;

  bool consume({required String current}) {
    final show = shouldShowUpdateNotice(lastSeen: _store.value, current: current);
    // 无论提不提示都写回：首次启动要记下当前号，下次才有对比基准。
    _store.write(current);
    return show;
  }
}

/// 存放上次启动 build 号的 .env 键名。
const kLastSeenBuildKey = 'LAST_SEEN_BUILD';

/// 生产实现：读当前 build 号，与 .env 里上次记录的比对。
///
/// 返回 true = 该提示「已更新到新版本」。**消费式**——判定即写回，
/// 保证同一次更新只在下次冷启动提示一次。
///
/// 读不到 build 号（插件异常/未来平台不支持）时返回 false：提示是锦上添花，
/// 绝不能因为它挡住启动。
Future<bool> checkUpdateNotice({
  required String configPath,
  Future<String?> Function()? currentBuild,
}) async {
  final build = await (currentBuild ?? _platformBuild)();
  if (build == null || build.isEmpty) return false;
  try {
    return UpdateNoticeStore(DotEnvLastSeenStore(configPath, kLastSeenBuildKey))
        .consume(current: build);
  } catch (_) {
    return false; // 配置不可写（只读目录等）不该影响启动
  }
}

/// 当前安装包的 build 号（Android 的 versionCode / 桌面/iOS 的 build 号）。
/// 取不到返回 null——调用方按「不提示」处理。
Future<String?> _platformBuild() async {
  try {
    final info = await PackageInfo.fromPlatform();
    // Android 的 versionCode 才是「装了几次」；versionName 是用户看到的 semver。
    // 两者拼一起，semver 变了或 code 变了都能识别。
    return '${info.version}+${info.buildNumber}';
  } catch (_) {
    return null;
  }
}
/// 把 [LastSeenStore] 接到已有的 .env 配置文件上。
///
/// 复用配置文件的理由：它已经处理好「桌面 ~/.stock/.env、移动端沙盒内 .env」
/// 的路径差异（见 lib/app_paths.dart），更新安装不会清掉它——这正是我们要的：
/// 沙盒数据跨版本保留，才能在下次启动读到「上次」的 build 号。
class DotEnvLastSeenStore implements LastSeenStore {
  DotEnvLastSeenStore(this.path, this.key);

  /// 配置文件路径。
  final String path;

  /// 存放 build 号的键名。
  final String key;

  @override
  String? get value {
    if (!File(path).existsSync()) return null;
    final raw = AppConfig.parseDotEnv(File(path).readAsStringSync())[key];
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  @override
  void write(String v) {
    // 同步写入：启动早期调用，还没有可用的 async 上下文；
    // 写的是本地小文件（几十字节），代价可忽略。
    // 不复用 AppConfig.updateFile（它是 async 且要 await），这里只需要落一次。
    final file = File(path);
    final vars = file.existsSync()
        ? AppConfig.parseDotEnv(file.readAsStringSync())
        : <String, String>{};
    vars[key] = v;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
        '${[for (final e in vars.entries) '${e.key}=${e.value}'].join('\n')}\n');
  }
}
