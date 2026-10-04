import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/sina_client.dart';

void main() {
  test('dailyBars 请求新浪日K并解析 JSON 数组', () async {
    String? symbol;
    String? datalen;
    final client = SinaClient(
      http: MockClient((req) async {
        symbol = req.url.queryParameters['symbol'];
        datalen = req.url.queryParameters['datalen'];
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'day': '2026-09-30',
              'open': '10.0',
              'high': '10.6',
              'low': '10.0',
              'close': '10.5',
              'volume': '9200',
            },
          ])),
          200,
        );
      }),
    );

    final rows = await client.dailyBars('600000.SH', count: 400);

    expect(symbol, 'sh600000');
    expect(datalen, '400');
    expect(rows.single.tradeDate, '20260930');
    expect(rows.single.open, 10.0);
    expect(rows.single.high, 10.6);
    expect(rows.single.low, 10.0);
    expect(rows.single.close, 10.5);
    expect(rows.single.vol, 9200);
    expect(rows.single.amount, 0, reason: '该接口无成交额');
  });

  test('北交所代码不支持时抛 ArgumentError', () async {
    final client = SinaClient(http: MockClient((req) async => http.Response('[]', 200)));
    expect(() => client.dailyBars('830799.BJ'), throwsArgumentError);
  });
}
