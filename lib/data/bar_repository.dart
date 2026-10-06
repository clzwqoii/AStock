/// 日线 SQLite 存储。trade_date 用 tushare 的 YYYYMMDD 字符串（字典序即时间序）。
library;

import 'package:sqlite3/sqlite3.dart';

import '../core/models.dart';
import 'tushare_client.dart';

/// 解析 `YYYYMMDD` 交易日。定长数字串直接切片取值，比 [DateTime.parse]
/// （内部多格式正则匹配，微基准 0.79µs vs 0.30µs）快约 2.6 倍——
/// 全市场加载 200 万+ 行时这是 IO 之外的最大开销。
/// 与 [DateTime.parse] 同样不校验月日范围（如 20230230 静默进位到 3-2），
/// 非 8 位或含非数字时抛 [FormatException]。
///
/// 公开而非私有：这是纯函数且已被优化过，必须能被 `test/bar_repository_test.dart`
/// 拿 [DateTime.parse] 当 oracle 逐位比对，否则「快 10 倍」的等价性无人担保。
DateTime parseTradeDate(String s) {
  if (s.length != 8) {
    throw FormatException('trade_date 应为 YYYYMMDD，实际 "$s"');
  }
  return DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)));
}

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
    // trade_date 单列索引：MAX(trade_date)（选股与同步的水位线）走不了主键前缀，
    // 否则每次都整体扫主键索引（360 万行实测 ~80ms → 建索引后 ~5ms，磁盘 ~58MB）。
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_daily_bars_trade_date ON daily_bars(trade_date)');
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

  /// 日线总行数（进度观感用，CLI 打印同步前后行数）。
  int barCount() {
    final r = _db.select('SELECT COUNT(*) AS n FROM daily_bars');
    return r.first['n'] as int;
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
          date: parseTradeDate(r['trade_date'] as String),
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
  ///
  /// [maxBars] > 0 时每只股票只保留末尾这么多根。**默认 0（不截断），生产路径未启用**：
  /// 截断会移动 `IndicatorSeries` 的前缀位置，从而移动各指标的 null 边界——
  /// MA250 在序列前 249 位为 null，一只 320 根的股票截到 300 根后 MA250 仍可算，
  /// 截到 250 根就恰好卡在边界上。全市场 244 只历史不足 300 根的股票会因此改变
  /// 命中结果（实测 ma250_up 差 1~23 只、ma60_breakout 差 1 只）。这不是纯性能优化，
  /// 是选股口径变更，要启用必须先确认口径变更可接受。
  ///
  /// 回测必须传 0：它逐日滚动、需要全部历史。
  List<StockData> loadAllStocks({int minBars = 0, int maxBars = 0}) {
    final byStock = <String, List<Bar>>{};
    // 逐行游标而非 `_db.select`：后者先把 360 万行全物化成 Row 对象再交给调用方，
    // 实测峰值 RSS 1889MB / 5.82s；游标流式读是 648MB / 4.68s，同一份数据逐位一致。
    // 内存这条比时间更要紧——移动端 1.9GB 会被系统直接杀掉。
    // 用下标取值而非列名：省掉每行的列名哈希查找（4.87s → 4.75s）。
    // 走 columnAt 而不是 r[i]：Row 的静态接口是 Map<String, dynamic>，
    // int 下标虽然运行时可用，但每个访问点都会触发 collection_methods_unrelated_type。
    final st = _db.prepare(
        'SELECT ts_code, trade_date, open, high, low, close, vol, amount '
        'FROM daily_bars ORDER BY ts_code, trade_date');
    try {
      final cur = st.selectCursor();
      while (cur.moveNext()) {
        final r = cur.current;
        final ts = r.columnAt(0) as String;
        (byStock[ts] ??= []).add(Bar(
              date: parseTradeDate(r.columnAt(1) as String),
              open: (r.columnAt(2) as num).toDouble(),
              high: (r.columnAt(3) as num).toDouble(),
              low: (r.columnAt(4) as num).toDouble(),
              close: (r.columnAt(5) as num).toDouble(),
              volume: (r.columnAt(6) as num).toDouble(),
              amount: (r.columnAt(7) as num).toDouble(),
            ));
      }
    } finally {
      st.dispose();
    }
    if (maxBars > 0) {
      // 用 entries 而不是 keys/values：keys 与 values 各自是独立 List，
      // elementAt 在 List 上是 O(n) —— 5672 只股票会退化成 O(n²)。
      final trimmed = <String, List<Bar>>{
        for (final e in byStock.entries)
          e.key: e.value.length > maxBars
              ? e.value.sublist(e.value.length - maxBars)
              : e.value,
      };
      byStock
        ..clear()
        ..addAll(trimmed);
    }
    return [
      for (final e in byStock.entries)
        if (e.value.length >= minBars) StockData(symbol: e.key, bars: e.value),
    ];
  }

  void close() => _db.dispose();
}

