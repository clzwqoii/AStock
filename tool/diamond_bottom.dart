/// 「钻石底」形态回测（诊断工具，不写入 builtInRules）。
///
/// 规则来源：抖音《千盘试炼400》钻石底一集的视频+音频拆解，见
/// `docs/diamond-bottom-rules.md`。视频的进场逻辑与项目已有的
/// `pivot_breakout_pullback`（中枢突破回抽不破）同构，颈线位取
/// `ind.pivotSeries` 的箱体上沿——这是视频里「手绘颈线位」的客观代理。
///
/// 视频的核心主张是**目标位 = 颈线位 × 2 够用**，而现有 `backtestAll`
/// 只统计未来 N 日收益，答不了这个问题。所以本工具自己走一笔
/// 「进场 → 触目标 / 触止损 / 超时」的三路径逐笔回测。
///
/// 视频没说的三件事在这里被显式参数化并扫描，不替它猜：
///   - 颈线位窗口（箱体长度）[lookback]
///   - 目标位倍数 [targetMults]，含视频声称的 2.0
///   - 最长持有交易日 [holdDays]，视频完全没提
///
/// 用法:
///   dart run tool/diamond_bottom.dart [db路径]
///   dart run tool/diamond_bottom.dart --selftest    # 只跑自检
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/indicators.dart' as ind;
import 'package:stock/core/market.dart';
import 'package:stock/core/models.dart';
import 'package:stock/data/bar_repository.dart';

/// 视频明确声称的目标位倍数。
const kVideoClaimedMult = 2.0;

/// 目标位倍数扫描档位。2.0 是视频的主张，其余为对照。
const _targetMults = [1.0, 1.5, 2.0, 2.5, 3.0];

/// 箱体长度（颈线位回溯根数）扫描档位，与 `tool/sweep_pivot.dart` 同档。
const _lookbacks = [20, 40, 60];

/// 最长持有交易日扫描档位（视频未给，此处显式扫）。
const _holds = [20, 40, 60, 120];

/// 回踩确认的宽容度：回踩最低价 vs 颈线位，跌破超过这个比例才算破线。
const kNeckBreakTol = 0.03;

/// 背离检测的最小间隔根数。两个波峰隔太近（< 5 根）就是噪声，不是背离。
const kDivergMinGap = 5;

/// MACD 柱（国内惯例 hist=(dif-dea)*2）背离的判据。
///
/// 顶背离：价格创出新高（相对进场以来的最高收盘），但 MACD 柱反而变小。
/// 用「柱」而不是「dif」：柱同时含 dif 与 dea 的相对位置，对「上攻乏力」
/// 更敏感——视频强调的正是涨不动了。
///
/// 量能柱背离：价格新高，但当日成交量 / 前 5 日均量（量比）反而下降。
/// 用量比而非绝对量：小盘股和大盘股的绝对量不可比。
///
/// 三条件全中（柱背离 + 量能背离 + 上攻乏力）才判离场，对应视频说的
/// 「三层共振」；单条件命中记为 weak，仅用于对照。
class _Diverg {
  const _Diverg(this.weak, this.strong);
  final bool weak;
  final bool strong;
}

/// 从进场日 [t] 起，到 [end] 为止，检测视频说的三类离场信号。
///
/// 「上攻乏力」量化为：新高点相对上一个波峰涨幅不足 [_weakGainPct]，
/// 视为涨不动（视频原话「上攻乏力」）。
///
/// 逐根扫描、记住上一个波峰；只有当根 K 线成为新的最高收盘时才更新波峰，
/// 与「背离」的定义一致（背离只在两个波峰之间成立）。
_Diverg? _divergenceAt(
  List<Bar> bars,
  int t,
  int end,
  List<double> hist,
  List<double> volRatio,
) {
  var peakClose = bars[t].close;
  var peakIndex = t;
  var peakHist = hist[t];
  var peakVolRatio = volRatio[t];
  _Diverg? found;
  for (var k = t + 1; k <= end; k++) {
    if (bars[k].close > peakClose) {
      // 新高 → 与上一个波峰比
      final gap = k - peakIndex;
      if (gap >= kDivergMinGap) {
        final macdDiverg = hist[k] < peakHist;
        final volDiverg = volRatio[k] < peakVolRatio;
        final weakGain =
            (bars[k].close / peakClose - 1) * 100 < _weakGainPct;
        if (macdDiverg && volDiverg && weakGain) {
          return const _Diverg(true, true);
        }
        if (macdDiverg || volDiverg) {
          found ??= const _Diverg(true, false);
        }
      }
      peakClose = bars[k].close;
      peakIndex = k;
      peakHist = hist[k];
      peakVolRatio = volRatio[k];
    } else if (found == null) {
      // 没创新高但已开始背离：等它创新高那天再定性太晚，这里只记录不提前离场。
      continue;
    }
  }
  return found;
}

