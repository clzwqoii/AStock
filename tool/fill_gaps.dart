/// 历史 K 线缺口补齐：按"该股确实少了的那一天"定向补，不整段重拉。
///
/// ## 为什么需要它
///
/// `IndicatorSeries` 把**相邻的两根 K 线当成相邻的两个交易日**。库里缺一根，
/// 后面的 MA/RSI/KDJ 全都跨着缺口算——等于把"三天前"当成"昨天"。实测 2026-10-06
/// 补齐了一部分历史缺口后，主规则 10 日胜率从 80.30% 变成 72.85%，就是因为原先
/// 跨缺口算出来的假信号消失了。**指标要正确，前提是序列里没有洞。**
///
/// ## 怎么判定"缺"
///
/// 交易日历取"行数 ≥ [kCalendarMinRows] 的日期"（整市场都在交易的日子），
/// 再对每只股票看它**自己的首末根之间**少了多少个交易日。只统计内部缺口，
/// 首根之前/末根之后不算（未上市、已退市）。
///
/// ## 为什么必须用 tushare 按日补，而不是相信缺口清单
///
/// 缺口里混着大量**真实停牌**：未按期披露年报的股票每年 4/30 起被停牌，
/// 实测 2024/2025/2026 三个 4 月底各缺 48~59 只，那不是数据缺失，是没交易。
/// tushare 的 daily 接口只返回当天**真的交易了**的股票，所以按日拉取是自校验的：
/// 返回里没有的票，就是当天没交易，我们不会凭空造一行。
/// 补齐后仍然缺的，就是真实停牌——工具会单独列出来，不当成失败。
///
/// ## 用法
///
///   dart run tool/fill_gaps.dart [--db 路径] [--min-stocks 1] [--max-requests 200]
///   dart run tool/fill_gaps.dart --dry-run      # 只看缺口清单，不请求
///
/// [--min-stocks N] 只补"当天缺 ≥N 只股票"的日期（默认 1 = 全补）。
/// [--max-requests] 单次运行最多请求多少个日期，便于分批（限频 50 次/分）。
/// 幂等：重复跑只会补还没补上的，已存在的行走 upsert。
library;

// ignore_for_file: avoid_print

import 'package:stock/config.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/tushare_client.dart';

/// 判定"这是整市场都在交易的交易日"的行数下限。
/// 实测 2024+ 的正常日期行数 5301~5561，停牌股也让单日掉不到 4000 以下。
const kCalendarMinRows = 4000;

