/// 日线 SQLite 存储。trade_date 用 tushare 的 YYYYMMDD 字符串（字典序即时间序）。
library;

import 'package:sqlite3/sqlite3.dart';

import '../core/models.dart';
import 'tushare_client.dart';

/// 打开（或创建）日线库。数据量约 5400 股 × N 日，单文件无压力。
class BarRepository {
  BarRepository(String path) : _db = sqlite3.open(path) {
    // WAL：自动同步（写）与选股（读）可能并发，避免读写互锁。
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('CREATE TABLE IF NOT EXISTS stocks ('
        'ts_code TEXT PRIMARY KEY, name TEXT NOT NULL)');
    _db.execute('CREATE TABLE IF NOT EXISTS daily_bars ('
        'ts_code TEXT NOT NULL, trade_date TEXT NOT NULL, '
        'open REAL NOT NULL, high REAL NOT NULL, low REAL NOT NULL, close REAL NOT NULL, '
        'vol REAL NOT NULL, amount REAL NOT NULL, '
        'PRIMARY KEY (ts_code, trade_date))');
  }

  final Database _db;

  void upsertStocks(List<({String tsCode, String name})> stocks) {
    if (stocks.isEmpty) return;
    _db.execute('BEGIN');
    try {
      final st = _db.prepare('INSERT OR REPLACE INTO stocks VALUES (?, ?)');
      for (final s in stocks) {
        st.execute([s.tsCode, s.name]);
      }
      st.dispose();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void upsertBars(List<DailyRow> rows) {
    if (rows.isEmpty) return;
    _db.execute('BEGIN');
    try {
      final st =
          _db.prepare('INSERT OR REPLACE INTO daily_bars VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
      for (final r in rows) {
        st.execute(
            [r.tsCode, r.tradeDate, r.open, r.high, r.low, r.close, r.vol, r.amount]);
      }
      st.dispose();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 库中最大的交易日（即已同步到哪天）；空库返回 null。
  String? maxTradeDate() {
    final r = _db.select('SELECT MAX(trade_date) FROM daily_bars');
    return r.first.values[0] as String?;
  }

  /// 股票代码 → 名称（低积分下 stocks 表可能为空，调用方需降级显示）。
  Map<String, String> stockNames() => {
        for (final r in _db.select('SELECT ts_code, name FROM stocks'))
          r['ts_code'] as String: r['name'] as String,
      };

  /// 全部股票代码（含已停更的），供逐股备源遍历。
  List<String> allSymbols() => [
        for (final r in _db.select('SELECT DISTINCT ts_code FROM daily_bars ORDER BY ts_code'))
          r['ts_code'] as String,
      ];

  /// 单只股票的日线，按日期升序；无数据返回空列表。
  List<Bar> barsFor(String tsCode) {
    final rows = _db.select(
        'SELECT trade_date, open, high, low, close, vol, amount '
        'FROM daily_bars WHERE ts_code = ? ORDER BY trade_date', [tsCode]);
    return [
      for (final r in rows)
        Bar(
          date: DateTime.parse(r['trade_date'] as String),
          open: (r['open'] as num).toDouble(),
          high: (r['high'] as num).toDouble(),
          low: (r['low'] as num).toDouble(),
          close: (r['close'] as num).toDouble(),
          volume: (r['vol'] as num).toDouble(),
          amount: (r['amount'] as num).toDouble(),
        ),
    ];
  }

  /// 全部股票的日线，按股票分组、日期升序；不足 [minBars] 根的股票剔除。
  List<StockData> loadAllStocks({int minBars = 0}) {
    final rows = _db.select(
        'SELECT ts_code, trade_date, open, high, low, close, vol, amount '
        'FROM daily_bars ORDER BY ts_code, trade_date');
    final byStock = <String, List<Bar>>{};
    for (final r in rows) {
      final ts = r['ts_code'] as String;
      (byStock[ts] ??= []).add(Bar(
            date: DateTime.parse(r['trade_date'] as String),
            open: (r['open'] as num).toDouble(),
            high: (r['high'] as num).toDouble(),
            low: (r['low'] as num).toDouble(),
            close: (r['close'] as num).toDouble(),
            volume: (r['vol'] as num).toDouble(),
            amount: (r['amount'] as num).toDouble(),
          ));
    }
    return [
      for (final e in byStock.entries)
        if (e.value.length >= minBars) StockData(symbol: e.key, bars: e.value),
    ];
  }

  void close() => _db.dispose();
}

