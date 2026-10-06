/// updater.sh 的行为契约（真跑 shell，不 mock）。
///
/// 为什么用 shell 测试而不是 Dart 单测：替换逻辑的正确性取决于 `ditto`
/// 的签名保真、rename 的原子性、重启时序——这些只有真文件系统能验证。
/// 之前实测发现 `cp -R` 会破坏 app 签名（`code object is not signed at all`），
/// 而这类 bug 在 Dart 层测试里完全看不出来：下载和"安装"都成功了，
/// 只有用户重启后才发现 app 坏了。所以这里跑真实进程。
///
/// 全部在临时目录里操作，不碰 /Applications 与真实安装。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 项目根目录（从 test/ 往上两级）。
Directory get _root {
  final p = Directory.current.path;
  final d = p.endsWith('/test')
      ? Directory(p.substring(0, p.length - 5))
      : Directory(p);
  return Directory('${d.path}/macos/Runner');
}

String get _scriptPath => '${_root.path}/updater.sh';

/// 临时工作区；由 setUp 建、tearDown 删（不用 systemTemp 的自动清理）。
late Directory tmp;

/// macOS 临时目录是 `/var` → `/private/var` 符号链接，而 `ditto` 打包/解压
/// 要求真实路径（否则报 "Cannot get the real path for source"）。
String realPath(String p) => p.replaceFirst(RegExp(r'^/var/'), '/private/var/');

