import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/sina_client.dart';
import 'package:stock/data/tushare_client.dart';

import 'fixtures.dart';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('applogic');
    dbPath = '${tmp.path}/t.db';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('runScreening 返回展示行（涨跌/涨跌幅/量比/成交额/MA20）与数据截止日', () async {
    seedStocks(dbPath);
    final r = await runScreening(dbPath, [ruleById('volume_surge'), ruleById('pct_change_up')]);
    expect(r.total, 2);
    expect(r.picked.map((s) => s.symbol), ['S1.SH']);
    final row = r.picked.single;
    expect(row.close, 10.5);
    expect(row.change, closeTo(0.5, 1e-9));
    expect(row.changePct, closeTo(5.0, 1e-9));
    expect(row.volumeRatio, 3.0);
    expect(row.ma20, closeTo(10.025, 1e-9)); // 19 根 10.0 + 1 根 10.5
    expect(row.amountWan, closeTo(0.1, 1e-9)); // amount=1千元 → 0.1 万
    expect(row.name, isNull, reason: 'seed 未写 stocks 表，名称应降级为 null');
    expect(r.dataDate, '20261002');

    final single = await runScreening(dbPath, [ruleById('pct_change_up')]);
    expect(single.picked.map((s) => s.symbol), ['S1.SH', 'S2.SZ']);
  });

  test('loadStockDetail 返回单只股票 bars+快照+名称；无数据返回 null', () async {
    seedStocks(dbPath);
    final repo = BarRepository(dbPath);
    repo.upsertStocks([(tsCode: 'S1.SH', name: '测试名')]);
    repo.close();

    final d = await loadStockDetail(dbPath, 'S1.SH');
    expect(d, isNotNull);
    expect(d!.bars, hasLength(40));
    expect(d.snapshot.close, 10.5);
    expect(d.name, '测试名');

    expect(await loadStockDetail(dbPath, 'NOPE.SZ'), isNull, reason: '无数据的代码返回 null');
  });

  test('checkForUpdate 比较版本号：有新版返回信息，否则 null', () async {
    http.Client mock(String version) => MockClient((req) async => http.Response.bytes(
          utf8.encode(jsonEncode({'version': version, 'url': 'https://example.com/dl'})),
          200,
        ));

    final newer = await checkForUpdate(
        currentVersion: '1.0.0', client: mock('1.2.0'), urls: ['https://a/update.json']);
    expect(newer?.latestVersion, '1.2.0');
    expect(newer?.downloadUrl, 'https://example.com/dl');

    expect(await checkForUpdate(
        currentVersion: '1.2.0', client: mock('1.2.0'), urls: ['https://a/update.json']), isNull);
    expect((await checkForUpdate(
            currentVersion: '1.9.0', client: mock('1.10.0'), urls: ['https://a/update.json']))
        ?.latestVersion,
        '1.10.0', reason: '版本号按数值比较，1.10 > 1.9');
  });

  test('多更新源：GitHub 挂了自动用 Gitee（国内可用）', () async {
    final client = MockClient((req) async {
      if (req.url.host.contains('github')) {
        return http.Response('not found', 500); // GitHub 快速失败
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode({'version': '1.5.0', 'url': 'https://gitee.com/dl'})), 200);
    });
    final info = await checkForUpdate(
      currentVersion: '1.0.0',
      client: client,
      urls: [
        'https://raw.githubusercontent.com/u/r/main/update.json',
        'https://gitee.com/u/r/raw/master/update.json',
      ],
    );
    expect(info?.latestVersion, '1.5.0');
    expect(info?.downloadUrl, 'https://gitee.com/dl');
  });

  test('多更新源全失败时抛出错误', () async {
    final client = MockClient((req) async => http.Response('boom', 500));
    await expectLater(
      checkForUpdate(
        currentVersion: '1.0.0',
        client: client,
        urls: ['https://a/update.json', 'https://b/update.json'],
      ),
      throwsA(anything),
    );
  });

  test('runSync 用注入的客户端完成增量同步', () async {
    final client = fakeSyncClient((td) {
      dailySeen.add(td);
      return [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]];
    });
    final progress = <String>[];
    final r = await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 9, 30, 18),
      clientFactory: (_) => client,
      onProgress: progress.add,
    );
    expect(r.dates, 1);
    expect(r.rows, 1);
    expect(progress, isNotEmpty);

    final after = await runScreening(dbPath, [ruleById('close_above_ma20')]);
    expect(after.total, 1);
  });

  test('runSync 接线新浪备源：tushare daily 故障时自动逐股降级', () async {
    // 生产构造点（runSync / bin/sync.dart）必须把新浪传给 SyncService，
    // 否则日线降级链形同虚设：tushare daily 一挂就原样抛出，40203 还会
    // 空转 5 次 65 秒。这里 daily 返回非 40203 错误码——不触发限频等待，
    // 直接考验「有没有备源」这一根因。
    seedStocks(dbPath); // S1.SH / S2.SZ 各 40 根，止于 20261002
    final tushare = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final api =
            (jsonDecode(req.body) as Map<String, dynamic>)['api_name'] as String;
        if (api == 'daily') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 50000, 'msg': '接口异常'})),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': ['cal_date', 'is_open'], 'items': [['20261005', '1']]},
          })),
          200,
        );
      }),
    );
    final sina = SinaClient(
      http: MockClient((req) async => http.Response.bytes(
            utf8.encode(jsonEncode([
              {
                'day': '2026-10-05',
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

    final r = await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 10, 5, 18),
      clientFactory: (_) => tushare,
      sinaFactory: () => sina,
    );
    expect(r.rows, 2, reason: 'tushare daily 不可用时两只股票都应由新浪补上 20261005');
    final repo = BarRepository(dbPath);
    expect(repo.maxTradeDate(), '20261005');
    repo.close();
  });
}

final dailySeen = <String>[];

/// 假 tushare：日历给 9/30 开市，daily 按 trade_date 返回 [itemsFor] 的结果。
TushareClient fakeSyncClient(List<List<dynamic>> Function(String tradeDate) itemsFor) {
  http.Response resp(List<String> fields, List<List<dynamic>> items) => http.Response.bytes(
        utf8.encode(jsonEncode({
          'code': 0,
          'data': {'fields': fields, 'items': items},
        })),
        200,
      );
  return TushareClient(
    token: 'tok',
    http: MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final api = body['api_name'] as String;
      switch (api) {
        case 'trade_cal':
          return resp(['cal_date', 'is_open'], [
            ['20260930', '1'],
            ['20261001', '0'],
          ]);
        case 'daily':
          return resp(
            ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
            itemsFor(((body['params'] as Map)['trade_date']) as String),
          );
        default:
          return resp(['ts_code', 'name'], []);
      }
    }),
  );
}

