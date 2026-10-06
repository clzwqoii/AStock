/// 增量同步编排：日历 → 待拉日期 → 逐日拉全市场日线入库。
library;

import 'dart:io';

import 'bar_repository.dart';
import 'eastmoney_client.dart';
import 'sina_client.dart';
import 'tencent_client.dart';
import 'tushare_client.dart';

class SyncResult {
  const SyncResult({required this.dates, required this.rows, this.latestDate});

  /// 本次实际拉取的交易日数。
  final int dates;

  /// 本次入库的日线行数。
  final int rows;

  /// 同步完成后库内最大交易日（`YYYYMMDD`）；空库为 null。
  final String? latestDate;
}

/// 回补历史的区间下界：今天往前推 [years] 个日历年（`YYYYMMDD`，闭区间）。
/// 2/29 回补 1 年会滚到 3/1——区间模式只要求"约一年前"，无需精确日。
String backfillFromDate(DateTime now, int years) {
  final d = DateTime(now.year - years, now.month, now.day);
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${d.year}${p2(d.month)}${p2(d.day)}';
}

/// 同步规则：
/// - 首次（空库）回填最近 [backfillDays] 个交易日；
/// - 之后只拉「已同步最大交易日之后、且已收盘」的交易日；
/// - 当天盘中运行时当日数据不完整，始终跳过，等次日增量补上。
class SyncService {
  SyncService(
    this._client,
    this._repo, {
    DateTime Function()? now,
    this.calendarWindowDays = 1100,
    this.retryWait = const Duration(seconds: 65),
    this.eastmoney,
    this.tencent,
    this.sina,
  })  : _now = now ?? DateTime.now;

  final TushareClient _client;
  final BarRepository _repo;
  final DateTime Function() _now;
  final EastmoneyClient? eastmoney;

  /// 日线逐股备源：新浪（不复权·手，与 tushare 主源同口径）。
  /// 腾讯仅用于股票名称查询——它的日K只有前复权（与主源混用会造成历史断层），网易接口已 502，均不进日线链路。
  final TencentClient? tencent;
  final SinaClient? sina;

  /// 回填窗口的日历查询跨度（日历日）。
  /// 1100 天 ≈ 3 年 ≈ 750 个交易日：既够算 MA250（约 420 根），
  /// 也让回测样本能跨越多段行情（切半/分年稳健性检验需要）。
  final int calendarWindowDays;

  /// 触发 40203 限频后的等待时长。tushare 按分钟计频，65 秒确保进入下一窗口。
  final Duration retryWait;