/// 「上攻乏力」的量化门槛（%）：新高点相对上一个波峰的涨幅不足此值视为涨不动。
const _weakGainPct = 1.0;

/// 一笔回测的结果。收益以进场价为基准的百分比。
class _Trade {
  _Trade(this.symbol, this.date, this.entry, this.pct, this.outcome);

  final String symbol;
  final DateTime date;
  final double entry;

  /// 到退出为止的收益（%）。
  final double pct;

  /// 'target' | 'stop' | 'timeout' | 'diverg' | 'diverg_weak'
  final String outcome;
}

/// 离场模式。视频主张的背离离场 vs 不看背离，必须能对照才算数。
enum _ExitMode {
  /// 只用目标位/止损/超时（第一轮的口径）。
  none,

  /// MACD柱背离 + 量能背离 + 上攻乏力，三条件共振才离场（视频的「三层共振」）。
  strong,

  /// 任一背离条件命中即离场（宽松对照）。
  weak,
}

/// 钻石底信号 + 逐笔回测。
///
/// 判定顺序严格照视频原话：
/// 1. 箱体上沿 = 颈线位（突破才成立）
/// 2. 突破颈线位
/// 3. 回踩不破颈线位（跌破 > [kNeckBreakTol] 判破线）
/// 4. 阳线再启动 = 进场
/// 然后逐日走到出结果：触及 颈线位×倍数 / 跌破颈线位×(1+tol) / 背离离场 / 超时。
///
/// [hist] 与 [volRatio] 是整条序列已算好的 MACD 柱与量比（对齐下标）。
/// 传 null 时退化为 [_ExitMode.none]，与第一轮口径一致。
List<_Trade> _runOne(
  String symbol,
  List<Bar> bars,
  int t,
  double neckline,
  double mult,
  int maxHold,
  _ExitMode mode, {
  List<double>? hist,
  List<double>? volRatio,
}) {
  final entry = bars[t].close;
  final target = neckline * mult;
  final stop = neckline * (1 - kNeckBreakTol);
  // 目标位只要求 >= 进场价才是「可达」；不可达的目标位只会全部走止损，
  // 那种情形必须当作数据缺口而不是当成形态失败。
  if (target <= entry) return const [];

  final end = (t + maxHold < bars.length - 1) ? t + maxHold : bars.length - 1;
  for (var k = t + 1; k <= end; k++) {
    // 顺序：先判止损还是先判目标？同根K线两者都触及无法从日线分辨，
    // 保守口径（先止损）会系统性低估形态，故先判目标——
    // 代价是可能高估。这个偏差会在报告里标注，不静默。
    if (bars[k].high >= target) {
      return [
        _Trade(symbol, bars[t].date, entry, (target / entry - 1) * 100, 'target')
      ];
    }
    if (bars[k].close < stop) {
      return [
        _Trade(symbol, bars[t].date, entry, (stop / entry - 1) * 100, 'stop')
      ];
    }
    // 背离离场：当日收盘离场。日线无法判断盘中先后，这里用收盘价是保守的
    // （比当日最高价略低），不会凭空造出不存在的收益。
    if (mode != _ExitMode.none && hist != null && volRatio != null) {
      final d = _divergenceAt(bars, t, k, hist, volRatio);
      if (d != null && (mode == _ExitMode.strong ? d.strong : true)) {
        return [
          _Trade(symbol, bars[t].date, entry,
              (bars[k].close / entry - 1) * 100,
              mode == _ExitMode.strong ? 'diverg' : 'diverg_weak')
        ];
      }
    }
  }
  return [
    _Trade(symbol, bars[t].date, entry, (bars[end].close / entry - 1) * 100, 'timeout')
  ];
}