Future<void> main(List<String> args) async {
  var dbPath = AppConfig.load().dbPath;
  var minStocks = 1;
  var maxRequests = 200;
  var dryRun = false;
  List<String> only = const [];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db':
        dbPath = args[++i];
      case '--min-stocks':
        minStocks = int.parse(args[++i]);
      case '--max-requests':
        maxRequests = int.parse(args[++i]);
      case '--dry-run':
        dryRun = true;
      case '--only':
        only = args[++i].split(',').where((e) => e.isNotEmpty).toList();
      default:
        throw ArgumentError('未知参数 ${args[i]}');
    }
  }

  final token = AppConfig.load().tushareToken;
  final repo = BarRepository(dbPath);
  final before = _gapReport(repo);
  print('库=$dbPath');
  print('交易日历 ${before.dates.length} 天（${before.dates.first} ~ ${before.dates.last}）');
  print('有内部缺口的股票 ${before.stocksWithGaps} 只，缺失 ${before.missingBars} 根，'
      '分布在 ${before.datesWithGaps} 个交易日');

  // 缺口最集中的日期——通常是同步断档，最值得先补
  final worst = before.perDate.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('缺口最大的日期：'
      '${worst.take(8).map((e) => '${e.key}(${e.value}只)').join(' ')}');

  final targets = only.isNotEmpty
      ? (only.toList()..sort())
      : (worst.where((e) => e.value >= minStocks).map((e) => e.key).toList()..sort());
  if (dryRun) {
    print('\n--dry-run：不请求。将请求 ${targets.length} 个日期'
        '（受 --max-requests=$maxRequests 限制时实际 ${targets.length < maxRequests ? targets.length : maxRequests} 个）');
    repo.close();
    return;
  }
  if (targets.isEmpty) {
    print('\n没有需要补的日期。');
    repo.close();
    return;
  }

  final client = TushareClient(token: token);
  final batch = targets.take(maxRequests).toList();
  print('\n开始补齐 ${batch.length} 个日期（限频 50 次/分，40203 会自动等 65s 重试）…');
  var filled = 0, requests = 0, noNewRows = 0;
  final sw = Stopwatch()..start();
  for (final date in batch) {
    try {
      final rows = await client.daily(tradeDate: date);
      requests++;
      if (rows.isEmpty) {
        noNewRows++;
        continue;
      }
      // 只 upsert 这个日期缺的股票？不必——upsert 幂等，整日写入还顺带修正
      // 可能的脏值。写入前按缺失清单过滤可以少写，但会漏掉"有行但值错"的情况。
      // 真实新增行数要用库的前后计数，不能用 tushare 的返回行数——
      // 那个日期大概率早就拉过了，返回 5300 行只新增一两行。
      final nBefore = repo.rowCountOnDate(date);
      repo.upsertBars(rows);
      final added = repo.rowCountOnDate(date) - nBefore;
      filled += added.toInt();
      if (added == 0) noNewRows++;
    } on TushareException catch (e) {
      print('  ✗ $date: ${e.message}');
    }
    if (requests % 25 == 0) {
      print('  …已请求 $requests/${batch.length}，写入 $filled 行，'
          '耗时 ${sw.elapsed.inMinutes} 分 ${sw.elapsed.inSeconds % 60} 秒');
    }
  }
  repo.close();
  print('\n本次：请求 $requests 个日期，**新增** $filled 行；'
      '$noNewRows 个日期一行都没补上（tushare 当天返回里没有我们缺的那些股票）');
  print('  参考：tushare 每个交易日返回约 5300 行，"请求数"不等于"新增行数"。');

  final after = _gapReport(BarRepository(dbPath));
  print('补齐后：有内部缺口 ${after.stocksWithGaps} 只 / 缺 ${after.missingBars} 根'
      '（补前 ${before.stocksWithGaps} 只 / ${before.missingBars} 根）');
  if (after.missingBars > 0) {
    print('剩余缺口多为真实停牌（tushare 当天无该股行）。若仍怀疑是断档，'
        '再跑一次本工具即可——幂等。');
  }
  print('\n⚠ 历史 K 线变了，指标与回测统计全部位移，必须按序重算：');
  print('  dart run tool/report_all.dart --archive   # 报告 + 台账');
  print('  dart run tool/train_score.dart            # 评分模型（必须在报告之后）');
}

/// 一次缺口体检的结果。
class _GapReport {
  _GapReport({
    required this.dates,
    required this.stocksWithGaps,
    required this.missingBars,
    required this.perDate,
  });

  final List<String> dates;
  final int stocksWithGaps;
  final int missingBars;

  /// 日期 → 该日缺几只股票。
  final Map<String, int> perDate;

  int get datesWithGaps => perDate.length;
}

_GapReport _gapReport(BarRepository repo) {
  final stocks = repo.loadAllStocks();
  final perDate = <String, int>{};
  var missing = 0, withGaps = 0;
  // 交易日历来自全市场：某一天的行数达到阈值就认为是大家都在交易的日子
  final countByDate = <String, int>{};
  for (final s in stocks) {
    for (final b in s.bars) {
      final key = _ymd(b.date);
      countByDate[key] = (countByDate[key] ?? 0) + 1;
    }
  }
  final cal = countByDate.entries.where((e) => e.value >= kCalendarMinRows).map((e) => e.key).toList()
    ..sort();
  final calIndex = {for (var i = 0; i < cal.length; i++) cal[i]: i};
  for (final s in stocks) {
    if (s.bars.isEmpty) continue;
    final have = {for (final b in s.bars) _ymd(b.date)};
    final lo = calIndex[_ymd(s.bars.first.date)], hi = calIndex[_ymd(s.bars.last.date)];
    if (lo == null || hi == null) continue;
    var gaps = 0;
    for (var i = lo; i <= hi; i++) {
      if (!have.contains(cal[i])) {
        gaps++;
        perDate[cal[i]] = (perDate[cal[i]] ?? 0) + 1;
      }
    }
    if (gaps > 0) {
      withGaps++;
      missing += gaps;
    }
  }
  return _GapReport(
    dates: cal,
    stocksWithGaps: withGaps,
    missingBars: missing,
    perDate: perDate,
  );
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';
