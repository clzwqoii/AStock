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
}
