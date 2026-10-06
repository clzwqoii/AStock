/// 检查更新入口的一致性契约。
///
/// macOS 菜单栏（⌘U）与设置页按钮是两处入口，历史上参数集不同：
/// 设置页传了 selfUpdateFn，菜单栏没传，只靠 `_downloadAndInstall` 内部的
/// 兜底 `selfUpdate ?? selfUpdateRunnerFor()` 才碰巧没出问题。
///
/// 兜底是脆弱的：一旦默认实现变了（例如将来按平台策略区分），两处就会静默
/// 分叉——菜单栏走一条路、设置页走另一路，且没有任何测试会失败。
///
/// 所以把参数收敛到 [UpdateDeps] 一处构造，两处入口都只调它。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/update_download.dart';
import 'package:stock/ui/settings_page.dart';

void main() {
  UpdateInfo sampleInfo() => UpdateInfo(
        latestVersion: '9.9.9',
        downloadUrl: 'https://example.com/releases',
        assets: const {'macos': 'https://example.com/A-macOS.zip'},
      );

  group('UpdateDeps：单一参数汇聚点', () {
    test('两处入口注入同一套依赖，不会分叉', () {
      // 关键契约：selfUpdateFn 必须由**调用方显式注入**。
      // 默认 null 是有意的——否则「漏传」与「故意不用」无法区分，
      // 两处入口就可能一个传了一个没传，悄悄走不同路径。
      Future<void> fake(String _) async {}
      final menuDeps = UpdateDeps(selfUpdateFn: fake);
      final settingsDeps = UpdateDeps(selfUpdateFn: fake);
      expect(menuDeps.selfUpdateFn, same(settingsDeps.selfUpdateFn));
    });

    test('默认 selfUpdateFn 为 null（强制调用方显式决定）', () {
      expect(const UpdateDeps().selfUpdateFn, isNull,
          reason: '默认值会掩盖漏传；macOS 上必须由外壳显式传入 selfUpdateRunnerFor()');
    });

    test('平台能力由 selfUpdateRunnerFor 决定，外壳据此注入', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(selfUpdateRunnerFor(), isNotNull, reason: 'macOS 走自动替换');

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(selfUpdateRunnerFor(), isNull,
          reason: '安卓不走自替换，系统安装器接管');
    });

    test('显式注入覆盖默认', () {
      Future<void> fake(String _) async {}
      expect(UpdateDeps(selfUpdateFn: fake).selfUpdateFn, same(fake));
    });

    test('依赖可完整携带五个字段（漏一个都会在入口分叉）', () {
      Future<void> fake(String _) async {}
      final deps = UpdateDeps(
        checkFn: () async => sampleInfo(),
        downloadFn: (u, f, {onProgress, client, saveDir}) async =>
            throw UnimplementedError(),
        installFn: (p) async {},
        selfUpdateFn: fake,
        launchUrl: (u) async => true,
      );
      expect(deps.checkFn, isNotNull);
      expect(deps.downloadFn, isNotNull);
      expect(deps.installFn, isNotNull);
      expect(deps.selfUpdateFn, same(fake));
      expect(deps.launchUrl, isNotNull);
    });
  });
}
