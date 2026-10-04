import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/tencent_client.dart';

void main() {
  test('dailyBars 请求腾讯日K并解析蜡烛数组（开高低收顺序）', () async {
    String? capturedParam;
    final client = TencentClient(
      http: MockClient((req) async {
        capturedParam = req.url.queryParameters['param'];
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'sh600000': {
                'qfqday': [
                  ['2026-09-29', '10.0', '10.2', '10.3', '9.8', '8800'],
                  ['2026-09-30', '10.2', '10.5', '10.6', '10.0', '9200'],
                ],
              },
            },
          })),
          200,
        );
      }),
    );

    final rows = await client.dailyBars('600000.SH', count: 320);

    expect(capturedParam, 'sh600000,day,,,320,qfq');
    expect(rows, hasLength(2));
    expect(rows.last.tradeDate, '20260930');
    expect(rows.last.open, 10.2);
    expect(rows.last.close, 10.5, reason: '腾讯数组顺序是 开收高低');
    expect(rows.last.high, 10.6);
    expect(rows.last.low, 10.0);
    expect(rows.last.vol, 9200);
    expect(rows.last.amount, 0, reason: '该接口无成交额');
  });

  test('北交所代码不支持时抛 ArgumentError', () async {
    final client = TencentClient(http: MockClient((req) async => http.Response('{}', 200)));
    expect(() => client.dailyBars('830799.BJ'), throwsArgumentError);
  });

  test('响应缺 day 数据时返回空列表', () async {
    final client = TencentClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({'code': 0, 'data': {'sh600000': {}}})),
            200,
          )),
    );
    expect(await client.dailyBars('600000.SH'), isEmpty);
  });
}
