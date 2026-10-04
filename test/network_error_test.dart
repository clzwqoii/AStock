/// 同步失败原因的人话化 + 网络自检。安卓真机上 DNS/代理问题必须一眼看懂。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/data/tushare_client.dart';
import 'package:stock/net_diag.dart';

void main() {
  group('describeSyncError', () {
    test('DNS 解析失败 → 提示已降级新浪 + 关代理/VPN', () {
      final s = describeSyncError(const SocketException(
          "Failed host lookup: 'api.tushare.pro' (OS Error: No address associated with hostname, errno = 7)"));
      expect(s, contains('新浪'));
      expect(s, contains('数据照常入库'));
    });

    test('连接类错误 → 同样走降级文案', () {
      for (final msg in ['Connection refused', 'Connection failed', 'Network is unreachable']) {
        final s = describeSyncError(SocketException(msg));
        expect(s, contains('新浪'));
        expect(s, contains('数据照常入库'));
      }
    });

    test('TLS 握手失败单独提示（代理干扰的典型表现）', () {
      final s = describeSyncError(const HandshakeException('handshake error'));
      expect(s, contains('代理'));
    });

    test('超时有专门文案，不带原始栈', () {
      final s = describeSyncError(TimeoutException('timeout'));
      expect(s, contains('超时'));
    });

    test('token 错误（tushare code 20001 之类）引导去设置页', () {
      final s = describeSyncError(TushareException(20001, 'invalid token'));
      expect(s, contains('token'));
      expect(s, contains('设置'));
    });

    test('限频 40203 保留既有语义', () {
      expect(describeSyncError(TushareException(40203, '频率超限')), contains('限频'));
    });

    test('未知错误仍带上原文，便于反馈', () {
      final s = describeSyncError(Exception('boom'));
      expect(s, contains('boom'));
    });

    test('错误里绝不出现用户 token 值', () {
      final s = describeSyncError(SocketException('token=abcdef123456 failed'));
      expect(s, isNot(contains('abcdef123456')));
    });
  });

  group('diagnoseNetwork', () {
    test('解析成功 + 握手成功 → 报告正常与耗时', () async {
      final s = await diagnoseNetwork(
        host: 'api.tushare.pro',
        lookup: (_) async => [InternetAddress('1.2.3.4')],
        probe: (_) async {},
      );
      expect(s, contains('DNS 正常'));
      expect(s, contains('1.2.3.4'));
      expect(s, contains('HTTPS 正常'));
      expect(s, contains('ms'));
    });

    test('解析失败 → 明确指出该关代理/VPN', () async {
      final s = await diagnoseNetwork(
        lookup: (_) async => throw const SocketException('Failed host lookup'),
        probe: (_) async {},
      );
      expect(s, contains('DNS 解析失败'));
      expect(s, contains('VPN'));
    });

    test('解析成功但连不上 → 说明是连通性问题', () async {
      final s = await diagnoseNetwork(
        lookup: (_) async => [InternetAddress('1.2.3.4')],
        probe: (_) async => throw const SocketException('Connection refused'),
      );
      expect(s, contains('连不上'));
    });
  });
}
