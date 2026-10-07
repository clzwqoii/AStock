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

/// 回补历史的区间下界：今天往前推 [years] 个日历年（`YYYYMMDD`，闭区间）。
/// 2/29 回补 1 年会滚到 3/1——区间模式只要求"约一年前"，无需精确日。
///
/// 放在这里而不是 sync 侧：覆盖判定 [HistoryCoverage.isYearsCovered] 与
/// 回补区间必须用同一个下界口径，两边分开写迟早对不上。
String backfillFromDate(DateTime now, int years) {
  final target = DateTime(now.year - years, now.month, now.day);
  return '${target.year}${target.month.toString().padLeft(2, '0')}${target.day.toString().padLeft(2, '0')}';
}

String _daysAgo(DateTime now, int days) {
  final d = now.subtract(Duration(days: days));
  return '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
}

/// 库内历史行情覆盖情况（供设置页与回补弹窗诊断历史深度、是否需要回补）。
class HistoryCoverage {
  const HistoryCoverage({
    required this.minDate,
    required this.maxDate,
    required this.tradeDays,
    required this.totalBars,
  });

  /// 库内最早交易日（`YYYYMMDD`）；空库为 null。
  final String? minDate;

  /// 库内最新交易日（`YYYYMMDD`）；空库为 null。
  final String? maxDate;

  /// 库内包含的不同交易日数。
  final int tradeDays;

  /// 库内日线总行数。
  final int totalBars;

  /// 是否为空库。
  bool get isEmpty => minDate == null;

  /// 指定年数（1/2/3 年）的历史是否已经覆盖到位：
  /// 1. 最早交易日 <= 该年数起算日期；
  /// 2. 最新交易日不严重断更（[isStale]）；
  /// 3. 交易日数满足基本密度（每年至少 [minDaysPerYear] 交易日，防止拉了头尾或中途断流）。
  ///
  /// 三条都不满足时返回 false，但**原因不同**：调用方要给诊断文案时必须先问
  /// [isStale]——断更库的深度往往够，"不足 N 年"的说法会把用户指去补历史，
  /// 而真正该做的是恢复同步。
  bool isYearsCovered(int years, [DateTime? now, int minDaysPerYear = 180]) {
    if (minDate == null || maxDate == null) return false;
    final current = now ?? DateTime.now();
    final target = backfillFromDate(current, years);
    if (minDate!.compareTo(target) > 0) return false;
    if (isStale(current)) return false;
    if (tradeDays < years * minDaysPerYear) return false;
    return true;
  }

  /// 末根是否已严重断更：最新交易日早于 [now] 往前 [staleDays] 天。
  ///
  /// 空库不算断更（那是"还没有数据"，由 [isEmpty] 表达）。
  bool isStale([DateTime? now, int staleDays = 45]) {
    if (maxDate == null) return false;
    return maxDate!.compareTo(_daysAgo(now ?? DateTime.now(), staleDays)) < 0;
  }
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

  /// 库中最早的交易日（回补历史覆盖下界，回执用它验收是否补到位）；空库返回 null。
  String? minTradeDate() {
    final r = _db.select('SELECT MIN(trade_date) FROM daily_bars');
    return r.first.values[0] as String?;
  }

  /// 库内历史覆盖统计：最早/最新交易日、不同交易日数、总行数。
  HistoryCoverage historyCoverage() {
    final r = _db.select(
        'SELECT MIN(trade_date), MAX(trade_date), COUNT(DISTINCT trade_date), COUNT(*) FROM daily_bars');
    final row = r.first;
    return HistoryCoverage(
      minDate: row.values[0] as String?,
      maxDate: row.values[1] as String?,
      tradeDays: (row.values[2] as num?)?.toInt() ?? 0,
      totalBars: (row.values[3] as num?)?.toInt() ?? 0,
    );
  }

  /// 选股池失效指纹：水位 + 最大 rowid。选股池缓存用它判断要不要重读全库。
  ///
  /// 只有水位不够：回补历史（[SyncService] 的区间模式）插入的是**早于水位**
  /// 的行，水位不动但池子内容变了。MAX(rowid) 补这个洞——daily_bars 是普通
  /// rowid 表，INSERT OR REPLACE 也换 rowid，任何写入都逃不过它；两条 MAX
  /// 都走索引/builtin 优化，O(1)。
  String poolFingerprint() {
    final r = _db.select('SELECT MAX(trade_date), MAX(rowid) FROM daily_bars');
    return '${r.first.values[0]}|${r.first.values[1]}';
  }

  /// 日线总行数（进度观感用，CLI 打印同步前后行数）。
  int barCount() {
    final r = _db.select('SELECT COUNT(*) AS n FROM daily_bars');
    return r.first['n'] as int;
  }

  /// 某交易日的日线行数（备源补数后判断哪些日期仍是缺口）。
  int rowCountOnDate(String tradeDate) {
    final r = _db.select(
        'SELECT COUNT(*) AS n FROM daily_bars WHERE trade_date = ?', [tradeDate]);
    return r.first['n'] as int;
  }

  /// 股票代码 → 名称（低积分下 stocks 表可能为空，调用方需降级显示）。
  Map<String, String> stockNames() => {
        for (final r in _db.select('SELECT ts_code, name FROM stocks'))
          r['ts_code'] as String: r['name'] as String,
      };

