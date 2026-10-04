import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/eastmoney_client.dart';
import 'package:stock/data/tencent_client.dart';

void main() {
  test('TencentClient.stockName 从 qt 块解析名称', () async {
    final client = TencentClient(
      http: MockClient((req) async {
        expect(req.url.path, '/appstock/app/fqkline/get');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'sz000581': {
                'qfqday': [
                  ['2026-09-30', '5.0', '5.1', '5.2', '4.9', '100'],
                ],
                'qt': {
                  'sz000581': ['1', '威孚高科', '000581'],
                },
              },
            },
          })),
          200,
        );
      }),
    );
    expect(await client.stockName('000581.SZ'), '威孚高科');
  });

  test('EastmoneyClient.stockName 走 push2his、带 UA、解析 name 字段', () async {
    final headers = <String, String>{};
    var path = '';
    final client = EastmoneyClient(
      http: MockClient((req) async {
        path = req.url.path;
        headers.addAll(req.headers);
        expect(req.url.queryParameters['secid'], '1.600000');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {'code': '600000', 'name': '浦发银行'},
          })),
          200,
        );
      }),
    );
    expect(await client.stockName('600000.SH'), '浦发银行');
    expect(path, '/api/qt/stock/kline/get');
    expect(
        headers.keys.any((k) => k.toLowerCase() == 'user-agent'), isTrue);
  });

  test('两家都不支持北交所', () async {
    expect(() => TencentClient(http: MockClient((r) async => http.Response('{}', 200)))
        .stockName('830799.BJ'), throwsArgumentError);
    expect(() => EastmoneyClient(http: MockClient((r) async => http.Response('{}', 200)))
        .stockName('830799.BJ'), throwsArgumentError);
  });
}