/// 造一个最小的「已签名 app」：Mach-O 可执行文件 + Info.plist。
///
/// 用真实 Mach-O（copy /usr/bin/true）而不是 shell 脚本：codesign 只认真
/// Mach-O，脚本会被判为「not signed at all」，测不到签名保真这条关键性质。
Directory makeApp(String parent, String name, {required String version}) {
  final app = Directory('$parent/$name.app');
  final macos = Directory('${app.path}/Contents/MacOS');
  macos.createSync(recursive: true);
  Directory('${app.path}/Contents/Resources').createSync(recursive: true);
  File('${macos.path}/$name').writeAsBytesSync(
      File('/usr/bin/true').readAsBytesSync()); // Mach-O
  File('${app.path}/Contents/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key><string>$name</string>
\t<key>CFBundleIdentifier</key><string>com.chenliang.stock</string>
\t<key>CFBundleShortVersionString</key><string>$version</string>
</dict>
</plist>
''');
  final r = Process.runSync('codesign',
      ['--force', '--deep', '--sign', '-', realPath(app.path)]);
  expect(r.exitCode, 0, reason: 'codesign 失败: ${r.stderr}');
  return app;
}

void main() {
  // updater.sh 依赖 macOS 专有命令（codesign/ditto/PlistBuddy），CI 跑在
  // ubuntu-latest 上：非 macOS 直接整体跳过，别把「平台不适用」报成失败。
  if (!Platform.isMacOS) {
    test('updater.sh 集成测试', () {}, skip: '仅 macOS 可跑（依赖 ditto/codesign）');
    return;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('updater_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('脚本存在且可执行', () {
    expect(File(_scriptPath).existsSync(), isTrue, reason: '缺少 macos/Runner/updater.sh');
  });

  group('dry-run：只做校验与演练，不动真实安装', () {
    test('zip 与已安装 app 都存在时 dry-run 通过', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');
      final zip = _makeZip(tmp, 'ASTock', '2.0.0');

      final r = _run(zip: zip, target: '${instDir.path}/ASTock.app', dryRun: true);
      expect(r.exitCode, 0, reason: 'dry-run 应成功: ${r.stdout}${r.stderr}');
      // 关键：dry-run 不得改动任何东西
      expect(_version(instDir.path), '1.0.0', reason: 'dry-run 不得替换已安装版本');
    });

    test('zip 里没有 app 时 dry-run 失败（不静默通过）', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');
      final zip = _makeEmptyZip(tmp);

      final r = _run(zip: zip, target: '${instDir.path}/ASTock.app', dryRun: true);
      expect(r.exitCode, isNot(0), reason: 'zip 无 app 必须报错，不能装出个空壳');
    });

    test('zip 文件不存在时失败且不触碰已安装版本', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');

      final r = _run(
          zip: '${tmp.path}/nope.zip',
          target: '${instDir.path}/ASTock.app',
          dryRun: true);
      expect(r.exitCode, isNot(0));
      expect(_version(instDir.path), '1.0.0');
    });
  });

  group('真实替换', () {
    test('替换后版本号更新，且签名仍然有效（ditto 保真）', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');
      final zip = _makeZip(tmp, 'ASTock', '2.0.0');

      final r = _run(zip: zip, target: '${instDir.path}/ASTock.app', noRelaunch: true);
      expect(r.exitCode, 0, reason: '替换应成功: ${r.stdout}${r.stderr}');
      expect(_version(instDir.path), '2.0.0');

      // 这条是整个方案的核心断言：cp -R 会破坏签名，ditto 不会
      final v = Process.runSync('codesign', ['-v', '${instDir.path}/ASTock.app']);
      expect(v.exitCode, 0, reason: '替换后签名必须仍然有效（必须用 ditto，不能 cp -R）');
    });

    test('替换后清理干净：不留 zip、不留备份、不留暂存目录', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');
      final zip = _makeZip(tmp, 'ASTock', '2.0.0');

      final r = _run(zip: zip, target: '${instDir.path}/ASTock.app', noRelaunch: true);
      expect(r.exitCode, 0);

      expect(File(zip).existsSync(), isFalse, reason: '下载的 zip 必须被清理');
      // 安装目录里除 app 本身外不得有任何残留
      final leftovers = instDir
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n != 'ASTock.app')
          .toList();
      expect(leftovers, isEmpty, reason: '不得残留备份/暂存：$leftovers');
      final workDirs = Directory('${tmp.path}/.updater_work').existsSync();
      expect(workDirs, isFalse, reason: '不得残留工作目录');
    });

    test('损坏的 zip 不会破坏已安装版本（旧版仍可运行）', () {
      final instDir = Directory('${tmp.path}/Applications')..createSync();
      makeApp(instDir.path, 'ASTock', version: '1.0.0');
      // 一个内容不是 zip 的文件
      final bad = File('${tmp.path}/bad.zip')..writeAsStringSync('this is not a zip');

      final r = _run(zip: bad.path, target: '${instDir.path}/ASTock.app', noRelaunch: true);
      expect(r.exitCode, isNot(0), reason: '损坏 zip 必须失败');
      expect(_version(instDir.path), '1.0.0', reason: '失败时旧版本必须完好无损');
      final v = Process.runSync('codesign', ['-v', '${instDir.path}/ASTock.app']);
      expect(v.exitCode, 0, reason: '失败时旧版本签名仍须有效');
    });
  });

  group('参数校验', () {
    test('缺 zip 或缺 target 时拒绝执行', () {
      final r = _runRaw([]);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('用法'));
    });
  });
}

/// 跑 updater.sh。默认传 `--no-relaunch`（测试里不能真启动 app）。
ProcessResult _run({
  required String zip,
  required String target,
  bool dryRun = false,
  bool noRelaunch = true,
}) =>
    _runRaw([
      if (dryRun) '--dry-run',
      '--zip', zip,
      '--target', target,
      if (noRelaunch) '--no-relaunch',
    ]);

ProcessResult _runRaw(List<String> args) {
  // 测试固定用 /bin/bash，不依赖执行权限位与 shebang。
  // stdoutEncoding/stderrEncoding 显式给 utf8：脚本输出中文，runSync 默认按
  // 系统编码解码会抛 FormatException（"Missing extension byte"）。
  return Process.runSync('/bin/bash', [_scriptPath, ...args],
      workingDirectory: tmp.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8);
}

/// 读已安装 app 的版本号。
String? _version(String appsDir) {
  final f = File('$appsDir/ASTock.app/Contents/Info.plist');
  if (!f.existsSync()) return null;
  final m = RegExp(r'<key>CFBundleShortVersionString</key><string>([^<]+)</string>')
      .firstMatch(f.readAsStringSync());
  return m?.group(1);
}

/// 造一个含 `name.app` 的 zip，返回 zip 路径。
///
/// 用系统 `zip -y`（保留符号链接）而非 `ditto -c -k`：实测 ditto 打包在
/// macOS 临时目录（/var → /private/var 符号链接）下会报 "Cannot get the real path"。
/// 解压侧仍用 ditto —— 它保留扩展属性，签名保真靠它。
String _makeZip(Directory tmp, String name, String version) {
  final stage = Directory('${tmp.path}/stage')..createSync();
  makeApp(stage.path, name, version: version);
  final zip = '${tmp.path}/$name-$version.zip';
  final r = Process.runSync('zip', ['-qry', '-y', realPath(zip), '$name.app'],
      workingDirectory: realPath(stage.path));
  expect(r.exitCode, 0, reason: '打包失败: ${r.stderr}');
  return zip;
}

/// 造一个合法但不含 app 的 zip。
String _makeEmptyZip(Directory tmp) {
  final d = Directory('${tmp.path}/empty')..createSync();
  File('${d.path}/readme.txt').writeAsStringSync('nothing here');
  final zip = '${tmp.path}/empty.zip';
  Process.runSync('zip', ['-qry', realPath(zip), 'readme.txt'],
      workingDirectory: realPath(d.path));
  return zip;
}