  /// 单只股票的名称；库里没有该代码时返回 null。
  /// 详情页只要一个名字，别为它走 [stockNames] 把整张表读成 Map。
  String? stockName(String tsCode) {
    final r = _db.select('SELECT name FROM stocks WHERE ts_code = ?', [tsCode]);
    return r.isEmpty ? null : r.first['name'] as String;
  }

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
  /// [excludeSpecialStocks] 为 true 时把 ST 系与科创板挡在选股池外：
  /// 名称以 ST / *ST / S*ST / PT 开头（风险警示与退市整理），名称含「退」（退市整理期
  /// 个股，退市XX 与 XX退 两种写法都在真实库里），代码以 68 开头（科创板与 CDR，
  /// 权限门槛与主板不同）。ST 标记只在开头——按子串匹配会误杀名字里含 ST 的正常股票。
  ///
  /// **回测必须传 false（默认）**：回测要在与选股一致的样本上才有意义，但剔除会移动
  /// 样本口径（历史胜率会变），要换口径必须重新生成报告。选股入口传 true。
  ///
  /// [maxBars] > 0 时每只股票只保留末尾这么多根。**默认 0（不截断），生产路径未启用**：
  /// 截断会移动 `IndicatorSeries` 的前缀位置，从而移动各指标的 null 边界——
  /// MA250 在序列前 249 位为 null，一只 320 根的股票截到 300 根后 MA250 仍可算，
  /// 截到 250 根就恰好卡在边界上。全市场 244 只历史不足 300 根的股票会因此改变
  /// 命中结果（实测 ma250_up 差 1~23 只、ma60_breakout 差 1 只）。这不是纯性能优化，
  /// 是选股口径变更，要启用必须先确认口径变更可接受。
  ///
  /// 回测必须传 0：它逐日滚动、需要全部历史。
  List<StockData> loadAllStocks({
    int minBars = 0,
    int maxBars = 0,
    bool excludeSpecialStocks = false,
  }) {
    // 逐行游标而非 `_db.select`：后者先把 360 万行全物化成 Row 对象再交给调用方。
    // 用下标取值而非列名：省掉每行的列名哈希查找。
    // 走 columnAt 而不是 r[i]：避免 collection_methods_unrelated_type。
    //
    // 性能优化（内存与速度）：
    // 1. 利用 SQL `ORDER BY ts_code, trade_date` 的连续性，单股流式聚集成 List<StockData>，
    //    消除 360 万次 Map<String, List<Bar>> 哈希查找及中间大 Map 分配。
    // 2. 日期对象缓存复用：全库实际只有 ~700-1000 个唯一交易日，复用 DateTime 实例，
    //    免去 360 万次 DateTime 分配及千万次 substring，省约 100MB 堆内存。
    // 3. maxBars 就地裁剪，无需在结束后分配第二个 trimmed Map。
    final st = _db.prepare(
        'SELECT ts_code, trade_date, open, high, low, close, vol, amount '
        'FROM daily_bars ${_specialFilterSql(excludeSpecialStocks)} '
        'ORDER BY ts_code, trade_date');
    final result = <StockData>[];
    final dateCache = <String, DateTime>{};
    String? currentTs;
    var currentBars = <Bar>[];

    void flushCurrent() {
      if (currentTs == null) return;
      if (maxBars > 0 && currentBars.length > maxBars) {
        currentBars = currentBars.sublist(currentBars.length - maxBars);
      }
      if (currentBars.length >= minBars) {
        result.add(StockData(symbol: currentTs, bars: currentBars));
      }
    }

    try {
      final cur = st.selectCursor();
      while (cur.moveNext()) {
        final r = cur.current;
        final ts = r.columnAt(0) as String;
        if (ts != currentTs) {
          flushCurrent();
          currentTs = ts;
          currentBars = <Bar>[];
        }
        final dateStr = r.columnAt(1) as String;
        final date = dateCache[dateStr] ??= parseTradeDate(dateStr);
        currentBars.add(Bar(
              date: date,
              open: (r.columnAt(2) as num).toDouble(),
              high: (r.columnAt(3) as num).toDouble(),
              low: (r.columnAt(4) as num).toDouble(),
              close: (r.columnAt(5) as num).toDouble(),
              volume: (r.columnAt(6) as num).toDouble(),
              amount: (r.columnAt(7) as num).toDouble(),
            ));
      }
      flushCurrent();
    } finally {
      st.dispose();
    }
    return result;
  }

  void close() => _db.dispose();

  /// 选股池过滤的 SQL 片段（参数为 false 时返回空串，查询与不加过滤逐字节相同）。
  /// GLOB 而非 LIKE：`?` 是 LIKE 的单字符通配符，用它写 `S?ST?*` 会连 `SHST` 之类
  /// 一起匹配；GLOB 无此坑，且能用主键覆盖索引（实测 360 万行 1.4s，与不过滤同量级）。
  String _specialFilterSql(bool excludeSpecialStocks) => excludeSpecialStocks
      ? "WHERE ts_code NOT LIKE '68%' "
          "AND ts_code NOT IN (SELECT ts_code FROM stocks WHERE "
          "name GLOB 'ST*' OR name GLOB '*ST*' OR name GLOB 'S*ST*' "
          "OR name GLOB 'PT*' OR name LIKE '%退%')"
      : '';
}

