import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/eastmoney_client.dart';
import 'package:stock/data/report_store.dart';
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

  test('runScreening 结果带分阶段耗时（timings）', () async {
    seedStocks(dbPath);
    final r = await runScreening(dbPath, [ruleById('pct_change_up')]);
    final t = r.timings;
    expect(t, isNotNull);
    // 微型库各阶段可能不足 1ms，只断言字段齐全与口径自洽，不钉具体毫秒数。
    expect(t!.loadMs, greaterThanOrEqualTo(0));
    expect(t.screenMs, greaterThanOrEqualTo(0));
    expect(t.assembleMs, greaterThanOrEqualTo(0));
    expect(t.totalMs, greaterThanOrEqualTo(t.loadMs + t.screenMs + t.assembleMs));
    expect(t.poolReused, isFalse);
  });

  test('loadHistoryCoverage：在 isolate 里读真实库，覆盖区间与库内容一致', () async {
    seedStocks(dbPath); // 2 只 × 40 个交易日（20260810~20261002）
    final cov = await loadHistoryCoverage(dbPath);
    expect(cov.isEmpty, isFalse);
    expect(cov.minDate, '20260810');
    expect(cov.maxDate, '20261002');
    expect(cov.tradeDays, 40);
    expect(cov.totalBars, 80);

    // 空库（库文件还不存在，App 首启就是这种）要返回空覆盖而不是抛异常
    final empty = await loadHistoryCoverage('${tmp.path}/fresh.db');
    expect(empty.isEmpty, isTrue);
    expect(empty.tradeDays, 0);
  });

  test('ScreeningService 池子复用：数据不变时第二次不重载，结果与单发一致', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    final r1 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r1.timings!.poolReused, isFalse);
    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.poolReused, isTrue, reason: '数据指纹没变 → 复用池子，不重读库');
    expect(r2.total, r1.total);
    expect([for (final p in r2.picked) p.symbol], [for (final p in r1.picked) p.symbol]);

    final direct = await runScreening(dbPath, [ruleById('pct_change_up')]);
    expect([for (final p in direct.picked) p.symbol], [for (final p in r1.picked) p.symbol],
        reason: '常驻池子与单发路径的结果必须一致');
  });

  test('ScreeningService.releasePool：内存压力时立即释放池子，服务仍可继续用', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    await svc.screen(dbPath, [ruleById('pct_change_up')]);
    final r1 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r1.timings!.poolReused, isTrue);

    svc.releasePool();
    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.poolReused, isFalse, reason: '释放后必须重新加载池子');
    final r3 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r3.timings!.poolReused, isTrue, reason: '释放不销毁服务，之后照常复用');
  });

  // 内存压力（didHaveMemoryPressure）随时可能落在"请求已发出、isolate 还没就绪"
  // 的窗口里。此时回收若照做，screen 的 Future 既拿不到结果也不会报错。
  test('ScreeningService.releasePool：孵化未完成时不回收，本次选股照常出结果', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    final fut = svc.screen(dbPath, [ruleById('pct_change_up')]);
    svc.releasePool(); // 同一 tick：isolate 必然还没就绪

    final r = await fut.timeout(const Duration(seconds: 10));
    expect([for (final p in r.picked) p.symbol], ['S1.SH', 'S2.SZ']);
  });

  test('ScreeningService：多请求并发时先完成的请求不提前触发空闲回收', () async {
    seedStocks(dbPath);
    final svc = ScreeningService(idleTimeout: const Duration(milliseconds: 50));
    addTearDown(svc.dispose);
    final fut1 = svc.screen(dbPath, [ruleById('pct_change_up')]);
    final fut2 = svc.screen(dbPath, [ruleById('pct_change_up')]);
    final results = await Future.wait([fut1, fut2]);
    expect(results[0].picked.length, results[1].picked.length);
  });

  test('ScreeningService.dispose：孵化未完成时在途 screen 以错误收场，不挂起', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    final fut = svc.screen(dbPath, [ruleById('pct_change_up')]);
    svc.dispose(); // 销毁不看在途状态：必须在途请求收场（报错）

    await expectLater(
      fut.timeout(const Duration(seconds: 10)),
      throwsA(isA<StateError>()),
    );
  });

  test('ScreeningService 失效重载：新交易日、回补旧日期、报告更新都会触发重载', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    await svc.screen(dbPath, [ruleById('pct_change_up')]);

    void addBar(String date) {
      final repo = BarRepository(dbPath);
      repo.upsertBars([
        DailyRow(
            tsCode: 'S1.SH',
            tradeDate: date,
            open: 10.0,
            high: 10.0,
            low: 10.0,
            close: 10.5,
            vol: 300.0,
            amount: 1),
      ]);
      repo.close();
    }

    addBar('20261003'); // 新交易日
    final r3 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r3.timings!.poolReused, isFalse, reason: '水位线变了必须重载');

    addBar('20260801'); // 回补更早的历史：水位线不变，但库内容变了
    final r4 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r4.timings!.poolReused, isFalse, reason: '回补不改水位线，按行指纹仍要重载');

    // 回测报告更新（选股评分依赖它）：文件内容变了也要重载
    ReportStore(reportPathFor(dbPath)).save(BacktestReport(
      generatedAt: DateTime.now().toIso8601String(),
      horizons: const [10],
      stockCount: 2,
      baseline: const {},
      results: const {},
    ));
    final r5 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r5.timings!.poolReused, isFalse, reason: '回测报告变了，评分缓存必须跟着换');
  });

  test('runBacktest 报告携带 recent 窗口数据,并把快照写入台账(同日去重)', () async {
    seedStocks(dbPath);
    final reportPath = '${tmp.path}/report.json';
    final r1 = await runBacktest(dbPath, reportPath: reportPath);
    // 漏接线回归:App 内重新回测的报告必须有窗口数据,「最近半年」才有得切。
    expect(r1.recent, isNotEmpty);
    expect(r1.recentBaseline, isNotEmpty);

    final hp = historyPathFor(reportPath);
    final h1 = BacktestHistory.fromJson(
        jsonDecode(File(hp).readAsStringSync()) as Map<String, dynamic>);
    expect(h1.snapshots, hasLength(1));
    expect(h1.snapshots.single.dataDate, '20261002');

    // 同一数据截止日重跑 → 替换不追加。
    await runBacktest(dbPath, reportPath: reportPath);
    final h2 = BacktestHistory.fromJson(
        jsonDecode(File(hp).readAsStringSync()) as Map<String, dynamic>);
    expect(h2.snapshots, hasLength(1));
    // 台账走「临时文件 + rename」原子替换：写完不许留下 .tmp 残骸
    // （残留说明 rename 没走成，下一个写者读到的就是半份数据）。
    final leftovers =
        tmp.listSync().where((e) => e.path.endsWith('.tmp')).toList();
    expect(leftovers, isEmpty, reason: '原子写不许留临时文件：$leftovers');
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
  test('runBackfillSync 区间补拉：水位线之前缺的日期能补上，已有的不重拉', () async {
    // 库内 9/30~10/2 有数据（水位 20261002），9/25 有、9/28 与 9/29 缺。
    // 增量模式只拉水位线之后的日期，永远补不回 9/28、9/29——
    // 这正是手机端「首轮回填没跑成、之后永远补不回历史」的解药。
    final seed = BarRepository(dbPath);
    seed.upsertBars([
      for (final d in ['20260925', '20260930', '20261001', '20261002'])
        DailyRow(
            tsCode: 'S1.SH',
            tradeDate: d,
            open: 10.0,
            high: 10.0,
            low: 10.0,
            close: 10.0,
            vol: 100.0,
            amount: 1),
    ]);
    seed.close();
    dailySeen.clear();
    http.Response resp(List<String> fields, List<List<dynamic>> items) =>
        http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': fields, 'items': items},
          })),
          200,
        );
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final api =
            (jsonDecode(req.body) as Map<String, dynamic>)['api_name'] as String;
        switch (api) {
          case 'trade_cal':
            return resp(['cal_date', 'is_open'], [
              for (final d in ['20260925', '20260928', '20260929', '20261007', '20261008'])
                [d, '1'],
            ]);
          case 'daily':
            final td = ((jsonDecode(req.body)
                as Map<String, dynamic>)['params'] as Map)['trade_date'] as String;
            dailySeen.add(td);
            return resp(
              ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]],
            );
          default:
            return resp(['ts_code', 'name'], []);
        }
      }),
    );
    final r = await runBackfillSync(
      dbPath: dbPath,
      token: 'tok',
      fromDate: '20260925',
      now: () => DateTime(2026, 10, 8, 18),
      clientFactory: (_) => client,
      rateDelay: Duration.zero,
    );
    // 9/28、9/29 都 ≤ 水位线 20261002：增量永远给不了，区间模式必须补上；
    // 库内已有的 9/25 不重复请求
    expect(r.dates, 4);
    expect(dailySeen, ['20260928', '20260929', '20261007', '20261008']);
    expect([for (final d in dailySeen) if (d.compareTo('20260925') < 0) d], isEmpty);
  });

  test('runBackfillSync force：重拉库内已有的半截日，补齐缺失股票', () async {
    // 备源逐股中断的残留：20261001 只入库了 S1.SH，当天全市场还有 S2.SZ。
    // 默认区间回补会整日跳过它（见上一条测试），force 是给用户的修复通路。
    final seed = BarRepository(dbPath);
    seed.upsertBars([
      DailyRow(
          tsCode: 'S1.SH',
          tradeDate: '20261001',
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: 10.0,
          vol: 100.0,
          amount: 1),
    ]);
    seed.close();
    dailySeen.clear();
    http.Response resp(List<String> fields, List<List<dynamic>> items) =>
        http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {'fields': fields, 'items': items},
          })),
          200,
        );
    final client = TushareClient(
      token: 'tok',
      http: MockClient((req) async {
        final api =
            (jsonDecode(req.body) as Map<String, dynamic>)['api_name'] as String;
        switch (api) {
          case 'trade_cal':
            return resp(['cal_date', 'is_open'], [
              ['20261001', '1'],
            ]);
          case 'daily':
            final td = ((jsonDecode(req.body)
                as Map<String, dynamic>)['params'] as Map)['trade_date'] as String;
            dailySeen.add(td);
            return resp(
              ['ts_code', 'trade_date', 'open', 'high', 'low', 'close', 'vol', 'amount'],
              [
                ['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0],
                ['S2.SZ', td, 2.0, 2.0, 2.0, 2.0, 100.0, 10.0],
              ],
            );
          default:
            return resp(['ts_code', 'name'], []);
        }
      }),
    );
    final r = await runBackfillSync(
      dbPath: dbPath,
      token: 'tok',
      fromDate: '20261001',
      force: true,
      now: () => DateTime(2026, 10, 2, 18),
      clientFactory: (_) => client,
      rateDelay: Duration.zero,
    );

    expect(dailySeen, ['20261001'], reason: 'force 时已有数据的日期也要重拉');
    expect(r.dates, 1);
    final repo = BarRepository(dbPath);
    expect(repo.rowCountOnDate('20261001'), 2, reason: '重拉后半截日补齐为两只');
    repo.close();
  });

  test('runBackfillSync 透传东财备源：tushare daily 故障时用注入的东财补上区间', () async {
    // 回补是最容易撞 40203 的入口（1.2s/日 × 三年 ≈ 700 次），降级链必须
    // 在这条路径上同样可注入、且真的接上——否则测试只能打到真实网络，
    // 生产里「回补不进备源」这类回归无处可测。
    seedStocks(dbPath);
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
            'data': api == 'trade_cal'
                ? {
                    'fields': ['cal_date', 'is_open'],
                    'items': [
                      ['20261005', '1'],
                    ],
                  }
                : {
                    'fields': ['ts_code', 'name'],
                    'items': [
                      ['S1.SH', '测试一'],
                      ['S2.SZ', '测试二'],
                    ],
                  },
          })),
          200,
        );
      }),
    );
    final eastmoney = EastmoneyClient(
      http: MockClient((req) async => http.Response.bytes(
          utf8.encode(jsonEncode({
            'data': {
              'klines': ['2026-10-05,10.0,10.5,10.6,10.0,920,920000.00'],
            },
          })),
          200)),
    );
    final sina = SinaClient(
      http: MockClient((req) async =>
          http.Response.bytes(utf8.encode(jsonEncode({'day': []})), 200)),
    );

    final r = await runBackfillSync(
      dbPath: dbPath,
      token: 'tok',
      fromDate: '20261005',
      now: () => DateTime(2026, 10, 5, 18),
      clientFactory: (_) => tushare,
      eastmoneyFactory: () => eastmoney,
      sinaFactory: () => sina,
      rateDelay: Duration.zero,
    );

    expect(r.rows, 2, reason: '两只股票的 20261005 都该由东财备源补上');
    final repo = BarRepository(dbPath);
    expect(repo.rowCountOnDate('20261005'), 2);
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

