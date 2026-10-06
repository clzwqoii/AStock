/// macOS 自更新的 Dart 侧契约：桌面端走「zip + 原生自替换」，
/// 安卓/iOS 等平台仍走原来的「打开安装包」路径。
///
/// 这里锁的是**分流决策与文案**，真实进程替换由 macos/Runner/updater.sh
/// 与 test/updater_script_test.dart 负责（那里跑真文件系统）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/update_download.dart';

void main() {
  group('自更新分流：只有 macOS 走自动替换', () {
    test('macOS 支持应用内自动安装', () {
      expect(supportsInAppSelfUpdate(TargetPlatform.macOS), isTrue);
    });

    test('安卓/Windows/iOS 不走自替换（各自另有机制或不支持）', () {
      // 安卓：系统安装器拉起即可，本来就不需要我们替换自己
      expect(supportsInAppSelfUpdate(TargetPlatform.android), isFalse);
      // Windows：自替换涉及运行中 exe 被锁定，本版先不做，退回打开安装包
      expect(supportsInAppSelfUpdate(TargetPlatform.windows), isFalse);
      expect(supportsInAppSelfUpdate(TargetPlatform.iOS), isFalse);
      expect(supportsInAppSelfUpdate(TargetPlatform.linux), isFalse);
    });

    test('platform 覆盖：测试环境下可覆写', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(supportsInAppSelfUpdate(), isTrue);
    });
  });

  group('安装包格式：桌面自替换用 zip，不是 dmg', () {
    test('macOS 期望的直链是 zip', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final info = UpdateInfo(
        latestVersion: '2.1.0',
        downloadUrl: 'https://example.com/releases',
        assets: const {
          'android': 'https://example.com/AStock-2.1.0-Android.apk',
          'macos': 'https://example.com/AStock-2.1.0-macOS.zip',
          'macos_dmg': 'https://example.com/AStock-2.1.0-macOS.dmg',
        },
      );
      expect(assetUrlFor(info), 'https://example.com/AStock-2.1.0-macOS.zip');
    });

    test('安卓仍取 apk', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final info = UpdateInfo(
        latestVersion: '2.1.0',
        downloadUrl: 'https://example.com/releases',
        assets: const {
          'android': 'https://example.com/AStock-2.1.0-Android.apk',
          'macos': 'https://example.com/AStock-2.1.0-macOS.zip',
        },
      );
      expect(assetUrlFor(info), 'https://example.com/AStock-2.1.0-Android.apk');
    });

    test('缺少本平台直链时返回 null（退回打开下载页）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final info = UpdateInfo(
        latestVersion: '2.1.0',
        downloadUrl: 'https://example.com/releases',
        assets: const {'android': 'https://example.com/a.apk'},
      );
      expect(assetUrlFor(info), isNull);
    });
  });

  group('下载保存目录', () {
    test('桌面自替换的 zip 落临时目录，不落用户「下载」文件夹', () {
      // 装完即删，安装包留在 ~/Downloads 是纯垃圾
      expect(updateDownloadDirFor(TargetPlatform.macOS), UpdateSaveDir.temp);
      expect(updateDownloadDirFor(TargetPlatform.android), UpdateSaveDir.temp);
    });

    test('Windows 暂不支持自替换，仍用下载文件夹（用户可见）', () {
      expect(updateDownloadDirFor(TargetPlatform.windows), UpdateSaveDir.downloads);
    });
  });
}
