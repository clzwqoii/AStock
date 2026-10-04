import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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

  test('stockNames 读取股票名单', () {
    expect(repo.stockNames(), isEmpty);
    repo.upsertStocks([(tsCode: '000001.SZ', name: '平安银行')]);
    expect(repo.stockNames()['000001.SZ'], '平安银行');
  });

  test('数据库启用 WAL 模式（允许同步写入与选股读取并发）', () {
    final db2 = sqlite3.open('${tmp.path}/test.db');
    try {
      expect(db2.select('PRAGMA journal_mode').first.values[0], 'wal');
    } finally {
      db2.dispose();
    }
  });

  test('maxTradeDate 取最大交易日，空库为 null', () {
    expect(repo.maxTradeDate(), isNull);
    repo.upsertBars([row('000001.SZ', '20260929'), row('000001.SZ', '20260930')]);
    expect(repo.maxTradeDate(), '20260930');
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
}