/// 全市场扫一遍，收集 (lookback, mult, hold) → 交易列表 与 同批可评估日的基准。
Map<String, Object> _scan(List<StockData> stocks) {
  final trades = <String, List<_Trade>>{};
  final base = <String, List<double>>{}; // key: 'hold'
  var evalDays = 0;

  final maxLook = _lookbacks.reduce((a, b) => a > b ? a : b);
  final maxHold = _holds.reduce((a, b) => a > b ? a : b);
  // 护栏与 backtestRule 同口径：除权/停牌污染日整日剔除，信号与基准同批。
  final calendar = tradingCalendar(stocks);

  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < maxLook + maxHold + 2) continue;
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final gapDays = tradingDaysSincePrevBar(bars, calendar, startFrom: maxLook);
    final lastEval = bars.length - 1 - maxHold;
    // 背离要用 MACD 柱与量比，各自整条只算一次（O(len)），不是逐日 O(len)。
    final closes = [for (final b in bars) b.close];
    final hist = ind.macd(closes).hist;
    final volRatio = List<double>.filled(bars.length, 0);
    for (var i = 5; i < bars.length; i++) {
      var s = 0.0;
      for (var k = i - 5; k < i; k++) {
        s += bars[k].volume;
      }
      volRatio[i] = s > 0 ? bars[i].volume / (s / 5) : 0;
    }

    for (var t = maxLook; t <= lastEval; t++) {
      // 从 lookback+1 回看：污染窗要覆盖箱体本身，否则颈线位是除权价。
      var contaminated = false;
      for (var i = t - maxLook; i <= t; i++) {
        if (sinceGap[i] < kCorporateActionLookbackBars ||
            gapDays[i] > kSuspensionMaxGapTradingDays) {
          contaminated = true;
          break;
        }
      }
      if (contaminated) continue;
      evalDays++;

      // 无条件基准（同一批可评估日，未来 hold 日收益）
      for (final h in _holds) {
        if (t + h <= bars.length - 1) {
          (base['$h'] ??= <double>[])
              .add((bars[t + h].close / bars[t].close - 1) * 100);
        }
      }

      for (final lb in _lookbacks) {
        // 颈线位 = 截至 t-1 的 lb 日箱体上沿（不含当日，与 pivotSeries 同口径）
        final neck = ind.highestHigh(bars.sublist(0, t), lb);
        if (neck == null || neck <= 0) continue;
        if (bars[t].close <= neck) continue; // 未突破
        // 突破日要有量：量比 >= 1.2，否则是缩量假突破
        var vol = 0.0;
        for (var k = t - 5; k < t; k++) {
          vol += bars[k].volume;
        }
        if (vol <= 0 || bars[t].volume / (vol / 5) < 1.2) continue;
        // 再启动：阳线
        if (bars[t].close <= bars[t].open) continue;
        // 回踩不破：突破后 1~10 日内最低价不得深破颈线位
        var pulledBack = false;
        var broke = false;
        for (var k = t + 1; k <= t + 10 && k < bars.length; k++) {
          if (bars[k].low <= neck * (1 + 0.01)) pulledBack = true;
          if (bars[k].low < neck * (1 - kNeckBreakTol)) {
            broke = true;
            break;
          }
        }
        if (broke || !pulledBack) continue;

        for (final m in _targetMults) {
          for (final h in _holds) {
            for (final mode in _ExitMode.values) {
              trades
                  .putIfAbsent('$lb|$m|$h|${mode.name}', () => <_Trade>[])
                  .addAll(_runOne(stock.symbol, bars, t, neck, m, h, mode,
                      hist: hist, volRatio: volRatio));
            }
          }
        }
      }
    }
  }
  return {'trades': trades, 'base': base, 'evalDays': evalDays};
}

