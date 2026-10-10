import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/models.dart';
import 'package:stock/data/bars_snapshot_store.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/tushare_client.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('barssnap');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  StockData stock(String symbol, String ymd, int n) => StockData(
        symbol: symbol,
        bars: [
          for (var i = 0; i < n; i++)
            Bar(
              date: DateTime.parse(
                  '${ymd.substring(0, 4)}-${ymd.substring(4, 6)}-${ymd.substring(6, 8)}')
                  .add(Duration(days: i)),
              open: 10 + i * 0.1,
              high: 10.5 + i * 0.1,
              low: 9.5 + i * 0.1,
              close: 10.2 + i * 0.1,
              volume: 100.0 + i,
              amount: 1000.0 + i,
            ),
        ],
      );

  test('roundtrip：写 → 读 → 范围重建与原始 StockData 逐位一致', () async {
    final stocks = [
      stock('000001.SZ', '20260101', 30),
      stock('600000.SH', '20260101', 25),
      stock('600519.SH', '20260101', 40),
    ];
    final path = barsSnapshotPathFor('${tmp.path}/t.db');
    writeBarsSnapshot(path, stocks, maxRowid: 95, rowCount: 95);

    final snap = loadBarsSnapshot(path)!;
    expect(snap.maxRowid, 95);
    expect(snap.rowCount, 95);
    expect(snap.symbols, ['000001.SZ', '600000.SH', '600519.SH']);

    // 全范围重建：逐字段逐位一致
    final rebuilt = stocksFromSnapshot(snap, '000001.SZ');
    expect(rebuilt.length, 3);
    for (var s = 0; s < 3; s++) {
      expect(rebuilt[s].symbol, stocks[s].symbol);
      expect(rebuilt[s].bars.length, stocks[s].bars.length);
      for (var i = 0; i < stocks[s].bars.length; i++) {
        final a = rebuilt[s].bars[i];
        final b = stocks[s].bars[i];
        expect(a.date, b.date, reason: '${stocks[s].symbol}[$i].date');
        expect(a.open, b.open);
        expect(a.high, b.high);
        expect(a.low, b.low);
        expect(a.close, b.close);
        expect(a.volume, b.volume);
        expect(a.amount, b.amount);
      }
    }

    // 半开区间 [from, to)：与 SQL loadStocksRange 的切片语义一致
    final mid = stocksFromSnapshot(snap, '600000.SH', toCode: '600519.SH');
    expect(mid.map((s) => s.symbol), ['600000.SH']);
  });

  test('文件缺失 / 截断 / 版本不符 → loadBarsSnapshot 返回 null', () async {
    final path = barsSnapshotPathFor('${tmp.path}/t.db');
    expect(loadBarsSnapshot(path), isNull, reason: '缺失');

    final stocks = [stock('000001.SZ', '20260101', 30)];
    writeBarsSnapshot(path, stocks, maxRowid: 30, rowCount: 30);
    var bytes = File(path).readAsBytesSync();
    File(path).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    expect(loadBarsSnapshot(path), isNull, reason: '截断');

    // 篡改版本号：头 JSON 里 "v":1 → "v":9（等长字节原位改写，不动布局）
    writeBarsSnapshot(path, stocks, maxRowid: 30, rowCount: 30);
    bytes = File(path).readAsBytesSync();
    final bd = ByteData.sublistView(bytes);
    final headLen = bd.getUint32(0, Endian.little);
    final head = utf8.decode(bytes.sublist(4, 4 + headLen));
    expect(head.contains('"v":1'), isTrue, reason: '头里应有版本号');
    final patchedHead = head.replaceFirst('"v":1', '"v":9');
    bytes.setRange(4, 4 + headLen, utf8.encode(patchedHead));
    File(path).writeAsBytesSync(bytes);
    expect(loadBarsSnapshot(path), isNull, reason: '版本不符');
  });

  test('路径命名：<数据库主名>-bars-snap.bin', () {
    expect(barsSnapshotPathFor('/a/b/stock.db'), '/a/b/stock-bars-snap.bin');
    expect(barsSnapshotPathFor('/a/b/nodot'), '/a/b/nodot-bars-snap.bin');
  });

  test('与 SQL load 逐位一致：真实库上快照重建 == loadStocksRange', () async {
    final dbPath = '${tmp.path}/t.db';
    final repo = BarRepository(dbPath);
    final rows = <DailyRow>[];
    for (var s = 0; s < 3; s++) {
      final code = ['000001.SZ', '600000.SH', '600519.SH'][s];
      for (var i = 0; i < 25; i++) {
        final d = DateTime(2026, 1, 1 + i);
        final ds =
            '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
        rows.add(DailyRow(
          tsCode: code,
          tradeDate: ds,
          open: 10 + i * 0.01,
          high: 10.5 + i * 0.01,
          low: 9.5 + i * 0.01,
          close: 10.2 + i * 0.01,
          vol: 100.0 + i,
          amount: 1000.0 + i,
        ));
      }
    }
    repo.upsertBars(rows);
    final wm = repo.poolFingerprintExt();
    final sqlStocks = repo.loadStocksRange('000001.SZ');
    repo.close();

    writeBarsSnapshot(barsSnapshotPathFor(dbPath), sqlStocks,
        maxRowid: wm.maxRowid, rowCount: wm.count);
    final snap = loadBarsSnapshot(barsSnapshotPathFor(dbPath))!;
    final snapStocks = stocksFromSnapshot(snap, '000001.SZ');

    expect(snapStocks.length, sqlStocks.length);
    for (var s = 0; s < sqlStocks.length; s++) {
      expect(snapStocks[s].symbol, sqlStocks[s].symbol);
      for (var i = 0; i < sqlStocks[s].bars.length; i++) {
        final a = snapStocks[s].bars[i];
        final b = sqlStocks[s].bars[i];
        expect(a.date, b.date, reason: '${sqlStocks[s].symbol}[$i].date');
        expect(a.open, b.open);
        expect(a.high, b.high);
        expect(a.low, b.low);
        expect(a.close, b.close);
        expect(a.volume, b.volume);
        expect(a.amount, b.amount);
      }
    }
  });

  test('增量 append：append 结果与全量重建逐位一致', () async {
    DailyRow dr(String code, DateTime d, int i) => DailyRow(
          tsCode: code,
          tradeDate:
              '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}',
          open: 10 + i * 0.01,
          high: 10.5 + i * 0.01,
          low: 9.5 + i * 0.01,
          close: 10.2 + i * 0.01,
          vol: 100.0 + i,
          amount: 1000.0 + i,
        );
    void expectStocksEqual(List<StockData> a, List<StockData> b) {
      expect(a.length, b.length);
      for (var s = 0; s < a.length; s++) {
        expect(a[s].symbol, b[s].symbol);
        expect(a[s].bars.length, b[s].bars.length, reason: '${b[s].symbol} 根数');
        for (var i = 0; i < b[s].bars.length; i++) {
          final x = a[s].bars[i], y = b[s].bars[i];
          expect(x.date, y.date, reason: '${b[s].symbol}[$i].date');
          expect(x.open, y.open);
          expect(x.high, y.high);
          expect(x.low, y.low);
          expect(x.close, y.close);
          expect(x.volume, y.volume);
          expect(x.amount, y.amount);
        }
      }
    }

    final dbPath = '${tmp.path}/t.db';
    final repo = BarRepository(dbPath);
    final path = barsSnapshotPathFor(dbPath);
    final rows0 = <DailyRow>[
      for (final code in ['000001.SZ', '600519.SH'])
        for (var i = 0; i < 25; i++) dr(code, DateTime(2026, 1, 1 + i), i),
    ];
    repo.upsertBars(rows0);
    var wm = repo.poolFingerprintExt();
    writeBarsSnapshot(path, repo.loadStocksRange('000001.SZ'),
        maxRowid: wm.maxRowid, rowCount: wm.count);

    // 追加：存量股续 5 天 + 新股 600600.SH（字典序插在 600519 之前，块要整体重排）
    final rows1 = <DailyRow>[
      for (final code in ['000001.SZ', '600519.SH'])
        for (var i = 25; i < 30; i++) dr(code, DateTime(2026, 1, 1 + i), i),
      for (var i = 0; i < 10; i++) dr('600600.SH', DateTime(2026, 1, 1 + i), i),
    ];
    rows1.sort((a, b) {
      final c = a.tsCode.compareTo(b.tsCode);
      return c != 0 ? c : a.tradeDate.compareTo(b.tradeDate);
    });
    repo.upsertBars(rows1);
    wm = repo.poolFingerprintExt();

    final old = loadBarsSnapshot(path)!;
    expect(appendBarsSnapshot(path, old, rows1, maxRowid: wm.maxRowid), isTrue);

    // 对照：全量重建
    writeBarsSnapshot('${tmp.path}/full.bin', repo.loadStocksRange('000001.SZ'),
        maxRowid: wm.maxRowid, rowCount: wm.count);
    final a = loadBarsSnapshot(path)!;
    final b = loadBarsSnapshot('${tmp.path}/full.bin')!;
    expect(a.maxRowid, b.maxRowid);
    expect(a.rowCount, b.rowCount);
    expect(a.symbols, b.symbols);
    expectStocksEqual(stocksFromSnapshot(a, '000001.SZ'),
        stocksFromSnapshot(b, '000001.SZ'));
    repo.close();
  });

  test('append 违规：新行日期 ≤ 存量股末根 → 返回 false 且原文件不动', () async {
    final dbPath = '${tmp.path}/t.db';
    final repo = BarRepository(dbPath);
    final path = barsSnapshotPathFor(dbPath);
    final rows0 = <DailyRow>[
      for (var i = 0; i < 25; i++)
        DailyRow(
          tsCode: '000001.SZ',
          tradeDate: (20260101 + i).toString(),
          open: 10,
          high: 10.5,
          low: 9.5,
          close: 10.2,
          vol: 100,
          amount: 1000,
        ),
    ];
    repo.upsertBars(rows0);
    final wm = repo.poolFingerprintExt();
    writeBarsSnapshot(path, repo.loadStocksRange('000001.SZ'),
        maxRowid: wm.maxRowid, rowCount: wm.count);
    final old = loadBarsSnapshot(path)!;
    final before = File(path).readAsBytesSync();

    // 日期早于末根 20260125：append 会破坏时间升序，必须拒绝
    final bad = [
      DailyRow(
        tsCode: '000001.SZ',
        tradeDate: '20260103',
        open: 10,
        high: 10.5,
        low: 9.5,
        close: 10.2,
        vol: 100,
        amount: 1000,
      ),
    ];
    expect(appendBarsSnapshot(path, old, bad, maxRowid: wm.maxRowid + 1),
        isFalse);
    expect(File(path).readAsBytesSync(), before, reason: '拒绝时不得动原文件');
    repo.close();
  });

  test('B 区间读快照只取所需块：与全量读切片逐位一致，且不依赖被截断的尾部', () async {
    final dbPath = '${tmp.path}/t.db';
    final repo = BarRepository(dbPath);
    final path = barsSnapshotPathFor(dbPath);
    repo.upsertBars([
      for (final code in ['600000.SH', '600001.SH', '600002.SH'])
        for (var i = 0; i < 10; i++)
          DailyRow(
            tsCode: code,
            tradeDate: (20260101 + i).toString(),
            open: 10 + i * 0.1,
            high: 10.5,
            low: 9.5,
            close: 10.2,
            vol: 100,
            amount: 1000,
          ),
    ]);
    final wm = repo.poolFingerprintExt();
    writeBarsSnapshot(path, repo.loadAllStocks(),
        maxRowid: wm.maxRowid, rowCount: wm.count);

    // 头只读（几百字节级），含定位所需信息
    final h = readSnapshotHeader(path);
    expect(h, isNotNull);
    expect(h!.symbols, ['600000.SH', '600001.SH', '600002.SH']);
    expect(h.maxRowid, wm.maxRowid);
    expect(h.rowCount, wm.count);

    final full =
        stocksFromSnapshot(loadBarsSnapshot(path)!, '600001.SH', toCode: '600002.SH');
    final ranged = stocksFromSnapshotFile(path, '600001.SH', toCode: '600002.SH');
    expect(ranged, isNotNull);
    expect(ranged!.length, 1);
    expect(ranged.single.symbol, '600001.SH');
    expect(full.length, 1);
    expect(ranged.single.bars.length, full.single.bars.length);
    for (var i = 0; i < full.single.bars.length; i++) {
      expect(ranged.single.bars[i].date, full.single.bars[i].date);
      expect(ranged.single.bars[i].close, full.single.bars[i].close);
      expect(ranged.single.bars[i].amount, full.single.bars[i].amount);
    }

    // 截掉最后一个块（600002.SH）：区间读不受影响（证明只读了前两块），
    // 但整段读必须失败——尾部缺失时不能静默返回不全的数据。
    var cut = h.dataStart;
    for (var s = 0; s < h.symbols.indexOf('600002.SH'); s++) {
      cut += 4 + h.lens[s] * 52;
    }
    final bytes = File(path).readAsBytesSync().sublist(0, cut);
    File(path).writeAsBytesSync(bytes);

    expect(stocksFromSnapshotFile(path, '600001.SH', toCode: '600002.SH'), isNotNull,
        reason: '所需块完整时必须成功');
    expect(stocksFromSnapshotFile(path, '600001.SH'), isNull,
        reason: '尾部块缺失时必须失败回退');
    expect(readSnapshotHeader(path), isNotNull,
        reason: '头完整时仍可读（截断只影响块区）');
    repo.close();
  });
}

