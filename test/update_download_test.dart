/// 应用内更新：流式下载进度、update.json assets 解析、平台直链选择。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as h;
import 'package:http/testing.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/update_download.dart';

void main() {
  group('downloadUpdatePackage', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('upd'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('流式写盘并回调进度，最终到达总长', () async {
      final client = MockClient.streaming((req, body) async => h.StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5, 6],
            ]),
            200,
            contentLength: 6,
          ));
      final events = <(int, int?)>[];
      final file = await downloadUpdatePackage(
        'https://x/AStock-9.9.9-Android.apk',
        'test.apk',
        onProgress: (r, t) => events.add((r, t)),
        client: client,
        saveDir: tmp,
      );
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(events.first, (3, 6));
      expect(events.last, (6, 6));
    });

    test('服务器未给长度时 total 为 null，仍完成写盘', () async {
      final client = MockClient.streaming((req, body) async => h.StreamedResponse(
            Stream.fromIterable([
              [7, 8],
            ]),
            200,
          ));
      final events = <(int, int?)>[];
      final file = await downloadUpdatePackage(
        'https://x/pkg.dmg',
        'pkg.dmg',
        onProgress: (r, t) => events.add((r, t)),
        client: client,
        saveDir: tmp,
      );
      expect(await file.readAsBytes(), [7, 8]);
      expect(events.last.$1, 2);
      expect(events.last.$2, isNull);
    });

    test('非 200 抛错且不残留半截文件', () async {
      final client = MockClient.streaming((req, body) async =>
          h.StreamedResponse(Stream.fromIterable([[1, 2]]), 404));
      await expectLater(
        downloadUpdatePackage('https://x/a.apk', 'a.apk',
            client: client, saveDir: tmp),
        throwsStateError,
      );
      expect(File('${tmp.path}/a.apk').existsSync(), isFalse);
    });
  });

  group('assets 解析与平台直链', () {
    test('checkForUpdate 解析 update.json 的 assets 字段', () async {
      final client = MockClient((req) async => h.Response(
            jsonEncode({
              'version': '9.9.9',
              'url': 'https://gitee.com/x/releases',
              'assets': {'android': 'https://g/apk', 'macos': 'https://g/dmg'},
            }),
            200,
          ));
      final info = await checkForUpdate(
          currentVersion: '1.0.3', client: client, urls: ['https://x/update.json']);
      expect(info!.assets['android'], 'https://g/apk');
      expect(info.assets['macos'], 'https://g/dmg');
    });

    test('旧清单无 assets 字段时为空 map，downloadUrl 照常', () async {
      final client = MockClient((req) async => h.Response(
            jsonEncode({'version': '9.9.9', 'url': 'https://gitee.com/x/releases'}),
            200,
          ));
      final info = await checkForUpdate(
          currentVersion: '1.0.3', client: client, urls: ['https://x/update.json']);
      expect(info!.assets, isEmpty);
      expect(info.downloadUrl, 'https://gitee.com/x/releases');
    });

    test('assetUrlFor 缺失平台直链时返回 null（走下载页兜底）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        expect(
          assetUrlFor(UpdateInfo(latestVersion: '9', downloadUrl: 'u', assets: const {'android': 'a'})),
          isNull,
        );
        expect(assetUrlFor(UpdateInfo(latestVersion: '9', downloadUrl: 'u')), isNull);
        expect(
          assetUrlFor(UpdateInfo(latestVersion: '9', downloadUrl: 'u', assets: const {'macos': 'dmg'})),
          'dmg',
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(
          assetUrlFor(UpdateInfo(latestVersion: '9', downloadUrl: 'u', assets: const {'macos': 'dmg'})),
          isNull,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
