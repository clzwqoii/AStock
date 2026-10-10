import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/backtest_detail_store.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/bars_snapshot_store.dart';
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

  test('ScreeningService 失效重载：水位变化全量重载；报告变化只换评分不重载池（P1b）', () async {
    seedStocks(dbPath);
    // 先存一份报告（baseWin=0.8）让选股有评分基准
    ReportStore(reportPathFor(dbPath)).save(BacktestReport(
      generatedAt: DateTime.now().toIso8601String(),
      horizons: const [10],
      stockCount: 2,
      baseline: {
        10: Baseline.fromStats(forwardDays: 10, stats: const BacktestStats(
            count: 100, winRate: 0.8, avgReturn: 5, medianReturn: 5,
            bestReturn: 20, worstReturn: -10, profitFactor: 2)),
      },
      results: const {},
    ));
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    final r0 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r0.timings!.poolReused, isFalse);
    expect(r0.picked.first.score!.score, closeTo(80, 0.5),
        reason: 'baseWin=0.8, 无命中规则 → score=80');

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

    addBar('20261003'); // 新交易日 → 水位变了 → 全量重载
    final r3 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r3.timings!.poolReused, isFalse, reason: '水位线变了必须重载');

    addBar('20260801'); // 回补更早的历史：水位线不变，但库内容变了
    final r4 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r4.timings!.poolReused, isFalse, reason: '回补不改水位线，按行指纹仍要重载');

    // 报告更新（baseWin 从 0.8 → 0.3）：只换评分，不重载股票池
    ReportStore(reportPathFor(dbPath)).save(BacktestReport(
      generatedAt: DateTime.now().toIso8601String(),
      horizons: const [10],
      stockCount: 2,
      baseline: {
        10: Baseline.fromStats(forwardDays: 10, stats: const BacktestStats(
            count: 100, winRate: 0.3, avgReturn: -2, medianReturn: -2,
            bestReturn: 10, worstReturn: -20, profitFactor: 0.5)),
      },
      results: const {},
    ));
    final r5 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r5.timings!.poolReused, isTrue, reason: '报告变了不重载股票池（P1b）');
    expect(r5.timings!.loadMs, 0, reason: '池子复用，不读库');
    expect(r5.picked.first.score!.score, closeTo(30, 0.5),
        reason: '评分用上新报告：baseWin=0.3 → score=30');
  });

  // ── P1c 同步后池增量 append ──

  test('P1c 增量 append：纯追加水位前进 → 走增量路径，结果与全量逐位一致', () async {
    seedStocks(dbPath); // S1.SH, S2.SZ × 40 日（水位 20261002）
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    final r1 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r1.timings!.poolReused, isFalse);
    expect(r1.timings!.incremental, isFalse, reason: '首次必须全量');

    void addBar(String code, String date, {double close = 10.5}) {
      final r = BarRepository(dbPath);
      r.upsertBars([
        DailyRow(
            tsCode: code,
            tradeDate: date,
            open: 10.0,
            high: 10.0,
            low: 10.0,
            close: close,
            vol: 100.0,
            amount: 1),
      ]);
      r.close();
    }

    // 纯追加水位前进：两票都加 20261005
    addBar('S1.SH', '20261005', close: 11.0);
    addBar('S2.SZ', '20261005', close: 9.5);

    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.poolReused, isFalse, reason: '池内容变了，不算复用');
    expect(r2.timings!.incremental, isTrue, reason: '纯追加水位前进 → 走增量 append');
    expect(r2.timings!.loadMs, lessThan(1000), reason: '增量路径几行新数据，读库毫秒级');

    // 对照：新建 svc 走全量路径，结果逐位一致
    final svcFull = ScreeningService();
    addTearDown(svcFull.dispose);
    final rFull = await svcFull.screen(dbPath, [ruleById('pct_change_up')]);
    expect([for (final p in r2.picked) p.symbol], [for (final p in rFull.picked) p.symbol],
        reason: '增量与全量的命中代码集合必须一致');
    for (var i = 0; i < r2.picked.length; i++) {
      final a = r2.picked[i], b = rFull.picked[i];
      expect(a.close, closeTo(b.close, 1e-9));
      expect(a.change, closeTo(b.change, 1e-9));
      expect(a.changePct, closeTo(b.changePct, 1e-9));
      expect(a.volumeRatio, closeTo(b.volumeRatio, 1e-9));
      expect(a.ma20, closeTo(b.ma20, 1e-9));
      expect(a.amountWan, closeTo(b.amountWan, 1e-9));
    }
  });

  test('P1c 增量 append：新股（IPO）追加水位之后的新行 → 整体加入池', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    await svc.screen(dbPath, [ruleById('pct_change_up')]);

    // 新股 IPO：只加水位前进的新行（纯追加场景，不回补早日期）
    final r = BarRepository(dbPath);
    r.upsertBars([
      DailyRow(
          tsCode: 'NEW.SH',
          tradeDate: '20261005',
          open: 10.0,
          high: 10.6,
          low: 10.0,
          close: 10.6,
          vol: 100.0,
          amount: 1),
    ]);
    r.close();

    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.incremental, isTrue, reason: '水位前进且纯追加 → 增量');
    // 与全量路径对照
    final svcFull = ScreeningService();
    addTearDown(svcFull.dispose);
    final rFull = await svcFull.screen(dbPath, [ruleById('pct_change_up')]);
    expect([for (final p in r2.picked) p.symbol], [for (final p in rFull.picked) p.symbol]);
    expect(r2.total, rFull.total, reason: 'total = 池内股票数，新股必须算入');
  });

  test('P1c 增量 append：停牌股（无新行）末根不变', () async {
    seedStocks(dbPath); // S1、S2 都到 20261002
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    final r1 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    // 记录 S1 在第一次选股时的末根 close（来自 r1 的 close 字段）

    // 只给 S2 追加新行，S1 停牌没新行
    final r = BarRepository(dbPath);
    r.upsertBars([
      DailyRow(
          tsCode: 'S2.SZ',
          tradeDate: '20261005',
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: 10.5,
          vol: 100.0,
          amount: 1),
    ]);
    r.close();

    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.incremental, isTrue);

    // 停牌股 S1 的末根 close 不变（没新行 append）
    final s1Row1 = r1.picked.firstWhere((p) => p.symbol == 'S1.SH',
        orElse: () => throw StateError('S1 必须在两次结果中都命中'));
    final s1Row2 = r2.picked.firstWhere((p) => p.symbol == 'S1.SH',
        orElse: () => throw StateError('S1 必须在两次结果中都命中'));
    expect(s1Row2.close, closeTo(s1Row1.close, 1e-9),
        reason: 'S1 没有新行 → 末根 close 必须不变');
    expect(s1Row2.signalDate, s1Row1.signalDate, reason: 'S1 末根日期不变');

    // 对照全量
    final svcFull = ScreeningService();
    addTearDown(svcFull.dispose);
    final rFull = await svcFull.screen(dbPath, [ruleById('pct_change_up')]);
    expect([for (final p in r2.picked) p.symbol], [for (final p in rFull.picked) p.symbol]);
  });

  test('P1c 增量 append：REPLACE 旧行（非纯追加）→ 退回全量重载', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    await svc.screen(dbPath, [ruleById('pct_change_up')]);

    // 追加新行 + 同时 REPLACE 旧行（同主键换值）
    final r = BarRepository(dbPath);
    r.upsertBars([
      DailyRow(
          tsCode: 'S1.SH',
          tradeDate: '20261005', // 新日（水位前进）
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: 11.0,
          vol: 100.0,
          amount: 1),
      DailyRow(
          tsCode: 'S1.SH',
          tradeDate: '20260930', // 旧行 REPLACE（同主键换 close）
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: 99.0,
          vol: 100.0,
          amount: 1),
    ]);
    r.close();

    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.incremental, isFalse, reason: 'REPLACE 旧行 → count 不变 → 退回全量');
    expect(r2.timings!.poolReused, isFalse);

    // 与全量路径逐位一致（确保退回全量后结果正确）
    final svcFull = ScreeningService();
    addTearDown(svcFull.dispose);
    final rFull = await svcFull.screen(dbPath, [ruleById('pct_change_up')]);
    expect([for (final p in r2.picked) p.symbol], [for (final p in rFull.picked) p.symbol]);
  });

  test('P1c 增量 append：水位后退（回补更早历史）→ 全量重载', () async {
    seedStocks(dbPath);
    final svc = ScreeningService();
    addTearDown(svc.dispose);
    await svc.screen(dbPath, [ruleById('pct_change_up')]);

    // 回补更早历史：水位不变但库内容变了（旧行被加进更早日期）
    final r = BarRepository(dbPath);
    r.upsertBars([
      DailyRow(
          tsCode: 'S1.SH',
          tradeDate: '20260701', // 早于水位
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: 10.0,
          vol: 100.0,
          amount: 1),
    ]);
    r.close();

    final r2 = await svc.screen(dbPath, [ruleById('pct_change_up')]);
    expect(r2.timings!.incremental, isFalse, reason: '水位没前进 → 不走增量');
    expect(r2.timings!.poolReused, isFalse);
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

  test('runBacktest 同路径并发去重:复用同一 Future(避免自动+手动双跑)', () async {
    seedStocks(dbPath);
    final rp = '${tmp.path}/report.json';
    // 并发两次同路径:第二次应复用第一次的 in-flight Future
    final f1 = runBacktest(dbPath, reportPath: rp);
    final f2 = runBacktest(dbPath, reportPath: rp);
    expect(f2, same(f1), reason: '同路径进行中的 runBacktest 必须复用同一 Future');
    final r1 = await f1;
    final r2 = await f2;
    expect(r2, same(r1));
  });

  test('runBacktest 不同路径不去重', () async {
    seedStocks(dbPath);
    // 不同 dbPath 避免两 isolate 同时开同一库设 WAL 的 lock；
    // 不同子目录避免 historyPathFor 解析到同一台账文件并发写冲突。
    final dbPath2 = '${tmp.path}/t2.db';
    seedStocks(dbPath2);
    final sub1 = Directory('${tmp.path}/sub1')..createSync();
    final sub2 = Directory('${tmp.path}/sub2')..createSync();
    final rp1 = '${sub1.path}/r.json';
    final rp2 = '${sub2.path}/r.json';
    final f1 = runBacktest(dbPath, reportPath: rp1);
    final f2 = runBacktest(dbPath2, reportPath: rp2);
    expect(f2, isNot(same(f1)), reason: '不同路径应各自独立回测');
    await Future.wait([f1, f2]);
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

  // ── P3 增量回测编排 ──────────────────────────────────────────────
  // 520 只（≥500 触发并行分片路径），40 根里第 16 根 +10%（信号日 t=15）。
  // maxH=20 → 全量可评 t∈[20,19] 中的 t=15 一类信号日；追加 1 日后
  // lastEval=20，每股恰好补评 1 个信号日，maxH 的前瞻窗口恰好贴边。
  final p3Base = DateTime(2026, 8, 10);
  String p3Date(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  String p3Code(int s) => '6${s.toString().padLeft(5, '0')}.SH';

  void seedP3(String dbPath, {int count = 520, int days = 40}) {
    final repo = BarRepository(dbPath);
    final rows = <DailyRow>[];
    for (var s = 0; s < count; s++) {
      for (var i = 0; i < days; i++) {
        final close = i == 15 ? 11.0 : 10.0;
        rows.add(DailyRow(
          tsCode: p3Code(s),
          tradeDate: p3Date(p3Base.add(Duration(days: i))),
          open: close,
          high: close,
          low: close,
          close: close,
          vol: 100,
          amount: 1,
        ));
      }
    }
    repo.upsertBars(rows);
    repo.close();
  }

  /// 与 app_logic 的 `_backtestFingerprint` 同构——组合一变这里就该红，
  /// 否则旧缓存会被新口径静默复用。
  String p3Fingerprint() => [
        'bkdv1',
        for (final r in builtInRules) r.id,
        ...kDefaultHorizons,
        kRecentWindowTradingDays,
        kCorporateActionLookbackBars,
        kSuspensionLookbackBars,
      ].join('|');

  void expectStatsNear(
      BacktestStats a, BacktestStats b, String what, bool exact) {
    expect(a.count, b.count, reason: '$what count');
    expect(a.winRate, b.winRate, reason: '$what winRate');
    expect(a.medianReturn, b.medianReturn, reason: '$what medianReturn');
    expect(a.bestReturn, b.bestReturn, reason: '$what bestReturn');
    expect(a.worstReturn, b.worstReturn, reason: '$what worstReturn');
    expect(a.p10, b.p10, reason: '$what p10');
    expect(a.p25, b.p25, reason: '$what p25');
    expect(a.p75, b.p75, reason: '$what p75');
    expect(a.p90, b.p90, reason: '$what p90');
    if (exact) {
      expect(a.avgReturn, b.avgReturn, reason: '$what avgReturn');
      expect(a.profitFactor, b.profitFactor, reason: '$what profitFactor');
      expect(a.stdDev, b.stdDev, reason: '$what stdDev');
    } else {
      expect(a.avgReturn, closeTo(b.avgReturn, 1e-9), reason: '$what avgReturn');
      expect(a.profitFactor, closeTo(b.profitFactor, 1e-9),
          reason: '$what profitFactor');
      expect(a.stdDev, b.stdDev == null ? isNull : closeTo(b.stdDev!, 1e-9),
          reason: '$what stdDev');
    }
  }

  void expectSameReports(BacktestReport a, BacktestReport b,
      {bool recentExact = true}) {
    for (final h in b.horizons) {
      expectStatsNear(a.baseline[h]!.stats, b.baseline[h]!.stats,
          'baseline h=$h', false);
    }
    for (final id in b.results.keys) {
      for (final h in b.horizons) {
        expectStatsNear(a.results[id]![h]!.stats, b.results[id]![h]!.stats,
            'results $id h=$h', false);
      }
    }
    for (final y in b.yearly.keys) {
      for (final id in b.yearly[y]!.keys) {
        for (final h in b.horizons) {
          final x = a.yearly[y]![id]![h]!, w = b.yearly[y]![id]![h]!;
          expect(x.count, w.count, reason: 'yearly $y $id h=$h count');
          expect(x.avgReturn, w.avgReturn, reason: 'yearly $y $id h=$h avg');
        }
      }
    }
    for (final y in b.yearlyBaseline.keys) {
      for (final h in b.horizons) {
        expect(a.yearlyBaseline[y]![h]!.count, b.yearlyBaseline[y]![h]!.count,
            reason: 'yearlyBaseline $y h=$h count');
      }
    }
    for (final id in b.signalProfile.keys) {
      for (final h in b.horizons) {
        final x = a.signalProfile[id]![h]!, w = b.signalProfile[id]![h]!;
        expect(x.signalCount, w.signalCount, reason: 'profile $id h=$h');
        expect(x.monthsWithSignals, w.monthsWithSignals, reason: 'profile $id h=$h');
        expect(x.topMonthShare, w.topMonthShare, reason: 'profile $id h=$h');
      }
    }
    for (final id in b.recent.keys) {
      for (final h in b.horizons) {
        expectStatsNear(a.recent[id]![h]!.stats, b.recent[id]![h]!.stats,
            'recent $id h=$h', recentExact);
        expect(a.recent[id]![h]!.dayMeanReturn, b.recent[id]![h]!.dayMeanReturn,
            reason: 'recent $id h=$h dayMeans');
      }
    }
    for (final h in b.horizons) {
      expectStatsNear(a.recentBaseline[h]!.stats, b.recentBaseline[h]!.stats,
          'recentBaseline h=$h', recentExact);
      expect(a.recentBaseline[h]!.dayMeanReturn,
          b.recentBaseline[h]!.dayMeanReturn,
          reason: 'recentBaseline h=$h dayMeans');
    }
    expect(a.marketState!.regime, b.marketState!.regime);
    expect(a.marketState!.stockCount, b.marketState!.stockCount);
    expect(a.marketState!.asOfDate, b.marketState!.asOfDate);
    expect(a.marketState!.maGap, b.marketState!.maGap);
    expect(a.marketState!.ret20, b.marketState!.ret20);
    expect(a.marketState!.breadthAboveMa20, b.marketState!.breadthAboveMa20);
    expect(a.marketState!.newHighLowDiff20, b.marketState!.newHighLowDiff20);
  }

  test('P3 增量回测：全量→缓存→追加K线→增量，与删缓存后的全量重跑一致', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await runBacktest(dbPath, reportPath: rp); // 全量（并行分片路径）
    final detailPath = backtestDetailPathFor(dbPath);
    expect(File(detailPath).existsSync(), isTrue, reason: '全量后应写明细缓存');

    // 追加 1 个交易日：每 5 只停 1 只（416 只追加、104 只停牌）
    final suspended = {for (var s = 0; s < 520; s += 5) s};
    final repo = BarRepository(dbPath);
    final day = p3Date(p3Base.add(const Duration(days: 40)));
    repo.upsertBars([
      for (var s = 0; s < 520; s++)
        if (!suspended.contains(s))
          DailyRow(
            tsCode: p3Code(s),
            tradeDate: day,
            open: 11,
            high: 11,
            low: 11,
            close: 11,
            vol: 100,
            amount: 1,
          ),
    ]);
    repo.close();

    final r2 = await runBacktest(dbPath, reportPath: rp); // 增量续扫

    // 缓存头滚到新水位；指纹与 App 侧一致（否则下次永远退全量）
    final cached = loadBacktestDetail(detailPath, fingerprint: p3Fingerprint())!;
    expect(cached.rowCount, 520 * 40 + (520 - suspended.length));
    expect(cached.detail.stockLens[p3Code(0)], 40, reason: '停牌股长度不变');
    expect(cached.detail.stockLens[p3Code(1)], 41);

    // 对照：删缓存 → 全量重跑
    File(detailPath).deleteSync();
    final r3 = await runBacktest(dbPath, reportPath: rp);
    expectSameReports(r2, r3);
  });

  test('P3 失效退全量：旧行被 INSERT OR REPLACE 后结果与全量一致', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await runBacktest(dbPath, reportPath: rp); // 全量写缓存

    // REPLACE 旧行：rowid 消失 → 水位下行数变化 → 自动退全量
    final repo = BarRepository(dbPath);
    repo.upsertBars([
      DailyRow(
        tsCode: p3Code(1),
        tradeDate: p3Date(p3Base.add(const Duration(days: 15))),
        open: 99,
        high: 99,
        low: 99,
        close: 99,
        vol: 100,
        amount: 1,
      ),
    ]);
    repo.close();

    final r2 = await runBacktest(dbPath, reportPath: rp);
    File(backtestDetailPathFor(dbPath)).deleteSync();
    final r3 = await runBacktest(dbPath, reportPath: rp);
    expectSameReports(r2, r3);
  });

  test('P3 无新数据复用磁盘报告：不重算（generatedAt 哨兵原样返回）', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await runBacktest(dbPath, reportPath: rp); // 全量：写报告 + detail 缓存

    // 把报告改成哨兵值：走重算路径 generatedAt 会是当前时间，
    // 只有复用磁盘报告才会把哨兵原样带出来。
    final f = File(rp);
    final sentinel = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    sentinel['generatedAt'] = '2000-01-01T00:00:00.000Z';
    f.writeAsStringSync(jsonEncode(sentinel));

    final r2 = await runBacktest(dbPath, reportPath: rp);
    expect(r2.generatedAt, '2000-01-01T00:00:00.000Z',
        reason: 'daily_bars 逐位未变 → 报告是同一数据的纯重算，直接复用');

    // detail 缓存原样保留（下一次数据前进时的增量锚点）
    final cached = loadBacktestDetail(
        backtestDetailPathFor(dbPath), fingerprint: p3Fingerprint());
    expect(cached, isNotNull);
  });

  test('P3 复用兜底：报告文件缺失时照常重算并恢复报告', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await runBacktest(dbPath, reportPath: rp);
    File(rp).deleteSync();

    final r2 = await runBacktest(dbPath, reportPath: rp);
    expect(File(rp).existsSync(), isTrue, reason: '重算后报告恢复落盘');
    expect(r2.stockCount, 520);
  });

  test('P5 runSync 后重建快照：水位与库一致', () async {
    final client = fakeSyncClient((td) {
      return [['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0]];
    });
    await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 9, 30, 18),
      clientFactory: (_) => client,
    );

    final snapPath = barsSnapshotPathFor(dbPath);
    final snap = loadBarsSnapshot(snapPath);
    expect(snap, isNotNull, reason: '同步完成后应重建快照');
    final repo = BarRepository(dbPath);
    final wm = repo.poolFingerprintExt();
    repo.close();
    expect(snap!.maxRowid, wm.maxRowid, reason: '快照水位 = 库 MAX(rowid)');
    expect(snap.rowCount, wm.count);
  });

  test('P5 快照回测与 SQL 回测一致：有快照跑一遍，删快照+删缓存再跑一遍', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await rebuildBarsSnapshot(dbPath); // 模拟同步后的快照重建
    final r1 = await runBacktest(dbPath, reportPath: rp); // worker 走快照路径

    final detailPath = backtestDetailPathFor(dbPath);
    if (File(detailPath).existsSync()) File(detailPath).deleteSync();
    File(barsSnapshotPathFor(dbPath)).deleteSync();
    final r2 = await runBacktest(dbPath, reportPath: rp); // worker 退 SQL 路径

    expect(r1.stockCount, 520);
    expect(r2.stockCount, 520);
    expectSameReports(r1, r2);
  });

  test('P5 过期快照自动回退：快照落后于库时结果与全量 SQL 一致', () async {
    seedP3(dbPath);
    final rp = '${tmp.path}/r.json';
    await rebuildBarsSnapshot(dbPath);
    await runBacktest(dbPath, reportPath: rp);

    // 追加 1 个交易日：快照落后于库（库里多了 rowid > snap.maxRowid 的行），
    // worker 必须拒绝这份快照，否则会丢掉新数据
    final repo = BarRepository(dbPath);
    final day = p3Date(p3Base.add(const Duration(days: 40)));
    repo.upsertBars([
      for (var s = 0; s < 520; s++)
        DailyRow(
          tsCode: p3Code(s),
          tradeDate: day,
          open: 11,
          high: 11,
          low: 11,
          close: 11,
          vol: 100,
          amount: 1,
        ),
    ]);
    repo.close();

    final r2 = await runBacktest(dbPath, reportPath: rp); // 增量续扫，走 SQL
    expect(r2.stockCount, 520);

    final detailPath = backtestDetailPathFor(dbPath);
    if (File(detailPath).existsSync()) File(detailPath).deleteSync();
    File(barsSnapshotPathFor(dbPath)).deleteSync();
    final r3 = await runBacktest(dbPath, reportPath: rp); // 全量 SQL 兜底对照
    expectSameReports(r2, r3);
  });

  test('A 选股池优先走快照：新鲜取快照、过期回退 null，口径与 SQL 逐位一致', () async {
    seedStocks(dbPath);
    String d(int i) => '2026${(1 + i ~/ 28).toString().padLeft(2, '0')}'
        '${(1 + i % 28).toString().padLeft(2, '0')}';
    // 补一只科创板（68 开头）与一只名称含 ST 的票：扣口径与 SQL 逐字一致
    final repo0 = BarRepository(dbPath);
    repo0.upsertStocks([
      (tsCode: 'S1.SH', name: '正常股'),
      (tsCode: 'S2.SZ', name: '*ST 风险'),
      (tsCode: '688001.SH', name: '科创股'),
    ]);
    repo0.upsertBars([
      for (var i = 0; i < 40; i++)
        DailyRow(
          tsCode: '688001.SH',
          tradeDate: d(i),
          open: 10,
          high: 10,
          low: 10,
          close: 10,
          vol: 100,
          amount: 1,
        ),
    ]);
    repo0.close();

    final repo = BarRepository(dbPath);
    expect(loadPoolFromSnapshot(repo, dbPath, excludeSpecialStocks: true), isNull,
        reason: '无快照时必须返回 null（回退 SQL）');

    final wm = repo.poolFingerprintExt();
    writeBarsSnapshot(barsSnapshotPathFor(dbPath), repo.loadAllStocks(),
        maxRowid: wm.maxRowid, rowCount: wm.count);

    final fromSnap =
        loadPoolFromSnapshot(repo, dbPath, excludeSpecialStocks: true);
    expect(fromSnap, isNotNull, reason: '新鲜快照必须命中');
    final fromSql = repo.loadAllStocks(excludeSpecialStocks: true);
    expect(fromSnap!.length, fromSql.length, reason: '扣口径一致（ST/科创板剔除）');
    for (var s = 0; s < fromSql.length; s++) {
      expect(fromSnap[s].symbol, fromSql[s].symbol);
      expect(fromSnap[s].bars.length, fromSql[s].bars.length);
      for (var i = 0; i < fromSql[s].bars.length; i++) {
        final a = fromSnap[s].bars[i], b = fromSql[s].bars[i];
        expect(a.date, b.date);
        expect(a.open, b.open);
        expect(a.high, b.high);
        expect(a.low, b.low);
        expect(a.close, b.close);
        expect(a.volume, b.volume);
        expect(a.amount, b.amount);
      }
    }
    expect(fromSnap.map((e) => e.symbol), isNot(contains('688001.SH')));
    expect(fromSnap.map((e) => e.symbol), isNot(contains('S2.SZ')));

    // 追加 1 行（未重建快照）→ 水位不符，必须回退
    repo.upsertBars([
      DailyRow(
        tsCode: 'S1.SH',
        tradeDate: '20261003',
        open: 10,
        high: 10,
        low: 10,
        close: 10,
        vol: 100,
        amount: 1,
      ),
    ]);
    expect(loadPoolFromSnapshot(repo, dbPath, excludeSpecialStocks: true), isNull,
        reason: '快照落后于库时必须拒绝');
    repo.close();
  });

  test('A 选股有快照与无快照结果一致（runScreening 端到端）', () async {
    seedStocks(dbPath);
    await rebuildBarsSnapshot(dbPath);
    final withSnap =
        await runScreening(dbPath, [ruleById('volume_surge'), ruleById('pct_change_up')]);
    File(barsSnapshotPathFor(dbPath)).deleteSync();
    final withoutSnap =
        await runScreening(dbPath, [ruleById('volume_surge'), ruleById('pct_change_up')]);
    expect(withSnap.total, withoutSnap.total);
    expect(withSnap.picked.map((e) => e.symbol),
        withoutSnap.picked.map((e) => e.symbol));
    expect(withSnap.dataDate, withoutSnap.dataDate);
  });

  test('C 同一收盘边界内重复启动同步早退：不再发网络请求，跨边界必须真同步', () async {
    seedStocks(dbPath);
    var clients = 0;
    final client = fakeSyncClient((td) => [
          ['S1.SH', td, 1.0, 1.0, 1.0, 1.0, 100.0, 10.0],
        ]);
    // 首次：2026-09-30（周三）18:00，收盘后正常同步并记录检查时刻
    await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 9, 30, 18),
      clientFactory: (_) {
        clients++;
        return client;
      },
    );
    expect(clients, 1, reason: '首次必须真同步');

    // 同一收盘边界内（当天 20:00）再启动：必须早退，连客户端都不创建
    final r2 = await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 9, 30, 20),
      clientFactory: (_) => throw StateError('早退时不得创建客户端'),
    );
    expect(r2.dates, 0);
    expect(r2.rows, 0);
    expect(r2.latestDate, isNotNull, reason: '早退仍要回执库内水位');

    // 越过新的收盘边界（次日 18:00）→ 必须正常同步，不得早退
    await runSync(
      dbPath: dbPath,
      token: 'tok',
      now: () => DateTime(2026, 10, 1, 18),
      clientFactory: (_) {
        clients++;
        return client;
      },
    );
    expect(clients, 2, reason: '新收盘边界后必须真同步');
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

