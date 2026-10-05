/// 应用内更新：流式下载（进度回调）与按平台触发安装。
/// iOS 系统限制不支持应用内自更新，调用方以「打开下载页」兜底。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// [saveDir] 测试注入；默认安卓用应用缓存目录（安装器经 FileProvider 读取）、
/// 桌面用「下载」文件夹（用户可见，卸载不丢）。
Future<File> downloadUpdatePackage(
  String url,
  String fileName, {
  ProgressFn? onProgress,
  h.Client? client,
  Directory? saveDir,
}) async {
  final dir = saveDir ?? await defaultSaveDir();
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

/// 下载保存目录。
Future<Directory> defaultSaveDir() async {
  if (Platform.isAndroid) return getTemporaryDirectory();
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return Directory('$home/Downloads');
}

/// 当前平台的安装包直链；null = 无应用内自更新条件（iOS / Linux / 未产出安装包的平台），
/// 走下载页兜底。用 defaultTargetPlatform 而非 dart:io Platform：
/// 测试可用 debugDefaultTargetPlatformOverride 与宿主机解耦。
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
