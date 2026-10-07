/// 增量同步编排：日历 → 待拉日期 → 逐日拉全市场日线入库。
library;

import 'dart:io';

import 'bar_repository.dart';
import 'eastmoney_client.dart';
import 'sina_client.dart';
import 'tencent_client.dart';
import 'tushare_client.dart';

export 'bar_repository.dart' show backfillFromDate, HistoryCoverage;

class SyncResult {
  const SyncResult({
    required this.dates,
    required this.rows,
    this.latestDate,
    this.earliestDate,
    this.failedSymbols = 0,
  });

  /// 本次实际拉取的交易日数。
  final int dates;

  /// 本次入库的日线行数。
  final int rows;

  /// 同步完成后库内最大交易日（`YYYYMMDD`）；空库为 null。
  final String? latestDate;

  /// 同步完成后库内最早交易日（`YYYYMMDD`）。回补历史的验收锚点：
  /// 选了 3 年而它晚于 3 年前，就是没补齐——光看行数看不出来。
  final String? earliestDate;

  /// 逐股备源拉取失败的股票只数（单只失败不中断，但必须在回执里可见，
  /// 否则大量失败也显示"回补完成"，用户以为数据齐了）。
  final int failedSymbols;
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
    this.netRetries = 2,
    this.netRetryWait = const Duration(seconds: 2),
    this.eastmoney,
    this.tencent,
    this.sina,
  })  : _now = now ?? DateTime.now;

  final TushareClient _client;
  final BarRepository _repo;
  final DateTime Function() _now;

  /// 东财：名单/名称之外还是日线备源链第一顺位（fqt=0 不复权·手，见
  /// [EastmoneyClient.dailyBars]）；为 null 时链路里没有东财这一环。
  final EastmoneyClient? eastmoney;

  /// 日线逐股备源第二顺位：新浪（不复权·手；无成交额，只有最近 400 根）。
  /// 腾讯仅用于股票名称查询——它的日K只有前复权（与主源混用会造成历史断层），网易接口已 502，均不进日线链路。
  final TencentClient? tencent;
  final SinaClient? sina;

  /// 回填窗口的日历查询跨度（日历日）。
  /// 1100 天 ≈ 3 年 ≈ 750 个交易日：既够算 MA250（约 420 根），
  /// 也让回测样本能跨越多段行情（切半/分年稳健性检验需要）。
  final int calendarWindowDays;

  /// 触发 40203 限频后的等待时长。tushare 按分钟计频，65 秒确保进入下一窗口。
  final Duration retryWait;

  /// 网络层抖动（超时/DNS/连接重置）的短重试次数与间隔。仅在有逐股备源时
  /// 启用：备源（新浪）只有最近 400 根深度，一次抖动不该把整段区间甩过去。
  final int netRetries;
  final Duration netRetryWait;

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

  /// 单日 daily 拉取，带恢复策略：40203 等 [retryWait] 穿过分钟窗口重试
  /// （[tolerant] 时最多 3 次，否则 6 次）；网络层抖动短间隔重试最多
  /// [netRetries] 次（仅 [tolerant] 即备源可用时）。都耗尽才抛给上层降级——
  /// 备源慢且深度只有 400 根，能不进就不进。
  Future<List<DailyRow>> _fetchDaily(String tradeDate,
      {required bool tolerant}) async {
    final maxRateAttempts = tolerant ? 3 : 6;
    var rateAttempts = 0;
    var netAttempts = 0;
    for (;;) {
      try {
        return await _client.daily(tradeDate: tradeDate);
      } on TushareException catch (e) {
        rateAttempts++;
        if (e.code != 40203 || rateAttempts >= maxRateAttempts) rethrow;
        stderr.writeln('限频等待重试 (daily $tradeDate): ${e.message}');
        await Future.delayed(retryWait);
      } on Exception catch (e) {
        if (!tolerant || netAttempts >= netRetries) rethrow;
        netAttempts++;
        stderr.writeln('网络异常重试 (daily $tradeDate): $e');
        if (netRetryWait > Duration.zero) await Future.delayed(netRetryWait);
      }
    }
  }

  /// 同步规则：
  /// - 首次（空库）回填最近 [backfillDays] 个交易日；
  /// - 之后只拉「已同步最大交易日之后、且已收盘」的交易日；
  /// - 当天盘中运行时当日数据不完整，始终跳过，等次日增量补上。
  ///
  /// [fromDate] / [toDate]（`YYYYMMDD`，闭区间）**任一传入即进入区间模式**：
  /// 绕过水位线，强制拉这个区间（另一侧留空表示不设界）；库里已有行数的日期
  /// 直接跳过，所以重复回补只花缺口的配额。
  /// 水位线增量只会拉 `MAX(trade_date)` 之后的日期，补不了更早的历史——
  /// 想把库从 120 个交易日扩到 250 个，必须显式给区间。
  /// `upsertBars` 是 `INSERT OR REPLACE`，重复拉同一区间幂等。
  ///
  /// [force] 只在区间模式下有意义：关掉「已有行数就跳过」，整段无条件重拉
  /// （数据源口径修正后覆盖旧数据用）。
  Future<SyncResult> sync({
    int backfillDays = 250,
    Duration rateDelay = const Duration(milliseconds: 350),
    Duration backupRateDelay = const Duration(milliseconds: 350),
    String? fromDate,
    String? toDate,
    bool force = false,
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
    if (force && fromDate == null && toDate == null) {
      throw ArgumentError('force 只能配合区间模式（fromDate/toDate）使用');
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
    // 日历是否来自降级的工作日候选：降级名单里混着节假日（永远拉不到行），
    // 缺口重试必须跳过，否则每个节假日白烧一次 tushare 配额。
    var calendarDegraded = false;
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
      calendarDegraded = true;
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
            // 已有行数的日期视为已补：重复回补不再白拉。天花板：某天只入库了部分
            // 股票（半截日）也整日跳过——新股/停牌使当日行数本就少于全市场，
            // 按行数占比判定会把这些日子当缺口年年重拉。
            for (final d in closedOpen)
              if ((fromDate == null || d.compareTo(fromDate) >= 0) &&
                  (toDate == null || d.compareTo(toDate) <= 0) &&
                  (force || _repo.rowCountOnDate(d) == 0))
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
    var failedSymbols = 0;
    var lastCompleted = -1; // targets 中最后一个成功入库的下标；-1 = 一个都没成
    try {
      for (var i = 0; i < targets.length; i++) {
        final d = targets[i];
        final dayRows =
            await _fetchDaily(d, tolerant: _hasPerStockSources);
        _repo.upsertBars(dayRows);
        rows += dayRows.length;
        onProgress?.call('$d ${dayRows.length} 行');
        lastCompleted = i;
        if (rateDelay > Duration.zero) await Future.delayed(rateDelay);
      }
    } on Exception {
      // 错误码与网络层异常（DNS/超时/连接被拒）都走逐股备源；备源为空才把异常抛给上层提示。
      final remaining = targets.sublist(lastCompleted + 1);
      final sources = _perStockSources(remaining.first);
      if (sources.isEmpty) rethrow;
      stderr.writeln(
          'tushare 日线不可用，按优先级降级：${sources.map((s) => s.$1).join(' → ')}');
      // 备源走独立限速：新浪没有 tushare 那种 50 次/分配额，逐股请求
      // 继承回补的 1.2s 间隔会把全程拖到 3 小时以上。
      final (backupRows, failed) =
          await _fillPerStock(remaining, sources, onProgress, backupRateDelay);
      rows += backupRows;
      failedSymbols = failed;
      if (!calendarDegraded) {
        rows += await _retryMissingDates(remaining, onProgress, rateDelay);
      }
    }
    if (needNameBackfill) {
      stderr.writeln('名单源均不可用，改用逐股行情回填名称（一次性，约 10 分钟）');
      await _backfillNames(onProgress);
    }
    return SyncResult(
        dates: targets.length,
        rows: rows,
        latestDate: _repo.maxTradeDate(),
        earliestDate: _repo.minTradeDate(),
        failedSymbols: failedSymbols);
  }

  bool get _hasPerStockSources => eastmoney != null || sina != null;

  /// 备源补数后仍有缺口的日期，回头用 tushare 逐日重试：新浪日K只有最近
  /// 400 根，长区间的早段它天然补不到。仅交易日历来自真实 trade_cal 时
  /// 才进来（降级候选混着节假日，那些日期永远没有行，重试纯烧配额）。
  /// 逐日查库跳过已补上的，幂等；tushare 仍不可用就放弃本轮剩余重试。
  Future<int> _retryMissingDates(
    List<String> dates,
    void Function(String msg)? onProgress,
    Duration rateDelay,
  ) async {
    var rows = 0;
    for (final d in dates) {
      if (_repo.rowCountOnDate(d) > 0) continue;
      try {
        final dayRows = await _fetchDaily(d, tolerant: true);
        _repo.upsertBars(dayRows);
        rows += dayRows.length;
        onProgress?.call('补齐 $d ${dayRows.length} 行');
      } on Exception catch (e) {
        stderr.writeln('补齐 $d 失败，放弃本轮 tushare 缺口重试：$e');
        break;
      }
      if (rateDelay > Duration.zero) await Future.delayed(rateDelay);
    }
    return rows;
  }

  /// 日线逐股备源链（按优先级）。东财在新浪之前：限速更宽松且无封 IP 前科、
  /// 一次请求全历史（新浪只有最近 400 根）、有真实成交额（新浪恒 0）、支持北交所。
  /// [minD]（区间下界，`YYYYMMDD`）只给东财用作请求起点，增量场景避免整段白拉。
  List<(String, Future<List<DailyRow>> Function(String symbol))>
      _perStockSources(String minD) => [
            if (eastmoney != null)
              ('东财', (sym) => eastmoney!.dailyBars(sym, beg: minD)),
            if (sina != null) ('新浪', (sym) => sina!.dailyBars(sym)),
          ];

  /// 逐股补数：遍历本地已有股票（空库时向东财要名单），
  /// 按优先级尝试各源——某源拉到数据即采用，无数据自动切下一源。单只失败跳过
  /// 但计数——返回值是 (入库行数, 失败只数)，失败只数随回执上报，
  /// 否则大面积失败照样显示"回补完成"，用户以为数据齐了。
  Future<(int, int)> _fillPerStock(
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
    // 降级链里每个源都会对同一批票再试一次，失败只数取各源的**最大值**：
    // 任一源的失败都代表"这些票这次没补上"。只记最后一个源的话，
    // 前面源全挂、最后源返回空数组时会报 0 只失败，用户以为数据齐了。
    var worstFailed = 0;
    for (final (label, fetch) in sources) {
      var done = 0;
      var failed = 0;
      var rows = 0;
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
          // 单只失败不影响整体（次日同步会按水位线自然补齐），但要计数上报。
          failed++;
        }
        done++;
        // 每 50 只报一次：200 只攒一条消息时，备源阶段会静默 5 分钟以上，
        // 界面看起来像卡死。
        if (done % 50 == 0) {
          onProgress?.call(
              '$label 备源 $done/${symbols.length}${failed > 0 ? '（$failed 只失败）' : ''}');
        }
        if (rateDelay > Duration.zero) await Future.delayed(rateDelay);
      }
      flush(); // 收尾：最后不足一批的也要落库
      if (rows > 0) {
        onProgress?.call(
            '$label 备源完成：$done 只，$rows 行${failed > 0 ? '，$failed 只失败' : ''}');
        return (rows, failed);
      }
      if (failed > worstFailed) worstFailed = failed;
      stderr.writeln('$label 备源无数据，降级下一源');
    }
    return (0, worstFailed);
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
    // 攒批入库：逐只 upsertStocks 是每只一次 BEGIN/COMMIT（一次 fsync），
    // 全市场 5000+ 只。凑满一批再写，单只结果不变，中断时已拿到的名字
    // 由 finally 落库（幂等，缺的下轮同步会再补）。
    final batch = <({String tsCode, String name})>[];
    void flush() {
      if (batch.isEmpty) return;
      _repo.upsertStocks(batch);
      batch.clear();
    }

    try {
      for (final sym in todo) {
        for (final fetch in fetchers) {
          try {
            final name = await fetch(sym);
            if (name != null && name.isNotEmpty) {
              batch.add((tsCode: sym, name: name));
              got++;
              break;
            }
          } catch (_) {
            // 该源这只失败，尝试下一源。
          }
        }
        done++;
        if (done % 500 == 0) onProgress?.call('名称回填 $done/${todo.length}');
        if (batch.length >= 200) flush();
        await Future.delayed(const Duration(milliseconds: 30));
      }
    } finally {
      flush();
    }
    onProgress?.call('名称回填完成：$got/${todo.length}');
  }
}
