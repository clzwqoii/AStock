import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/models.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/tushare_client.dart';

DailyRow row(String ts, String date, {double close = 10.0}) => DailyRow(
      tsCode: ts,
      tradeDate: date,
      open: close,
      high: close,
      low: close,
      close: close,
      vol: 100.0,
      amount: 50.0,
    );

void main() {
  late Directory tmp;
  late BarRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('stockdb');
    repo = BarRepository('${tmp.path}/test.db');
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  test('同主键重复写入是更新不是重复', () {
    repo.upsertBars([row('600000.SH', '20260930', close: 10.0)]);
    repo.upsertBars([row('600000.SH', '20260930', close: 11.0)]);
    final stocks = repo.loadAllStocks();
    expect(stocks.single.bars, hasLength(1));
    expect(stocks.single.bars.single.close, 11.0);
  });

  test('poolFingerprint：新交易日、回补旧日期、同主键替换都会改变指纹', () {
    expect(repo.poolFingerprint(), isNotNull, reason: '空库也要返回稳定的指纹');
    repo.upsertBars([row('600000.SH', '20260930')]);
    final afterSeed = repo.poolFingerprint();
    repo.upsertBars([row('600000.SH', '20261009')]);
    expect(repo.poolFingerprint(), isNot(afterSeed), reason: '水位线推进要变');

    final afterNew = repo.poolFingerprint();
    repo.upsertBars([row('600000.SH', '20260901')], ); // 回补更早历史：水位不变
    expect(repo.poolFingerprint(), isNot(afterNew), reason: '回补不改水位但改内容，指纹必须变');

    final afterBackfill = repo.poolFingerprint();
    repo.upsertBars([row('600000.SH', '20260901', close: 12.0)]); // INSERT OR REPLACE
    expect(repo.poolFingerprint(), isNot(afterBackfill), reason: '替换写入也要被感知');
  });

  test('poolFingerprintExt：含 maxDate/maxRowid/count 三字段，与 poolFingerprint 字符串同源', () {
    // 空库：maxDate 为 null（空字符串也行）、maxRowid/count 为 0。
    var ext = repo.poolFingerprintExt();
    expect(ext.maxDate, isNull);
    expect(ext.maxRowid, 0);
    expect(ext.count, 0);

    repo.upsertBars([
      row('600000.SH', '20260928'),
      row('600000.SH', '20260929'),
      row('000001.SZ', '20260930'),
    ]);
    ext = repo.poolFingerprintExt();
    expect(ext.maxDate, '20260930');
    expect(ext.maxRowid, greaterThan(0));
    expect(ext.count, 3);

    // 与字符串指纹同源：maxDate|maxRowid 必须一一对应。
    expect(repo.poolFingerprint(), '${ext.maxDate}|${ext.maxRowid}');
  });

  test('barCountUpTo：纯追加不变，REPLACE 旧行或删除旧行会减少（增量失效判据）', () {
    repo.upsertBars([
      row('600000.SH', '20260928'),
      row('600000.SH', '20260929'),
      row('000001.SZ', '20260930'),
    ]);
    final wm = repo.poolFingerprintExt().maxRowid;
    expect(repo.barCountUpTo(wm), 3);

    // 纯追加：新行 rowid > 水位，水位下行数不变
    repo.upsertBars([row('600000.SH', '20260930')]);
    expect(repo.barCountUpTo(wm), 3);

    // INSERT OR REPLACE 旧行：旧行 rowid 消失、新行拿更大 rowid → 计数减少
    repo.upsertBars([row('600000.SH', '20260928', close: 99.0)]);
    expect(repo.barCountUpTo(wm), 2);

    // 删除旧行：同理
    final raw = sqlite3.open('${tmp.path}/test.db');
    raw.execute("DELETE FROM daily_bars WHERE ts_code='000001.SZ'");
    raw.dispose();
    expect(repo.barCountUpTo(wm), 1);
  });

  test('barsSince：返回 trade_date > 参数 的行，按代码分组升序，带 rowid 范围与计数', () {
    // 空库 → 空结果
    var delta = repo.barsSince('20260101');
    expect(delta.byCode, isEmpty);
    expect(delta.minRowid, 0);
    expect(delta.maxRowid, 0);
    expect(delta.rowCount, 0);

    repo.upsertBars([
      row('600000.SH', '20260928'),
      row('600000.SH', '20260929'),
      row('000001.SZ', '20260930'),
      row('600000.SH', '20261005'), // 水位前进追加
      row('000001.SZ', '20261005'),
    ]);

    // 取水位 20260930 之后：返回 2 行（20261005 × 2 只）
    delta = repo.barsSince('20260930');
    expect(delta.byCode.length, 2);
    expect(delta.byCode['600000.SH']!.single.date, DateTime(2026, 10, 5));
    expect(delta.byCode['000001.SZ']!.single.date, DateTime(2026, 10, 5));
    expect(delta.rowCount, 2);
    expect(delta.maxRowid, greaterThan(0));
    expect(delta.minRowid, greaterThan(0));
    expect(delta.maxRowid, greaterThanOrEqualTo(delta.minRowid));

    // 越界：参数 > 水位 → 空结果（但 maxRowid 仍是当前库最大 rowid 用于比对）
    delta = repo.barsSince('20261009');
    expect(delta.byCode, isEmpty);
    expect(delta.rowCount, 0);
  });

  test('stockNames 读取股票名单', () {
    expect(repo.stockNames(), isEmpty);
    repo.upsertStocks([(tsCode: '000001.SZ', name: '平安银行')]);
    expect(repo.stockNames()['000001.SZ'], '平安银行');
  });

  test('stockName 单只查询：命中返回名称，未命中返回 null', () {
    repo.upsertStocks([(tsCode: '000001.SZ', name: '平安银行')]);
    expect(repo.stockName('000001.SZ'), '平安银行');
    expect(repo.stockName('999999.SZ'), isNull);
  });

  test('数据库启用 WAL 模式（允许同步写入与选股读取并发）', () {
    final db2 = sqlite3.open('${tmp.path}/test.db');
    try {
      expect(db2.select('PRAGMA journal_mode').first.values[0], 'wal');
    } finally {
      db2.dispose();
    }
  });

  test('maxTradeDate 的 MAX 查询点名 trade_date 专用索引', () {
    // 主键 (ts_code, trade_date) 的第二列取 MAX：无专用索引时 SQLite 走
    // 主键覆盖索引整体扫描（360 万行实测 ~80ms/次），建索引后为端点查找 ~5ms。
    // 实测基准（2026-10-06，360 万行合成表）：80ms → 5ms，索引磁盘 ~58MB。
    repo.upsertBars([row('000001.SZ', '20260930')]);
    final db2 = sqlite3.open('${tmp.path}/test.db');
    try {
      final plan = db2
          .select('EXPLAIN QUERY PLAN SELECT MAX(trade_date) FROM daily_bars')
          .map((r) => r['detail'] as String)
          .join(' | ');
      expect(plan, contains('idx_daily_bars_trade_date'), reason: '查询计划：$plan');
    } finally {
      db2.dispose();
    }
  });

  test('maxTradeDate 取最大交易日，空库为 null', () {
    expect(repo.maxTradeDate(), isNull);
    repo.upsertBars([row('000001.SZ', '20260929'), row('000001.SZ', '20260930')]);
    expect(repo.maxTradeDate(), '20260930');
    expect(repo.barCount(), 2);
  });

  test('historyCoverage：空库返回空覆盖，有数据返回正确起止日期与交易日数', () {
    final emptyCov = repo.historyCoverage();
    expect(emptyCov.isEmpty, isTrue);
    expect(emptyCov.minDate, isNull);
    expect(emptyCov.maxDate, isNull);
    expect(emptyCov.tradeDays, 0);
    expect(emptyCov.totalBars, 0);
    expect(emptyCov.isYearsCovered(1, DateTime(2026, 10, 7)), isFalse);

    repo.upsertBars([
      row('000001.SZ', '20231001'),
      row('600000.SH', '20231001'),
      row('000001.SZ', '20261007'),
    ]);

    final cov = repo.historyCoverage();
    expect(cov.isEmpty, isFalse);
    expect(cov.minDate, '20231001');
    expect(cov.maxDate, '20261007');
    expect(cov.tradeDays, 2);
    expect(cov.totalBars, 3);
  });

  test('isYearsCovered：断更库或交易日数不足时返回 false，足量且最新时返回 true', () {
    final now = DateTime(2026, 10, 7);
    // 场景 1：断更陈旧库（maxDate 远早于当前）
    const staleCov = HistoryCoverage(
      minDate: '20200101',
      maxDate: '20220101',
      tradeDays: 500,
      totalBars: 2000000,
    );
    expect(staleCov.isYearsCovered(1, now), isFalse);
    expect(staleCov.isYearsCovered(2, now), isFalse);
    expect(staleCov.isYearsCovered(3, now), isFalse);

    // 场景 2：碎片库（交易日数远不足，如仅有 2 个交易日）
    const sparseCov = HistoryCoverage(
      minDate: '20231001',
      maxDate: '20261007',
      tradeDays: 2,
      totalBars: 3,
    );
    expect(sparseCov.isYearsCovered(1, now), isFalse);
    expect(sparseCov.isYearsCovered(2, now), isFalse);
    expect(sparseCov.isYearsCovered(3, now), isFalse);

    // 场景 3：覆盖足量且连续
    const fullCov = HistoryCoverage(
      minDate: '20231001',
      maxDate: '20261007',
      tradeDays: 728,
      totalBars: 3800000,
    );
    expect(fullCov.isYearsCovered(1, now), isTrue);
    expect(fullCov.isYearsCovered(2, now), isTrue);
    expect(fullCov.isYearsCovered(3, now), isTrue);
    expect(fullCov.isYearsCovered(4, now), isFalse);

    // 场景 4：真实节假日休市边界（如 2026-10-07 的 3 年前 2023-10-07 为国庆休市，
    // 最早开市交易日为 20231009，自然日稍晚 2 天，但交易日数 726 已完整覆盖）
    const holidayBoundaryCov = HistoryCoverage(
      minDate: '20231009',
      maxDate: '20261007',
      tradeDays: 726,
      totalBars: 3920000,
    );
    expect(holidayBoundaryCov.isYearsCovered(3, now), isTrue,
        reason: '国庆长假休市导致首个交易日比自然日晚2天，不能误判为未覆盖3年');
  });

  test('isStale：末根超过 45 天算断更，空库不算', () {
    final now = DateTime(2026, 10, 7);
    // 深且密，只有末根停在两年前
    const stopped = HistoryCoverage(
      minDate: '20200101',
      maxDate: '20240101',
      tradeDays: 900,
      totalBars: 3000000,
    );
    expect(stopped.isStale(now), isTrue);
    expect(stopped.isYearsCovered(1, now), isFalse,
        reason: '断更库不能因为"深度够"就判成已覆盖');

    const fresh = HistoryCoverage(
      minDate: '20231001',
      maxDate: '20261007',
      tradeDays: 728,
      totalBars: 3800000,
    );
    expect(fresh.isStale(now), isFalse);
    // 边界：正好 45 天（20260823）不算断更，差一天（20260822）就算
    const exactly = HistoryCoverage(
      minDate: '20231001',
      maxDate: '20260823',
      tradeDays: 700,
      totalBars: 3000000,
    );
    expect(exactly.isStale(now), isFalse);
    const oneDayMore = HistoryCoverage(
      minDate: '20231001',
      maxDate: '20260822',
      tradeDays: 700,
      totalBars: 3000000,
    );
    expect(oneDayMore.isStale(now), isTrue);

    const empty = HistoryCoverage(
      minDate: null,
      maxDate: null,
      tradeDays: 0,
      totalBars: 0,
    );
    expect(empty.isStale(now), isFalse, reason: '空库是"还没有数据"，不是"断更"');
  });

  test('minTradeDate 取最早交易日，空库为 null', () {
    expect(repo.minTradeDate(), isNull);
    repo.upsertBars([row('000001.SZ', '20260929'), row('000001.SZ', '20260930')]);
    expect(repo.minTradeDate(), '20260929');
  });

  test('rowCountOnDate 返回某交易日已入库行数，无数据为 0', () {
    repo.upsertBars([
      row('000001.SZ', '20260929'),
      row('600000.SH', '20260930'),
      row('000001.SZ', '20260930'),
    ]);
    expect(repo.rowCountOnDate('20260929'), 1);
    expect(repo.rowCountOnDate('20260930'), 2);
    expect(repo.rowCountOnDate('20261001'), 0, reason: '没入库过的日期返回 0');
  });

  test('loadAllStocks 按股票分组、按日期升序、按 minBars 过滤', () {
    repo.upsertBars([
      row('000001.SZ', '20260929'),
      row('000001.SZ', '20260930'),
      row('600000.SH', '20260930'),
    ]);
    final all = repo.loadAllStocks();
    expect(all, hasLength(2));
    final a = all.firstWhere((s) => s.symbol == '000001.SZ');
    expect(a.bars.map((b) => b.date.day).toList(), [29, 30]);
    expect(repo.loadAllStocks(minBars: 3).map((s) => s.symbol), isEmpty);
    expect(repo.loadAllStocks(minBars: 2).map((s) => s.symbol), ['000001.SZ']);
  });

  group('loadAllStocks 的 maxBars（只取尾部 N 根）', () {
    // 选股只需要末日快照，规则最长回看 MA250 + 回踩窗口 ≈ 300 根。
    // 全市场 360 万行里最近 250 个交易日只有 137 万行（38%），
    // 选股路径加载全量等于白读 62%。回测必须传 0（要全部历史）。
    test('maxBars 只保留每只股票末尾 N 根，且仍按日期升序', () {
      repo.upsertBars([
        for (var d = 1; d <= 5; d++)
          row('000001.SZ', '2026090$d'),
      ]);
      final t = repo.loadAllStocks(maxBars: 2).single;
      expect(t.bars.map((b) => b.date.day).toList(), [4, 5]);
    });

    test('历史不足 maxBars 的股票不被剔除（只截断，不丢股票）', () {
      repo.upsertBars([
        row('000001.SZ', '20260929'),
        row('000001.SZ', '20260930'),
        row('600000.SH', '20260930'),
      ]);
      // maxBars=10 > 实际 2 根，两只都应保留
      expect(repo.loadAllStocks(maxBars: 10).map((s) => s.symbol),
          containsAll(<String>['000001.SZ', '600000.SH']));
    });

    test('maxBars=0 表示不截断（回测口径，默认行为不变）', () {
      repo.upsertBars([
        for (var d = 1; d <= 5; d++) row('000001.SZ', '2026090$d'),
      ]);
      expect(repo.loadAllStocks().single.bars, hasLength(5));
      expect(repo.loadAllStocks(maxBars: 0).single.bars, hasLength(5));
    });

    test('maxBars 与 minBars 同时生效', () {
      repo.upsertBars([
        for (var d = 1; d <= 5; d++) row('000001.SZ', '2026090$d'),
      ]);
      // 截断到 3 根后不足 minBars=4 → 该股票被剔除
      expect(repo.loadAllStocks(maxBars: 3, minBars: 4).map((s) => s.symbol), isEmpty);
      expect(repo.loadAllStocks(maxBars: 3, minBars: 3).map((s) => s.symbol), ['000001.SZ']);
    });

    test('maxBars=1 时末日指标仍可算（选股只用最后一根）', () {
      repo.upsertBars([
        for (var d = 1; d <= 5; d++) row('000001.SZ', '2026090$d'),
      ]);
      final t = repo.loadAllStocks(maxBars: 1).single;
      expect(t.bars.single.date.day, 5);
    });
  });

  group('loadAllStocks 的 excludeSpecialStocks（剔除 ST / 退市 / 科创板）', () {
    // 选股口径：ST、*ST、S*ST、PT*、退市整理、以及科创板（688/689）不进选股池。
    // 名称含「退」的两类写法都在真实库里（退市XX 为主流，XX退 为退市整理期个股）。
    void seedMixed() {
      repo.upsertStocks(const [
        (tsCode: '600000.SH', name: '浦发银行'), // 正常主板
        (tsCode: '600001.SH', name: 'ST龙韵'),
        (tsCode: '600002.SH', name: '*ST美谷'),
        (tsCode: '600003.SH', name: 'S*ST前锋'),
        (tsCode: '600004.SH', name: 'PT水仙'),
        (tsCode: '600005.SH', name: '退市博天'),
        (tsCode: '600006.SH', name: '广道退'),
        (tsCode: '688001.SH', name: '华兴源创'),
        (tsCode: '689009.SH', name: '九号公司-WD'), // CDR，与科创板同门槛
      ]);
      repo.upsertBars([
        for (final ts in [
          '600000.SH', '600001.SH', '600002.SH', '600003.SH', '600004.SH',
          '600005.SH', '600006.SH', '688001.SH', '689009.SH',
        ])
          row(ts, '20260930'),
      ]);
    }

    test('开启时剔除 ST/*ST/S*ST/PT*/退市与科创板，其余原样保留', () {
      seedMixed();
      expect(repo.loadAllStocks(excludeSpecialStocks: true).map((s) => s.symbol), ['600000.SH']);
    });

    test('关闭（默认）时一只都不剔除，回测口径不受影响', () {
      seedMixed();
      expect(repo.loadAllStocks(), hasLength(9));
      expect(repo.loadAllStocks(excludeSpecialStocks: false), hasLength(9));
    });

    test('与 minBars 过滤同时生效（叠加而非互相替代）', () {
      seedMixed();
      // 只有 600000.SH 逃过过滤，但它只有 1 根 < minBars=2 → 空
      expect(repo.loadAllStocks(excludeSpecialStocks: true, minBars: 2), isEmpty);
      expect(repo.loadAllStocks(minBars: 2), isEmpty); // 都不开过滤时同样只有 1 根
      expect(repo.loadAllStocks(minBars: 1), hasLength(9));
      expect(repo.loadAllStocks(excludeSpecialStocks: true, minBars: 1), hasLength(1));
    });

    test('名单缺失（stocks 表为空）时只按代码剔科创板，不误杀其它股票', () {
      // 低积分下名单可能为空：名称类过滤无从谈起，但主板仍要能选。
      repo.upsertBars([row('600000.SH', '20260930'), row('688001.SH', '20260930')]);
      expect(repo.loadAllStocks(excludeSpecialStocks: true).map((s) => s.symbol), ['600000.SH']);
    });

    test('非标记位上的字母不误杀：XD 除权前缀与拉丁名都应保留', () {
      // 除权后 tushare/eastmoney 名称带 XD 前缀（如 XD安徽凤凰），与 ST 无关；
      // 另有 TCL智家、九号公司-WD 这类合法名字。若实现按 ST 子串搜索就会误伤。
      repo.upsertStocks(const [
        (tsCode: '600007.SH', name: 'XD安徽凤凰'),
        (tsCode: '600008.SH', name: 'TCL中环'),
        (tsCode: '600009.SH', name: '九号公司-WD'),
        (tsCode: '600010.SH', name: 'ST龙韵'),
      ]);
      repo.upsertBars([
        row('600007.SH', '20260930'),
        row('600008.SH', '20260930'),
        row('600009.SH', '20260930'),
        row('600010.SH', '20260930'),
      ]);
      expect(repo.loadAllStocks(excludeSpecialStocks: true).map((s) => s.symbol),
          ['600007.SH', '600008.SH', '600009.SH']);
    });

    test('名称含 ST 子串（非开头）也剔除——对齐 SQL GLOB *ST* 语义', () {
      // SQL 的 name GLOB '*ST*' 是子串匹配，不是前缀。
      // 过滤口径逐字保留：改造到 Dart 侧也必须用 contains('ST')。
      repo.upsertStocks(const [
        (tsCode: '600000.SH', name: '浦发银行'),
        (tsCode: '600001.SH', name: 'BEST集团'), // 含 ST 子串，非 ST 标记
      ]);
      repo.upsertBars([
        row('600000.SH', '20260930'),
        row('600001.SH', '20260930'),
      ]);
      expect(repo.loadAllStocks(excludeSpecialStocks: true).map((s) => s.symbol),
          ['600000.SH']);
    });
  });

  group('loadAllStocks 的逐行游标实现', () {
    // 实现从 `_db.select`（一次性物化 ResultSet）换成 `prepare().selectCursor()`
    // 流式读：全市场实测峰值 RSS 1889MB → 648MB、5.82s → 4.68s，数据逐位一致。
    // 这里锁住游标路径特有的两件事——跨股票分组的顺序、以及语句被正确释放。
    test('多股票多日：按代码分组、组内日期升序、组间按首次出现顺序', () {
      repo.upsertBars([
        // 故意乱序写入：游标依赖 ORDER BY 而非插入顺序
        row('600000.SH', '20260930'),
        row('000001.SZ', '20260930'),
        row('600000.SH', '20260929'),
        row('000001.SZ', '20260929'),
      ]);
      final all = repo.loadAllStocks();
      expect(all.map((s) => s.symbol).toList(), ['000001.SZ', '600000.SH']);
      for (final s in all) {
        expect(s.bars.map((b) => b.date.day).toList(), [29, 30]);
      }
    });

    test('连续多次调用结果一致（游标语句已释放，不残留/不丢行）', () {
      repo.upsertBars([
        for (var d = 1; d <= 5; d++) row('000001.SZ', '2026090$d'),
        for (var d = 1; d <= 3; d++) row('600000.SH', '2026090$d'),
      ]);
      String shape(List<StockData> xs) => xs
          .map((s) => '${s.symbol}:${s.bars.map((b) => b.date.day).join(",")}')
          .join('|');
      final first = shape(repo.loadAllStocks());
      expect(shape(repo.loadAllStocks()), first);
      // minBars 过滤在重复调用下仍然生效（600000.SH 只有 3 根，被剔除）
      expect(shape(repo.loadAllStocks(minBars: 4)), '000001.SZ:1,2,3,4,5');
      // 释放后仍能正常读别的表，说明语句没有把连接占住
      expect(repo.stockNames(), isEmpty);
    });
  });

  group('trade_date 解析与 DateTime.parse 完全等价', () {
    // parseTradeDate 是手写切片（比 DateTime.parse 快约 10 倍，全市场 360 万行
    // 实测 0.2s vs 3.1s）。oracle 取 DateTime.parse 本身，实现换写法时不得漂移。
    // 覆盖闰年 2/29、世纪闰年、各月边界，以及越界月日的进位行为。
    const samples = [
      '20240101', '20240229', '20000229', '19000229', '21001231', '19991231',
      '20260930', '20250101', '20240228', '20240301', '20260430', '20260431',
      '19700101', '20991231', '20240615', '20241130', '20240230', '20230229',
      '20231301', '20230001', '20230100', '20240032',
    ];
    test('逐位等价（含越界月日进位）', () {
      for (final s in samples) {
        expect(parseTradeDate(s), DateTime.parse(s), reason: s);
      }
    });

    test('非 8 位抛 FormatException（不是静默接受）', () {
      expect(() => parseTradeDate('2024-01-05'), throwsFormatException);
      expect(() => parseTradeDate('202401'), throwsFormatException);
      expect(() => parseTradeDate('2024010a'), throwsFormatException);
    });

    test('8 位但含非数字也抛 FormatException', () {
      expect(() => parseTradeDate('2024AB01'), throwsFormatException);
      expect(() => parseTradeDate('        '), throwsFormatException);
    });
  });

  test('trade_date 按本地日期全字段还原（loadAllStocks 与 barsFor 同口径）', () {
    // 锁定 YYYYMMDD → 年/月/日的完整还原；解析实现改写时防行为漂移
    repo.upsertBars([row('000001.SZ', '20240105')]);
    final expected = DateTime(2024, 1, 5);
    expect(repo.loadAllStocks().single.bars.single.date, expected);
    expect(repo.barsFor('000001.SZ').single.date, expected);
  });

  test('loadAllStocks 跨股票共享同一交易日的 DateTime 实例（内存复用）', () {
    repo.upsertBars([
      row('000001.SZ', '20260930'),
      row('600000.SH', '20260930'),
    ]);
    final stocks = repo.loadAllStocks();
    expect(stocks, hasLength(2));
    final date1 = stocks.firstWhere((s) => s.symbol == '000001.SZ').bars.single.date;
    final date2 = stocks.firstWhere((s) => s.symbol == '600000.SH').bars.single.date;
    expect(identical(date1, date2), isTrue);
  });

  group('loadStocksRange（主键范围分片扫描）', () {
    test('分片并集 == loadAllStocks，边界不重不漏', () {
      // 5 只股票各 3 根：按 ts_code 升序排列
      const codes = [
        '000001.SZ', '000002.SZ', '000003.SZ', '600000.SH', '600001.SH',
      ];
      const dates = ['20260901', '20260902', '20260903'];
      for (final code in codes) {
        repo.upsertBars([
          for (final d in dates) row(code, d),
        ]);
      }

      final all = repo.loadAllStocks();
      expect(all.map((s) => s.symbol).toList(), codes);

      // 连续分片：[000001, 000002), [000002, 600000), [600000, null)
      final shard0 = repo.loadStocksRange('000001.SZ', toCode: '000002.SZ');
      final shard1 = repo.loadStocksRange('000002.SZ', toCode: '600000.SH');
      final shard2 = repo.loadStocksRange('600000.SH');

      expect(shard0.map((s) => s.symbol).toList(), ['000001.SZ']);
      expect(shard1.map((s) => s.symbol).toList(), ['000002.SZ', '000003.SZ']);
      expect(shard2.map((s) => s.symbol).toList(), ['600000.SH', '600001.SH']);

      final union = [...shard0, ...shard1, ...shard2];
      expect(union.length, all.length);
      for (var i = 0; i < all.length; i++) {
        expect(union[i].symbol, all[i].symbol, reason: 'stock $i symbol');
        expect(union[i].bars.length, all[i].bars.length,
            reason: 'stock $i bar count');
        for (var j = 0; j < all[i].bars.length; j++) {
          expect(union[i].bars[j].close, all[i].bars[j].close,
              reason: 'stock $i bar $j close');
          expect(union[i].bars[j].date, all[i].bars[j].date,
              reason: 'stock $i bar $j date');
        }
      }
    });

    test('toCode 上界为半开区间：不含 toCode 自身', () {
      repo.upsertBars([
        row('000001.SZ', '20260930'),
        row('000002.SZ', '20260930'),
        row('000003.SZ', '20260930'),
      ]);
      final shard = repo.loadStocksRange('000001.SZ', toCode: '000003.SZ');
      expect(shard.map((s) => s.symbol).toList(), ['000001.SZ', '000002.SZ']);
    });

    test('minBars 过滤在范围扫描下同样生效', () {
      repo.upsertBars([
        row('000001.SZ', '20260930'),
        row('000002.SZ', '20260929'),
        row('000002.SZ', '20260930'),
      ]);
      final shard =
          repo.loadStocksRange('000001.SZ', toCode: '000003.SZ', minBars: 2);
      expect(shard.map((s) => s.symbol).toList(), ['000002.SZ']);
    });
  });

  test('tradingCalendarFromDb 与 tradingCalendar(loadAllStocks()) 一致', () {
    // 3 只股票各 3 根，其中一只少一根（模拟停牌）
    const dates = ['20260901', '20260902', '20260903'];
    for (final code in ['000001.SZ', '000002.SZ', '600000.SH']) {
      repo.upsertBars([
        for (final d in dates) row(code, d),
      ]);
    }
    // 000003.SZ 只有 2 根（模拟 09-03 停牌）
    repo.upsertBars([row('000003.SZ', '20260901'), row('000003.SZ', '20260902')]);

    final stocks = repo.loadAllStocks();
    final expected = tradingCalendar(stocks);
    final actual = repo.tradingCalendarFromDb();
    expect(actual.length, expected.length);
    for (final d in expected) {
      expect(actual.contains(d), isTrue, reason: '$d 应在日历中');
    }
  });
}

