import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/netease_client.dart';

void main() {
  test('CSV 按列位解析、升序输出、成交额元转千元', () async {
    String? code;
    String? start;
    String? end;
    final client = NeteaseClient(
      http: MockClient((req) async {
        code = req.url.queryParameters['code'];
        start = req.url.queryParameters['start'];
        end = req.url.queryParameters['end'];
        // 头部是 GB2312（utf8 解码会乱码），数据行是 ASCII——按列位解析不受影响。
        const csv = '日期,股票代码,名称,??,??,??,??,??,??\n'
            '2026-09-30,600000,XX,10.0,10.6,10.0,10.5,9200,96600000\n'
            '2026-09-29,600000,XX,10.0,10.3,9.9,10.2,8000,82000000\n';
        return http.Response.bytes(utf8.encode(csv), 200);
      }),
    );

    final rows = await client.dailyBars('600000.SH', start: '20260901', end: '20260930');

    expect(code, '0600000', reason: '沪市前缀 0');
    expect(start, '20260901');
    expect(end, '20260930');
    expect(rows.map((r) => r.tradeDate).toList(), ['20260929', '20260930'],
        reason: '网易返回倒序，客户端应排成升序');
    expect(rows.last.open, 10.0);
    expect(rows.last.high, 10.6);
    expect(rows.last.low, 10.0);
    expect(rows.last.close, 10.5);
    expect(rows.last.vol, 9200);
    expect(rows.last.amount, closeTo(96600, 0.1), reason: '成交额元 → 千元');
  });

  test('深市代码前缀为 1', () async {
    String? code;
    final client = NeteaseClient(
      http: MockClient((req) async {
        code = req.url.queryParameters['code'];
        return http.Response.bytes(
            utf8.encode('日期,代码,名称,A,B,C,D,E,F\n'), 200);
      }),
    );
    await client.dailyBars('000581.SZ');
    expect(code, '1000581', reason: '深市前缀 1');
  });

  test('北交所代码不支持时抛 ArgumentError', () async {
    final client = NeteaseClient(http: MockClient((req) async => http.Response('', 200)));
    expect(() => client.dailyBars('830799.BJ'), throwsArgumentError);
  });
}