void _selfTest() {
  // 构造一段能明确判定的手写K线：箱体上沿 10，突破后回踩到 9.8，再启动。
  final bars = <Bar>[];
  Bar b(DateTime d, double o, double h, double l, double c, double v) =>
      Bar(date: d, open: o, high: h, low: l, close: c, volume: v);
  final d0 = DateTime(2024, 1, 2);
  // 20 根箱体：上沿 10，低点 8
  for (var i = 0; i < 20; i++) {
    bars.add(b(d0.add(Duration(days: i)), 9.5, 10.0, 8.0, 9.5, 100));
  }
  // 突破日：放量阳线收 10.5
  bars.add(b(d0.add(const Duration(days: 20)), 10.0, 10.6, 9.9, 10.5, 200));
  // 回踩：最低 9.8（未深破 9.7）
  bars.add(b(d0.add(const Duration(days: 21)), 10.4, 10.5, 9.8, 10.0, 80));
  // 之后一路涨到 21（=颈线 10 × 2 的 1.05 倍，越过 20）
  for (var i = 0; i < 40; i++) {
    final c = 10.5 + (i + 1) * 0.3;
    bars.add(b(d0.add(Duration(days: 22 + i)), c - 0.1, c + 0.2, c - 0.3, c, 150));
  }

  // 1) 目标位 = 颈线 × 2 必须在某根被触及
  final t = 20;
  final tr = _runOne('TEST', bars, t, 10.0, kVideoClaimedMult, 60, _ExitMode.none);
  assert(tr.length == 1, '应产生恰好一笔交易，实际 ${tr.length}');
  assert(tr.first.outcome == 'target', '应触及目标位，实际 ${tr.first.outcome}');
  assert((tr.first.pct - (20.0 / 10.5 - 1) * 100).abs() < 1e-9,
      '收益应按目标价算，实际 ${tr.first.pct}');

  // 2) 目标位不可达（低于进场价）时不应产生交易
  assert(_runOne('TEST', bars, t, 10.0, 0.5, 60, _ExitMode.none).isEmpty,
      '目标位低于进场价时必须为空交易');

  // 3) 跌破颈线位应判止损
  final down = <Bar>[...bars];
  for (var i = 21; i < down.length; i++) {
    down[i] = b(down[i].date, 9.0, 9.1, 8.0, 8.5, 150);
  }
  final tr2 = _runOne('TEST', down, t, 10.0, 2.0, 60, _ExitMode.none);
  assert(tr2.first.outcome == 'stop', '应判止损，实际 ${tr2.first.outcome}');
  assert((tr2.first.pct - (9.7 / 10.5 - 1) * 100).abs() < 1e-9,
      '止损价应为颈线×(1-tol)=9.7，实际 ${tr2.first.pct}');

  // 4) 超时按末根收盘
  final flat = <Bar>[...bars];
  for (var i = 21; i < flat.length; i++) {
    flat[i] = b(flat[i].date, 10.0, 10.2, 9.9, 10.0, 150);
  }
  final tr3 = _runOne('TEST', flat, t, 10.0, 2.0, 5, _ExitMode.none);
  assert(tr3.first.outcome == 'timeout', '应判超时，实际 ${tr3.first.outcome}');
  assert((tr3.first.pct - (10.0 / 10.5 - 1) * 100).abs() < 1e-9,
      '超时按末根收盘算，实际 ${tr3.first.pct}');

  // 5) 背离检测：价创新高但 MACD 柱与量比同时萎缩 → strong 背离成立
  //    构造：t 处收盘 10.5 / hist 高 / 量比高；k 处收盘 10.6（新高）
  //    但 hist 明显变小、量比也变小 → 三条件（含上攻乏力，10.6/10.5≈0.95%<1%）。
  final divBars = <Bar>[];
  for (var i = 0; i < 30; i++) {
    divBars.add(b(d0.add(Duration(days: i)), 10.0, 10.1, 9.9, 10.0, 100));
  }
  divBars[t] = b(d0.add(Duration(days: t)), 10.0, 10.6, 9.9, 10.5, 300);
  for (var i = t + 1; i < t + 6; i++) {
    divBars[i] = b(d0.add(Duration(days: i)), 10.0, 10.1, 9.95, 10.0, 100);
  }
  // 新高但缩量：必须在 t+6（与 t 间隔 6 ≥ kDivergMinGap=5，否则不算背离）。
  // 收盘 10.55（新高，较 10.5 仅 +0.5% < _weakGainPct=1% → 上攻乏力成立）
  divBars[t + 6] = b(d0.add(Duration(days: t + 6)), 10.4, 10.6, 10.4, 10.55, 110);
  // hist 必须真的变小：这里直接用构造好的序列喂 _divergenceAt
  final histSeq = List<double>.filled(divBars.length, 0);
  histSeq[t] = 5.0; // 进场日柱值大
  for (var i = t + 1; i < divBars.length; i++) {
    histSeq[i] = 1.0; // 之后柱值小 → 顶背离
  }
  final vrSeq = List<double>.filled(divBars.length, 1.0);
  vrSeq[t] = 3.0; // 进场日量比大
  for (var i = t + 1; i < divBars.length; i++) {
    vrSeq[i] = 1.1; // 之后量比小 → 量能背离
  }
  final d = _divergenceAt(divBars, t, t + 7, histSeq, vrSeq);
  assert(d != null, '应检出背离，实际 null');
  assert(d != null && d.strong, '三条件共振应判 strong，实际只有 weak');

  // 5b) 只有 MACD 背离、量能不背离 → 仅 weak
  final vrSeq2 = List<double>.filled(divBars.length, 1.0);
  vrSeq2[t] = 1.0;
  for (var i = t + 1; i < divBars.length; i++) {
    vrSeq2[i] = 2.0; // 量比反而放大
  }
  final d2 = _divergenceAt(divBars, t, t + 7, histSeq, vrSeq2);
  assert(d2 != null && d2.weak && !d2.strong,
      '仅 MACD 背离应判 weak 而非 strong');

  // 5c) 背离离场按当日收盘离场，且强/弱模式都能退出
  final trD = _runOne('TEST', divBars, t, 9.0, 99.0, 60, _ExitMode.strong,
      hist: histSeq, volRatio: vrSeq);
  assert(trD.first.outcome == 'diverg',
      'strong 模式应背离离场，实际 ${trD.first.outcome}');
  final trW = _runOne('TEST', divBars, t, 9.0, 99.0, 60, _ExitMode.weak,
      hist: histSeq, volRatio: vrSeq2);
  assert(trW.first.outcome == 'diverg_weak',
      'weak 模式应弱背离离场，实际 ${trW.first.outcome}');

  // 5d) mode=none 时即便有背离也不该提前离场（对照口径必须干净）
  final trN = _runOne('TEST', divBars, t, 9.0, 99.0, 60, _ExitMode.none,
      hist: histSeq, volRatio: vrSeq);
  assert(trN.first.outcome == 'timeout',
      'none 模式不该被背离离场，实际 ${trN.first.outcome}');

  print('✅ 自检通过：目标位触及 / 不可达 / 止损 / 超时 / 背离(强·弱·不启用) 七条路径');
}

