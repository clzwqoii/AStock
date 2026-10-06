/// 检查更新的源竞速：必须等所有源都给出「有新版」或「都失败」才能下结论。
///
/// 真机 bug（2026-10-06）：首次点「检查更新」说已是最新，再点一次才拿到新版本。
/// 根因是竞速逻辑把「某个源说没有新版」当成终局结论立刻返回——而那个源可能
/// 是 CDN 缓存的旧版本（update.json 刚从 2.1.0 改到 2.2.0，几秒内缓存不一致）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as h;
import 'package:http/testing.dart';
import 'package:stock/app_logic.dart';

/// 造一个返回固定 update.json 的客户端。
h.Client _clientReturning(String version) => MockClient((req) async {
      final body = jsonEncode({
        'version': version,
        'url': 'https://example.com/releases',
        'assets': {
          'android': 'https://example.com/A-$version.apk',
          'macos': 'https://example.com/A-$version-macOS.zip',
        },
      });
      return h.Response(body, 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

/// 失败的客户端（模拟墙/超时）。
h.Client _failingClient() =>
    MockClient((req) async => throw const SocketExceptionStub());

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

void main() {
  const urls = ['https://a.test/update.json', 'https://b.test/update.json'];

  test('慢源有新版：即使快源说「已是最新」，也要等慢源给出结论', () async {
    // a.test（快）说没有新版 —— 这是 CDN 旧缓存
    // b.test（慢）说有新版 —— 这是权威源
    final client = MockClient((req) async {
      if (req.url.host == 'a.test') {
        return h.Response(
          jsonEncode({'version': '2.1.0', 'url': '', 'assets': {}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return h.Response(
        jsonEncode({
          'version': '2.2.0',
          'url': 'https://example.com/releases',
          'assets': {
            'android': 'https://example.com/A.apk',
            'macos': 'https://example.com/A-macOS.zip',
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final info = await checkForUpdate(
      currentVersion: '2.1.0',
      client: client,
      urls: urls,
    );

    expect(info, isNotNull, reason: '必须有新版：慢源才是权威，不能被快的旧缓存盖掉');
    expect(info!.latestVersion, '2.2.0');
  });

  test('慢源失败 + 快源说无新版：仍然返回「已是最新」而非抛错', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'a.test') {
        return h.Response(
          jsonEncode({'version': '2.1.0', 'url': '', 'assets': {}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      throw const SocketExceptionStub();
    });

    final info = await checkForUpdate(
      currentVersion: '2.1.0',
      client: client,
      urls: urls,
    );
    expect(info, isNull, reason: '所有可用源都没有新版 → 已是最新，不该抛错');
  });

  test('所有源都失败：抛出错误（而不是静默说「已是最新」）', () async {
    expect(
      () => checkForUpdate(
        currentVersion: '2.1.0',
        client: _failingClient(),
        urls: urls,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('单源可用：正常工作', () async {
    final info = await checkForUpdate(
      currentVersion: '2.1.0',
      client: _clientReturning('2.2.0'),
      urls: const ['https://a.test/update.json'],
    );
    expect(info?.latestVersion, '2.2.0');
  });

  test('单源说无新版：返回 null', () async {
    final info = await checkForUpdate(
      currentVersion: '2.2.0',
      client: _clientReturning('2.2.0'),
      urls: const ['https://a.test/update.json'],
    );
    expect(info, isNull);
  });
}
