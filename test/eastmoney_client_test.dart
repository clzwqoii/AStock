import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/eastmoney_client.dart';

void main() {
  test('stockList 分页拉取并按代码前缀映射市场后缀', () async {
    final pages = {
      1: [
        {'f12': '000581', 'f13': 0, 'f14': '威孚高科'},
        {'f12': '600000', 'f13': 1, 'f14': '浦发银行'},
      ],
      2: [
        {'f12': '830799', 'f13': 2, 'f14': '艾融软件'},
      ],
    };
    final requestedPn = <int>[];
    final client = EastmoneyClient(
      pageSize: 2,
      http: MockClient((req) async {
        final pn = int.parse(req.url.queryParameters['pn']!);
        requestedPn.add(pn);
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {'total': 3, 'diff': pages[pn]},
          })),
          200,
        );
      }),
    );

    final rows = await client.stockList();

    expect(requestedPn, [1, 2]);
    expect(rows.map((r) => r.tsCode).toList(), ['000581.SZ', '600000.SH', '830799.BJ']);
    expect(rows[0].name, '威孚高科');
    expect(rows[2].name, '艾融软件');
  });

  test('total 为 0 时返回空列表', () async {
    final client = EastmoneyClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'data': {'total': 0, 'diff': []},
            })),
            200,
          )),
    );
    expect(await client.stockList(), isEmpty);
  });

  test('dailyBars 请求 fqt=0 不复权，字段映射与口径换算正确', () async {
    // 期望值来自 2026-10-06 对 push2his 的 curl 实测（浦发银行 2023-01-03），
    // 与 tushare 不复权口径逐位一致：vol 单位手、amount 单位元（换算成千元）。
    Uri? requested;
    final client = EastmoneyClient(
      http: MockClient((req) async {
        requested = req.url;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {
              'code': '600000',
              'klines': [
                // f51 日期, f52 开, f53 收, f54 高, f55 低, f56 量(手), f57 额(元)
                '2023-01-03,7.27,7.23,7.28,7.17,258925,187094064.00',
                '2023-01-04,7.20,7.24,7.26,7.16,301455,217886328.00',
              ],
            },
          })),
          200,
        );
      }),
    );

    final bars = await client.dailyBars('600000.SH', beg: '20230101');

    expect(requested!.queryParameters['fqt'], '0', reason: '必须是不复权口径');
    expect(requested!.queryParameters['klt'], '101');
    expect(requested!.queryParameters['beg'], '20230101', reason: '区间下界透传，增量场景避免整段白拉');
    expect(requested!.queryParameters['secid'], '1.600000');
    expect(bars, hasLength(2));
    final first = bars[0];
    expect(first.tradeDate, '20230103');
    expect(first.open, 7.27);
    expect(first.close, 7.23, reason: 'f52/f53 是开/收——字段顺序是开收高低，别按高低收开映射');
    expect(first.high, 7.28);
    expect(first.low, 7.17);
    expect(first.vol, 258925, reason: '东财量已是手，与主源同口径');
    expect(first.amount, closeTo(187094.064, 0.001), reason: '元→千元（÷1000）');
  });

  test('dailyBars 深市 secid 走 0，无数据返回空列表', () async {
    final secids = <String>[];
    final client = EastmoneyClient(
      http: MockClient((req) async {
        secids.add(req.url.queryParameters['secid']!);
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': null})),
          200,
        );
      }),
    );
    expect(await client.dailyBars('000001.SZ'), isEmpty);
    expect(await client.dailyBars('600519.SH', beg: '20260518'), isEmpty);
    expect(secids, ['0.000001', '1.600519']);
  });
}