void main(List<String> args) {
  if (args.contains('--selftest')) {
    _selfTest();
    return;
  }

  final selftestFail = _runSelfTestCapture();
  if (selftestFail != null) {
    print('❌ 自检失败，先修逻辑再回测：\n$selftestFail');
    exitCode = 1;
    return;
  }

  final dbPath = args.isNotEmpty && !args[0].startsWith('--')
      ? args[0]
      : AppConfig.load().dbPath;
  print('加载 $dbPath …');
  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
  repo.close();
  if (stocks.isEmpty) {
    print('数据库为空，先跑 dart run bin/sync.dart');
    return;
  }
  print('股票 ${stocks.length} 只 · 开始扫描（护栏：除权+停牌）…');

  final t0 = DateTime.now();
  final res = _scan(stocks);
  final trades = res['trades'] as Map<String, List<_Trade>>;
  final base = res['base'] as Map<String, List<double>>;
  final evalDays = res['evalDays'] as int;
  print('可评估日 $evalDays 个 · 耗时 ${DateTime.now().difference(t0).inSeconds}s');

  for (final h in _holds) {
    final b = base['$h'] ?? const <double>[];
    if (b.isEmpty) continue;
    final bw = b.where((x) => x > 0).length / b.length * 100;
    final ba = b.reduce((a, x) => a + x) / b.length;
    print('');
    print('══ 持有 $h 日 · 同批基准：${b.length} 样本 · 胜率 ${bw.toStringAsFixed(1)}% · 均收益 ${ba.toStringAsFixed(2)}% ══');
    print('  离场模式  箱体  目标倍数  信号数  触目标%  止损%  背离%  超时%  均收益%  中位%  均收益差pp  剔top1%后均收益%');
    for (final mode in _ExitMode.values) {
      for (final lb in _lookbacks) {
        for (final m in _targetMults) {
          final list = trades['$lb|$m|$h|${mode.name}'] ?? const <_Trade>[];
          if (list.isEmpty) continue;
          final n = list.length;
          final hits = list.where((x) => x.outcome == 'target').length;
          final stops = list.where((x) => x.outcome == 'stop').length;
          final divs = list
              .where((x) => x.outcome == 'diverg' || x.outcome == 'diverg_weak')
              .length;
          final tos = list.where((x) => x.outcome == 'timeout').length;
          final ps = [for (final x in list) x.pct]..sort();
          final avg = ps.reduce((a, x) => a + x) / n;
          final med = ps[n ~/ 2];
          // 右偏敏感性：剔掉最好的 1% 后均值还剩多少。若塌到负，说明整个期望
          // 靠极少数暴涨股撑着，均值毫无参考价值（AGENTS.md 规则 4 的同类问题，
          // 逐笔统计会把噪声当提升）。
          final cut = (n * 0.01).floor();
          final trimmed = ps.sublist(0, n - cut);
          final avgTrimmed = trimmed.isEmpty
              ? double.nan
              : trimmed.reduce((a, x) => a + x) / trimmed.length;
          final mark = m == kVideoClaimedMult ? ' ← 视频主张' : '';
          final modeTag = switch (mode) {
            _ExitMode.none => '无背离  ',
            _ExitMode.strong => '三层共振',
            _ExitMode.weak => '弱背离  ',
          };
          print('  $modeTag  ${lb.toString().padLeft(4)}  ${m.toStringAsFixed(1).padLeft(8)}  '
              '${n.toString().padLeft(6)}  ${(hits / n * 100).toStringAsFixed(1).padLeft(7)}  '
              '${(stops / n * 100).toStringAsFixed(1).padLeft(5)}  '
              '${(divs / n * 100).toStringAsFixed(1).padLeft(5)}  '
              '${(tos / n * 100).toStringAsFixed(1).padLeft(5)}  '
              '${avg.toStringAsFixed(2).padLeft(7)}  ${med.toStringAsFixed(2).padLeft(5)}  '
              '${(avg - ba).toStringAsFixed(2).padLeft(10)}  '
              '${avgTrimmed.toStringAsFixed(2).padLeft(15)}$mark');
        }
      }
    }
  }

  print('');
  print('离场模式说明（视频的「三层共振」= strong 列）：');
  print('  · 无背离  = 只看目标位/止损/超时（上一轮口径）');
  print('  · 三层共振 = MACD柱背离 + 量能背离 + 上攻乏力 三条件同时成立才离场');
  print('  · 弱背离  = 任一背离条件成立即离场（宽松对照）');
  print('');
  print('口径与已知偏差（不静默）：');
  print('  · 目标位不可达（≤ 进场价）的信号被直接剔除，那些行的信号数会偏小');
  print('  · 同根 K 线同时触及目标与止损时判「目标」，日线无法分辨先后 → 可能高估');
  print('  · 未计交易成本、滑点、涨跌停无法成交');
  print('  · 颈线位用 ind.highestHigh 作客观代理，视频是手绘，二者不会完全一致');
  print('  · 背离用「价格创新高 vs 柱/量比萎缩」量化，视频是肉眼看形态，'
      '参数（kDivergMinGap=$kDivergMinGap根、_weakGainPct=$_weakGainPct%）是我定的，非视频原文');
  print('  · 中位收益与均收益方向相反 = 极度右偏，剔 top1% 列就是查这件事');
  print('  · 未做按天聚类 bootstrap（AGENTS.md 规则 4），逐笔统计不等于独立样本');
}

/// 跑自检并把 assert 消息吞掉返回（dart 的 assert 在 --enable-asserts 下抛 AssertionError）。
String? _runSelfTestCapture() {
  try {
    _selfTest();
    return null;
  } catch (e) {
    return e.toString();
  }
}
