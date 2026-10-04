import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/eastmoney_client.dart';
import 'package:stock/data/sina_client.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tencent_client.dart';
import 'package:stock/data/tushare_client.dart';

void main() {
  // 假日历：1/1、1/2、1/5、1/6、1/9 开市，1/3、1/4 休市。
  const openDates = ['20260101', '20260102', '20260105', '20260106', '20260109'];
  const closedDates = ['20260103', '20260104'];

  late Directory tmp;
  late BarRepository repo;
  late List<String> dailyRequested;
  late int stockBasicCalls;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stocksync');
    repo = BarRepository('${tmp.path}/t.db');
    dailyRequested = [];
    stockBasicCalls = 0;
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  TushareClient fakeClient() => TushareClient(
        token: 'tok',
        http: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final api = body['api_name'] as String;
          final params = body['params'] as Map<String, dynamic>;
          http.Response resp(List<String> fields, List<List<dynamic>> items) =>
              http.Response.bytes(
                utf8.encode(jsonEncode({
                  'code': 0,
                  'data': {'fields': fields, 'items': items},
                })),
                200,
              );
          switch (api) {
            case 'trade_cal':
              return resp(
                ['cal_date', 'is_open'],
                [
                  for (final d in openDates) [d, '1'],
                  for (final d in closedDates) [d, '0'],
                ],
              );
            case 'stock_basic':
              stockBasicCalls++;
              return resp(['ts_code', 'name'], [
                ['S1.SH', '股票一'],
                ['S2.SZ', '股票二'],
              ]);
            case 'daily':
              final td = params['trade_date'] as String;
              dailyRequested.add(td);
              return resp(
                ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
                [
                  ['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0],
                  ['S2.SZ', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0],
                ],
              );
            default:
              throw StateError('unexpected api $api');
          }
        }),
      );

  SyncService svc(DateTime now) =>
      SyncService(fakeClient(), repo, now: () => now);

  test('首次同步回填最近 N 个已收盘交易日', () async {
    final r = await svc(DateTime(2026, 1, 8, 18)).sync(backfillDays: 3);
    expect(r.dates, 3);
    expect(r.rows, 6);
    expect(dailyRequested, ['20260102', '20260105', '20260106']);
    expect(repo.maxTradeDate(), '20260106');
    expect(stockBasicCalls, 1);
  });

  test('当天未收盘的日期不会被拉取', () async {
    await svc(DateTime(2026, 1, 9, 10)).sync(backfillDays: 3);
    expect(dailyRequested.contains('20260109'), isFalse);
  });

  test('增量同步：没有新交易日时不重复请求', () async {
    final now = DateTime(2026, 1, 8, 18);
    await svc(now).sync(backfillDays: 3);
    final again = await svc(now).sync();
    expect(again.dates, 0);
    expect(dailyRequested.length, 3);
  });

  test('限频 40203 自动等待重试后成功', () async {
    var dailyCalls = 0;
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['api_name'] == 'daily') {
          dailyCalls++;
          if (dailyCalls == 1) {
            return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 40203, 'msg': '频率超限'})),
              200,
            );
          }
          final td = ((body['params'] as Map)['trade_date']) as String;
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {
                'fields': ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
                'items': [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
              },
            })),
            200,
          );
        }
        if (body['api_name'] == 'stock_basic') stockBasicCalls++;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': ['cal_date', 'is_open'], 'items': [['20260106', '1']]},
          })),
          200,
        );
      }),
    );
    final repo2 = repo;
    final s = SyncService(client, repo2,
        now: () => DateTime(2026, 1, 8, 18), retryWait: Duration.zero);
    final r = await s.sync(backfillDays: 3, rateDelay: Duration.zero);
    expect(dailyCalls, 2, reason: '第一次 40203 后应重试一次');
    expect(r.rows, 1);
  });

  test('stock_basic 失败不阻断行情同步', () async {
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final api = body['api_name'] as String;
        if (api == 'stock_basic') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40203, 'msg': 'stock_basic 频率超限'})),
            200,
          );
        }
        if (api == 'trade_cal') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {'fields': ['cal_date', 'is_open'], 'items': [['20260106', '1']]},
            })),
            200,
          );
        }
        final td = ((body['params'] as Map)['trade_date']) as String;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'fields': ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              'items': [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
            },
          })),
          200,
        );
      }),
    );
    final emptyEm = EastmoneyClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'data': {'total': 0, 'diff': []},
            })),
            200,
          )),
    );
    final r = await SyncService(client, repo,
            now: () => DateTime(2026, 1, 8, 18), eastmoney: emptyEm)
        .sync(backfillDays: 3, rateDelay: Duration.zero);
    expect(r.dates, 1, reason: '股票列表失败不应影响日线同步');
  });

  test('tushare 股票列表限频时自动降级东方财富补齐名称', () async {
    final em = EastmoneyClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'data': {
                'total': 2,
                'diff': [
                  {'f12': '600001', 'f13': 1, 'f14': '东财一'},
                  {'f12': '000002', 'f13': 0, 'f14': '东财二'},
                ],
              },
            })),
            200,
          )),
    );
    final tushare = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final api = body['api_name'] as String;
        http.Response resp(List<String> fields, List<List<dynamic>> items) =>
            http.Response.bytes(
              utf8.encode(jsonEncode({
                'code': 0,
                'data': {'fields': fields, 'items': items},
              })),
              200,
            );
        switch (api) {
          case 'stock_basic':
            return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 40203, 'msg': 'stock_basic 频率超限'})),
              200,
            );
          case 'trade_cal':
            return resp(['cal_date', 'is_open'], [['20260930', '1']]);
          case 'daily':
            final td = ((body['params'] as Map)['trade_date']) as String;
            return resp(
              ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
            );
          default:
            return resp(['ts_code', 'name'], []);
        }
      }),
    );

    final r = await SyncService(tushare, repo,
            now: () => DateTime(2026, 9, 30, 18), eastmoney: em)
        .sync(backfillDays: 3, rateDelay: Duration.zero);

    expect(r.dates, 1, reason: '名单失败不影响日线同步');
    final names = repo.stockNames();
    expect(names['600001.SH'], '东财一', reason: '名称应来自东方财富降级源');
    expect(names['000002.SZ'], '东财二');
  });

  test('tushare daily 限频时自动降级新浪逐股补数', () async {
    // 预置 600000.SH 39 根日线（2026-08-22 起），同步水位 20260929。
    final dates = [
      for (var i = 0; i < 39; i++)
        DateTime(2026, 8, 22)
            .add(Duration(days: i))
            .toIso8601String()
            .substring(0, 10)
            .replaceAll('-', '')
    ];
    repo.upsertBars([
      for (final d in dates)
        DailyRow(
            tsCode: '600000.SH',
            tradeDate: d,
            open: 10.0, high: 10.0, low: 10.0, close: 10.0, vol: 100.0, amount: 1),
    ]);
    expect(repo.maxTradeDate(), dates.last);

    final tushare = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final api = body['api_name'] as String;
        if (api == 'daily') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40203, 'msg': 'daily 频率超限'})),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': ['cal_date', 'is_open'], 'items': [['20260930', '1']]},
          })),
          200,
        );
      }),
    );
    final sina = SinaClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode([
              {
                'day': '2026-09-30',
                'open': '10.0',
                'high': '10.6',
                'low': '10.0',
                'close': '10.5',
                'volume': '920000',
              },
            ])),
            200,
          )),
    );

    final r = await SyncService(tushare, repo,
            now: () => DateTime(2026, 9, 30, 18),
            retryWait: Duration.zero,
            sina: sina)
        .sync(backfillDays: 3, rateDelay: Duration.zero);

    expect(r.rows, 1, reason: '新浪应补上 20260930 这天');
    expect(repo.maxTradeDate(), '20260930');
    final bars = repo.loadAllStocks().firstWhere((s) => s.symbol == '600000.SH').bars;
    expect(bars.last.close, 10.5);
    expect(bars.last.volume, 9200);
  });

  test('tushare daily 不可用时降级新浪逐股补数（不复权·手口径）', () async {
    // 预置 600000.SH 39 根历史，使逐股备源有可遍历的本地代码（空库会去拉名单）
    final dates = [
      for (var i = 0; i < 39; i++)
        DateTime(2026, 8, 22).add(Duration(days: i)).toIso8601String().substring(0, 10).replaceAll('-', '')
    ];
    repo.upsertBars([
      for (final d in dates)
        DailyRow(tsCode: '600000.SH', tradeDate: d,
            open: 10.0, high: 10.0, low: 10.0, close: 10.0, vol: 100.0, amount: 1),
    ]);
    final tushare = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final api = (jsonDecode(req.body) as Map<String, dynamic>)['api_name'] as String;
        if (api == 'daily') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40203, 'msg': 'daily 频率超限'})),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': ['cal_date', 'is_open'], 'items': [['20260930', '1']]},
          })),
          200,
        );
      }),
    );
    final sina = SinaClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode([
              {
                'day': '2026-09-30',
                'open': '10.0',
                'high': '10.6',
                'low': '10.0',
                'close': '10.5',
                'volume': '920000',
              },
            ])),
            200,
          )),
    );

    final r = await SyncService(tushare, repo,
            now: () => DateTime(2026, 9, 30, 18),
            retryWait: Duration.zero,
            sina: sina)
        .sync(backfillDays: 3, rateDelay: Duration.zero);

    expect(r.rows, 1);
    final bars = repo.loadAllStocks().firstWhere((s) => s.symbol == '600000.SH').bars;
    expect(bars.last.close, 10.5);
    expect(bars.last.volume, 9200, reason: '新浪的股已换算成手');
  });

  test('东财也不可用时用腾讯逐股回填名称', () async {
    final tushare = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final api = body['api_name'] as String;
        http.Response resp(List<String> fields, List<List<dynamic>> items) =>
            http.Response.bytes(
              utf8.encode(jsonEncode({
                'code': 0,
                'data': {'fields': fields, 'items': items},
              })),
              200,
            );
        if (api == 'stock_basic') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40203, 'msg': '限频'})),
            200,
          );
        }
        if (api == 'trade_cal') {
          return resp(['cal_date', 'is_open'], [['20260930', '1']]);
        }
        final td = ((body['params'] as Map)['trade_date']) as String;
        return resp(
          ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
          [['600000.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
        );
      }),
    );
    // 东财 clist 返回 200 但内容是网页 → jsonDecode 抛异常，模拟被网络拦截。
    final brokenEm = EastmoneyClient(
      http: MockClient((req) async => http.Response('<html>blocked</html>', 200)),
    );
    final tencent = TencentClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {
                'sh600000': {
                  'qfqday': [
                    ['2026-09-30', '1.0', '1.0', '1.0', '1.0', '100'],
                  ],
                  'qt': {
                    'sh600000': ['1', '浦发银行', '600000'],
                  },
                },
              },
            })),
            200,
          )),
    );

    await SyncService(tushare, repo,
            now: () => DateTime(2026, 9, 30, 18),
            retryWait: Duration.zero,
            eastmoney: brokenEm,
            tencent: tencent)
        .sync(backfillDays: 3, rateDelay: Duration.zero);

    expect(repo.stockNames()['600000.SH'], '浦发银行', reason: '东财挂时应由腾讯逐股回填名称');
  });

  test('交易日历不可用时退化为工作日候选（跳过周末）', () async {
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final api = body['api_name'] as String;
        if (api == 'trade_cal') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 40203, 'msg': 'trade_cal 频率超限(1次/小时)'})),
            200,
          );
        }
        if (api == 'daily') {
          final td = ((body['params'] as Map)['trade_date']) as String;
          dailyRequested.add(td);
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {
                'fields': ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
                'items': [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
              },
            })),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': ['ts_code', 'name'], 'items': []},
          })),
          200,
        );
      }),
    );
    // 2026-01-08 是周四；当天 18 点已过 17 点截止，可拉。最近 3 个工作日 = 1/8(四)、1/7(三)、1/6(二)。
    final r = await SyncService(client, repo,
            now: () => DateTime(2026, 1, 8, 18), retryWait: Duration.zero)
        .sync(backfillDays: 3, rateDelay: Duration.zero);
    expect(dailyRequested, ['20260106', '20260107', '20260108']);
    expect(r.dates, 3);
  });

  test('增量同步：新交易日出现后只拉那一天', () async {
    await svc(DateTime(2026, 1, 8, 18)).sync(backfillDays: 3);
    final r = await svc(DateTime(2026, 1, 9, 18)).sync();
    expect(r.dates, 1);
    expect(dailyRequested, ['20260102', '20260105', '20260106', '20260109']);
  });
}
