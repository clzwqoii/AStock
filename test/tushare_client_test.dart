import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/tushare_client.dart';

void main() {
  test('daily 构造正确请求并解析响应', () async {
    var capturedBody = '';
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        capturedBody = req.body;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'fields': ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              'items': [
                ['600000.SH', '20260930', 10.0, 11.0, 9.5, 10.5, 123456.0, 789.0],
              ],
            },
          }),
          200,
        );
      }),
    );

    final rows = await client.daily(tradeDate: '20260930');

    expect(rows, hasLength(1));
    expect(rows.single.tsCode, '600000.SH');
    expect(rows.single.tradeDate, '20260930');
    expect(rows.single.open, 10.0);
    expect(rows.single.close, 10.5);
    expect(rows.single.vol, 123456.0);
    expect(rows.single.amount, 789.0);

    final body = jsonDecode(capturedBody) as Map<String, dynamic>;
    expect(body['api_name'], 'daily');
    expect(body['token'], 'tok');
    expect((body['params'] as Map)['trade_date'], '20260930');
    expect(body['fields'], 'ts_code,trade_date,open,high,low,close,vol,amount');
  });

  test('超出单页上限时自动翻页', () async {
    final total = List.generate(5, (i) => ['00000$i.SZ', '20260930', 1.0, 2.0, 0.5, 1.5, 100.0 + i, 50.0]);
    final offsets = <int>[];
    final client = TushareClient(
      token: 'tok',
      pageSize: 2,
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        offsets.add((body['params'] as Map)['offset'] as int);
        final limit = (body['params'] as Map)['limit'] as int;
        final page = total.skip(offsets.last).take(limit).toList();
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'fields': ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              'items': page,
            },
          }),
          200,
        );
      }),
    );

    final rows = await client.daily(tradeDate: '20260930');

    expect(offsets, [0, 2, 4]);
    expect(rows, hasLength(5));
    expect(rows.last.tsCode, '000004.SZ');
  });

  test('请求超时抛出 TimeoutException（避免界面永远转圈）', () async {
    final client = TushareClient(
      token: 'tok',
      timeout: const Duration(milliseconds: 50),
      http: MockClient((req) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
        client.stockBasic(),
        throwsA(isA<TushareException>().having((e) => e.message, 'message', contains('超时'))));
  });

  test('接口返回错误码时抛异常', () async {
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40001, 'msg': '权限不足'})),
            200,
          )),
    );
    expect(
      () => client.daily(tradeDate: '20260930'),
      throwsA(isA<TushareException>()),
    );
  });
}
