/// 应用内更新：流式下载（进度回调）与按平台触发安装。
/// iOS 系统限制不支持应用内自更新，调用方以「打开下载页」兜底。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as h;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logic.dart';

typedef ProgressFn = void Function(int received, int? total);

/// 下载端口；测试注入假实现，生产用 [downloadUpdatePackage]。
typedef DownloadPackageFn = Future<File> Function(
  String url,
  String fileName, {
  ProgressFn? onProgress,
  h.Client? client,
  Directory? saveDir,
});

/// 安装端口；测试注入假实现记录路径，生产用 [installUpdatePackage]。
typedef InstallPackageFn = Future<void> Function(String path);

/// 下载安装包（[url] 直链）到本地并返回文件。
/// [saveDir] 测试注入；默认按平台策略——macOS/安卓落应用临时目录（装完即删），
/// 其余平台落用户「下载」文件夹（用户可见、卸载不丢）。
Future<File> downloadUpdatePackage(
  String url,
  String fileName, {
  ProgressFn? onProgress,
  h.Client? client,
  Directory? saveDir,
  TargetPlatform? platform,
}) async {
  final dir = saveDir ?? await defaultSaveDir(platform);
  await dir.create(recursive: true);
  final file = File('${dir.path}/$fileName');
  final sink = file.openWrite();
  var received = 0;
  try {
    final res = await (client ?? h.Client()).send(h.Request('GET', Uri.parse(url)));
    if (res.statusCode != 200) {
      throw StateError('下载失败：HTTP ${res.statusCode}');
    }
    final total = res.contentLength;
    await for (final chunk in res.stream) {
      received += chunk.length;
      sink.add(chunk);
      onProgress?.call(received, total);
    }
  } catch (_) {
    await sink.flush();
    await sink.close();
    if (await file.exists()) await file.delete(); // 不留半截安装包
    rethrow;
  }
  await sink.flush();
  await sink.close();
  return file;
}

/// 下载保存目录（默认按平台策略：见 [defaultSaveDir]）。
Future<Directory> defaultSaveDir([TargetPlatform? platform]) async {
  final p = platform ?? defaultTargetPlatform;
  return switch (updateDownloadDirFor(p)) {
    UpdateSaveDir.temp => getTemporaryDirectory(),
    UpdateSaveDir.downloads => Directory(_userDownloadsPath()),
  };
}

String _userDownloadsPath() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return '$home/Downloads';
}

/// 安装包保存位置。
enum UpdateSaveDir {
  /// 应用临时目录：装完即删，不在用户可见目录留垃圾。
  temp,

  /// 用户「下载」文件夹：用户可见、卸载不丢。
  downloads,
}

/// [platform] 上安装包该放哪。
///
/// macOS 走自替换（装完由 updater.sh 删掉安装包），所以落临时目录；
/// 安卓同理——系统安装器读完就没人再碰它了。
/// Windows 本版还退回到「打开安装包让用户自己点」，安装包得留在用户找得到的地方。
UpdateSaveDir updateDownloadDirFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.android => UpdateSaveDir.temp,
      _ => UpdateSaveDir.downloads,
    };

/// [platform] 是否支持应用内自动安装（下载 → 替换 → 重启，全自动）。
///
/// 目前只有 macOS：替换由 `macos/Runner/updater.sh` 完成（Dart 不直接动文件）。
/// 安卓不需要——系统安装器本来就接管；iOS 受系统限制；
/// Windows 的自替换涉及运行中 exe 被内核锁定，本版不做。
bool supportsInAppSelfUpdate([TargetPlatform? platform]) =>
    (platform ?? defaultTargetPlatform) == TargetPlatform.macOS;

/// 当前平台的自更新安装器。抛 [UnsupportedError] 表示该平台无此能力，
/// 调用方应退回「打开安装包 / 打开下载页」。
typedef SelfUpdateRunner = Future<void> Function(String zipPath);

/// 唤起 macOS 原生自更新：把安装包交给 updater.sh 替换本 app，随后本进程退出。
///
/// 走 MethodChannel 而非 Dart 直接替换：运行中的 Mach-O 被内核锁定，
/// 运行中的进程无法可靠地把自己换掉，必须由外部进程在 App 退出后动手。
///
/// 调起后**不返回**——原生侧会 `exit(0)`；这里只在出错时抛出。
const _selfUpdateChannel = MethodChannel('astock/self_update');

Future<void> runMacSelfUpdate(String zipPath) async {
  if (!supportsInAppSelfUpdate()) {
    throw UnsupportedError('当前平台不支持应用内自动安装');
  }
  await _selfUpdateChannel.invokeMethod<void>('install', {'zip': zipPath});
}

/// 当前平台的自更新安装器；null = 该平台无此能力。
SelfUpdateRunner? selfUpdateRunnerFor([TargetPlatform? platform]) {
  if (!supportsInAppSelfUpdate(platform)) return null;
  return runMacSelfUpdate;
}

/// 当前平台的安装包直链；null = 无应用内自更新条件（iOS / Linux / 未产出安装包的平台），
/// 走下载页兜底。用 defaultTargetPlatform 而非 dart:io Platform：
/// 测试可用 debugDefaultTargetPlatformOverride 与宿主机解耦。
///
/// macOS 取 **zip**（`assets.macos`）而不是 dmg——dmg 挂载后要用户手动拖拽，
/// zip 才能被 updater.sh 直接解压替换。
String? assetUrlFor(UpdateInfo info) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return info.assets['android'];
    case TargetPlatform.macOS:
      return info.assets['macos'];
    case TargetPlatform.windows:
      return info.assets['windows'];
    case TargetPlatform.iOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return null;
  }
}

/// 下载完成后的安装触发：安卓拉起系统安装器（确认环节由系统提供），
/// 桌面交给系统打开安装包（macOS 挂载 dmg、Windows 走默认处理）。
/// 失败抛 StateError（open_filex 返回非 done）。
Future<void> installUpdatePackage(String path) async {
  final res = await OpenFilex.open(path);
  if (res.type != ResultType.done) {
    throw StateError(res.message);
  }
}