  Future<T> _withRateRetry<T>(Future<T> Function() op,
      {String? label, int maxAttempts = 6}) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await op();
      } on TushareException catch (e) {
        if (e.code != 40203 || attempt >= maxAttempts - 1) rethrow;
        stderr.writeln('限频等待重试${label == null ? '' : ' ($label)'}: ${e.message}');
        await Future.delayed(retryWait);
      }
    }
  }

  /// 同步规则：
  /// - 首次（空库）回填最近 [backfillDays] 个交易日；
  /// - 之后只拉「已同步最大交易日之后、且已收盘」的交易日；
  /// - 当天盘中运行时当日数据不完整，始终跳过，等次日增量补上。
  ///
  /// [fromDate] / [toDate]（`YYYYMMDD`，闭区间）**任一传入即进入区间模式**：
  /// 绕过水位线，强制拉这个区间（另一侧留空表示不设界）。
  /// 水位线增量只会拉 `MAX(trade_date)` 之后的日期，补不了更早的历史——
  /// 想把库从 120 个交易日扩到 250 个，必须显式给区间。
  /// `upsertBars` 是 `INSERT OR REPLACE`，重复拉同一区间幂等。
  Future<SyncResult> sync({
    int backfillDays = 250,
    Duration rateDelay = const Duration(milliseconds: 350),
    String? fromDate,
    String? toDate,
    void Function(String msg)? onProgress,
  }) async {
    for (final d in [fromDate, toDate]) {
      if (d != null && !RegExp(r'^\d{8}$').hasMatch(d)) {
        throw ArgumentError('日期格式应为 YYYYMMDD，实际 $d');
      }
    }
    if (fromDate != null && toDate != null && fromDate.compareTo(toDate) > 0) {
      throw ArgumentError('fromDate($fromDate) 晚于 toDate($toDate)');
    }
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}'
        '${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}';

    final today = _now();
    final todayStr = fmt(today);

    // 交易日历：低积分限频严格（如 1 次/小时），失败时退化为工作日候选；
    // 节假日会拉到空数据、不入库，下次同步自动重试（自愈）。
    List<String> candidates;
    // 网络层异常（DNS 失败/被墙/断网）与 tushare 错误码同样要降级：
    // 真机实测过 api.tushare.pro 解析失败时整个同步中断、一格数据都没进库。
    try {
      final cal = await _withRateRetry(
          () => _client.tradeCal(
              fmt(today.subtract(Duration(days: calendarWindowDays))), fmt(today)),
          label: 'trade_cal',
          maxAttempts: 1);
      candidates = [for (final c in cal) if (c.isOpen) c.date];
    } on Exception {
      stderr.writeln('交易日历不可用，改用工作日候选（节假日会拉到空数据并自动跳过）');
      candidates = [];
      for (var d = today.subtract(Duration(days: calendarWindowDays));
          !d.isAfter(today);
          d = d.add(const Duration(days: 1))) {
        if (d.weekday >= DateTime.monday && d.weekday <= DateTime.friday) {
          candidates.add(fmt(d));
        }
      }
    }

    // 当日数据以 17 点为可用截止（tushare 收盘后更新）；此前视为未收盘，跳过。
    bool closed(String d) =>
        d.compareTo(todayStr) < 0 || (d == todayStr && today.hour >= 17);
    final closedOpen = [for (final d in candidates) if (closed(d)) d];

    final synced = _repo.maxTradeDate();
    final inRange = fromDate == null && toDate == null;
    final targets = inRange
        ? (synced == null
            ? (closedOpen.length <= backfillDays
                ? closedOpen
                : closedOpen.sublist(closedOpen.length - backfillDays))
            : [for (final d in closedOpen) if (d.compareTo(synced) > 0) d])
        : [
            for (final d in closedOpen)
              if ((fromDate == null || d.compareTo(fromDate) >= 0) &&
                  (toDate == null || d.compareTo(toDate) <= 0))
                d
          ];

    // 股票名单是可选信息，三级降级：tushare stock_basic → 东财 clist → 逐股行情回填名称；
    // 全部失败只置标记，等日线入库后再回填名称（那时本地才有代码清单）。
    var needNameBackfill = false;
    try {
      _repo.upsertStocks(
          await _withRateRetry(_client.stockBasic, label: 'stock_basic', maxAttempts: 1));
    } on Exception {
      try {
        _repo.upsertStocks(await (eastmoney ?? EastmoneyClient()).stockList());
        stderr.writeln('tushare 股票列表限频，已自动改用东方财富数据源');
      } catch (e) {
        needNameBackfill = true;
      }
    }

    var rows = 0;
    try {
      for (final d in targets) {
        // 有逐股备源时 tushare daily 一次失败立即切换，不做 65 秒重试等待。
        final dayRows = await _withRateRetry(() => _client.daily(tradeDate: d),
            label: 'daily $d', maxAttempts: _hasPerStockSources ? 1 : 6);
        _repo.upsertBars(dayRows);
        rows += dayRows.length;
        onProgress?.call('$d ${dayRows.length} 行');
        if (rateDelay > Duration.zero) await Future.delayed(rateDelay);
      }
    } on Exception {
      // 错误码与网络层异常（DNS/超时/连接被拒）都走逐股备源；备源为空才把异常抛给上层提示。
      final sources = _perStockSources();
      if (sources.isEmpty) rethrow;
      stderr.writeln(
          'tushare 日线不可用，按优先级降级：${sources.map((s) => s.$1).join(' → ')}');
      rows += await _fillPerStock(targets, sources, onProgress, rateDelay);
    }
    if (needNameBackfill) {
      stderr.writeln('名单源均不可用，改用逐股行情回填名称（一次性，约 10 分钟）');
      await _backfillNames(onProgress);
    }
    return SyncResult(
        dates: targets.length, rows: rows, latestDate: _repo.maxTradeDate());
  }

  bool get _hasPerStockSources => sina != null;

  /// 日线逐股备源链（按优先级）。元素为 (源名, 按股票代码拉日K)。
  List<(String, Future<List<DailyRow>> Function(String symbol))> _perStockSources() => [
        if (sina != null) ('新浪', (sym) => sina!.dailyBars(sym)),
      ];

  /// 逐股补数：遍历本地已有股票（空库时向东财要名单），
  /// 按优先级尝试各源——某源拉到数据即采用，无数据自动切下一源。单只失败跳过。
  Future<int> _fillPerStock(
    List<String> targets,
    List<(String, Future<List<DailyRow>> Function(String symbol))> sources,
    void Function(String msg)? onProgress,
    Duration rateDelay,
  ) async {
    var symbols = _repo.allSymbols();
    if (symbols.isEmpty) {
      symbols = [
        for (final s in await (eastmoney ?? EastmoneyClient()).stockList()) s.tsCode
      ];
    }
    final minD = targets.first;
    final maxD = targets.last;
    var rows = 0;
    for (final (label, fetch) in sources) {
      var done = 0;
      rows = 0;
      // 攒批再入库：逐股提交意味着每只股票一次 BEGIN/COMMIT（一次 fsync），
      // 全市场 5672 次。同样的行改成每 200 只一批，实测快约 3 倍
      // （0.35s → 0.11s）。绝对收益不大（这条路径的主成本是每只 350ms 的
      // 网络延迟，合计半小时），但代码没变复杂。
      final batch = <DailyRow>[];
      void flush() {
        if (batch.isEmpty) return;
        _repo.upsertBars(batch);
        batch.clear();
      }

      for (final sym in symbols) {
        if (!(sym.endsWith('.SH') || sym.endsWith('.SZ'))) continue; // 备源均不含北交所
        try {
          final bars = await fetch(sym);
          final picked = [
            for (final b in bars)
              if (b.tradeDate.compareTo(minD) >= 0 && b.tradeDate.compareTo(maxD) <= 0) b
          ];
          batch.addAll(picked);
          rows += picked.length;
          if (batch.length >= 200) flush();
        } catch (_) {
          // 单只失败不影响整体（次日同步会按水位线自然补齐）。
        }
        done++;
        if (done % 200 == 0) onProgress?.call('$label 备源 $done/${symbols.length}');
        if (rateDelay > Duration.zero) await Future.delayed(rateDelay);
      }
      flush(); // 收尾：最后不足一批的也要落库
      if (rows > 0) {
        onProgress?.call('$label 备源完成：$done 只，$rows 行');
        return rows;
      }
      stderr.writeln('$label 备源无数据，降级下一源');
    }
    return rows;
  }

  /// 名称回填（逐股）：只补 stocks 表里还没有名称的代码；
  /// 每只先腾讯后东财，30ms 间隔防限流（免 token 接口，无严格配额）。
  Future<void> _backfillNames(void Function(String msg)? onProgress) async {
    final symbols = _repo.allSymbols();
    if (symbols.isEmpty) return;
    final existing = _repo.stockNames();
    final todo = [for (final s in symbols) if (!existing.containsKey(s)) s];
    if (todo.isEmpty) return;
    final fetchers = [
      if (tencent != null) tencent!.stockName,
      if (eastmoney != null) eastmoney!.stockName,
    ];
    if (fetchers.isEmpty) return;
    var done = 0;
    var got = 0;
    for (final sym in todo) {
      for (final fetch in fetchers) {
        try {
          final name = await fetch(sym);
          if (name != null && name.isNotEmpty) {
            _repo.upsertStocks([(tsCode: sym, name: name)]);
            got++;
            break;
          }
        } catch (_) {
          // 该源这只失败，尝试下一源。
        }
      }
      done++;
      if (done % 500 == 0) onProgress?.call('名称回填 $done/${todo.length}');
      await Future.delayed(const Duration(milliseconds: 30));
    }
    onProgress?.call('名称回填完成：$got/${todo.length}');
  }
}
