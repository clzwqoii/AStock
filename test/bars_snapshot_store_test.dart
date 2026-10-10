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
}

