/// 探针：最近 ~120 交易日窗口里,各规则有没有统计功效、"谁的超额为正"。
///
/// 回答三个问题(实现「最近半年规则对比」前的实证依据):
///
/// 1. **功效**:每条规则窗口内信号数、独立信号日数。按天聚类 bootstrap 的
///    重抽单位是交易日,独立日太少(经验阈值 < 20)的规则谈不上"谁更好"。
/// 2. **方向与显著性**:窗口内日均超额(相对无条件基准,按日配对)+ 按天重抽
///    200 轮的 95% CI。CI 下界 > 0 才算"显著为正",其余只是描述。
/// 3. **对账**:自算等权指数的窗口涨跌幅与官方市值加权指数(公开数据,人工查)
///    方向应当一致;幅度不同是口径差异(等权 vs 加权),不是错误。
///
/// 用法: dart run tool/probe_recent_window.dart [dbPath] [窗口交易日数=120]
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  final window = args.length > 1 ? int.parse(args[1]) : 120;

  final repo = BarRepository(dbPath);
  try {
    final stocks = repo.loadAllStocks();
    print('库 $dbPath:${stocks.length} 只;窗口 = 最近 $window 个交易日。');
    final watch = Stopwatch()..start();
    final report = backtestAll(
      stocks,
      builtInRules,
      horizons: kDefaultHorizons,
      recentWindowTradingDays: window,
    );
    print('backtestAll 耗时 ${watch.elapsedMilliseconds / 1000.0}s');

    final h = kDefaultHorizons.length >= 2 ? kDefaultHorizons[1] : kDefaultHorizons.last;
    final base = report.recentBaseline[h];
    if (base == null || base.dayMeanReturn.isEmpty) {
      print('窗口内没有可评估日(库太新?),无法比较。');
      exit(0);
    }
    print('');
    print('══ 市场状态(等权自算,对账见文末)══');
    final ms = report.marketState!;
    print('  截至 ${ms.asOfDate};判定 ${ms.regime.label};'
        'MA偏离 ${ms.maGap.toStringAsFixed(2)}%,'
        '近20日 ${ms.ret20.toStringAsFixed(2)}%,'
        '站上MA20 ${(ms.breadthAboveMa20 * 100).toStringAsFixed(1)}%,'
        '新高−新低 ${(ms.newHighLowDiff20 * 100).toStringAsFixed(1)}pp');
    print('  等权基准窗口内:${base.dayMeanReturn.length} 天,'
        '10日均收 ${base.avgReturn.toStringAsFixed(3)}%,'
        '胜率 ${(base.winRate * 100).toStringAsFixed(1)}%');
    print('');
    print('══ 各规则窗口表现(持有 $h 日;按日均超额降序)══');
    print('  ${'规则'.padRight(24)}${'信号'.padLeft(7)}${'独立日'.padLeft(6)}'
        '${'超额pp'.padLeft(8)}${'CI下界'.padLeft(8)}${'CI上界'.padLeft(8)}  显著?');
    final rows = <(String, int, int, double, double, double)>[];
    for (final rule in builtInRules) {
      final slice = report.recent[rule.id]?[h];
      if (slice == null || slice.dayMeanReturn.isEmpty) {
        rows.add((rule.name, 0, 0, 0, 0, 0));
        continue;
      }
      final ci = recentExcessCI(
        ruleDayMean: slice.dayMeanReturn,
        baseDayMean: base.dayMeanReturn,
        seed: 7, // 固定种子:两次运行的 CI 必须逐位一致,否则没法对账
      );
      rows.add((
        rule.name,
        slice.count,
        slice.dayMeanReturn.length,
        ci.excess,
        ci.ciLow,
        ci.ciHigh,
      ));
    }
    rows.sort((a, b) => b.$4.compareTo(a.$4));
    for (final (name, cnt, days, ex, lo, hi) in rows) {
      // 三态,与回测页超额列的颜色语义一致:
      // ✓ 显著为正(lo>0) / ▼ 显著为负(hi<0) / 其余不显著;独立日不足单独标。
      final sig = days < 20
          ? '日数不足'
          : lo > 0
              ? '✓ 显著为正'
              : hi < 0
                  ? '▼ 显著为负'
                  : '不显著';
      print('  ${name.padRight(24)}${cnt.toString().padLeft(7)}'
          '${days.toString().padLeft(6)}${ex.toStringAsFixed(2).padLeft(8)}'
          '${lo.toStringAsFixed(2).padLeft(8)}${hi.toStringAsFixed(2).padLeft(8)}'
          '  $sig');
    }

    print('');
    print('══ 对账(人工比对,不进链路)══');
    // 等权窗口全段涨跌:每只股票窗口首末收盘比的等权平均。
    final calendar = tradingCalendar(stocks).toList()..sort();
    final cutoff = calendar.length > window
        ? calendar[calendar.length - window]
        : calendar.first;
    var n = 0;
    var sumRet = 0.0;
    for (final s in stocks) {
      if (s.bars.first.date.isAfter(cutoff) || s.bars.length < 2) continue;
      Bar? start;
      for (final b in s.bars) {
        if (b.date.isBefore(cutoff) || b.date == cutoff) {
          start = b;
        } else {
          break;
        }
      }
      if (start == null || start.close <= 0) continue;
      sumRet += (s.bars.last.close / start.close - 1) * 100;
      n++;
    }
    if (n > 0) {
      print('  自算等权指数窗口($window 个交易日,$n 只)全段涨跌 '
          '${(sumRet / n).toStringAsFixed(2)}%;近 20 日 ${ms.ret20.toStringAsFixed(2)}%。');
    }
    print('  请与公开指数同区间涨跌比对方向(等权与市值加权幅度不同属正常):');
    print('  例如中证全指/万得全A(贴近等权口径)、上证指数(市值加权,仅看方向)。');
    exit(0);
  } finally {
    repo.close();
  }
}
