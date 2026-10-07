/// 选股规则引擎：指标快照、规则与内置规则目录。
library;

import 'indicators.dart' as ind;
import 'models.dart';

// ── 60 日线「有效突破」阈值 ──────────────────────────────────────
// 数值口径来自业内共识（突破幅度 / 站稳天数 / 量能配合 / 乖离上限），
// 全部抽成常量便于单测与上线后按实际命中数回调。

/// 突破事件回溯天数（有效突破）：突破日距信号日最多这么多天。
const breakoutLookbackDays = 5;

/// 突破前「已在 MA60 下方盘整」的考察天数。
const kPreBreakoutCheckDays = 5;

/// 突破前考察窗口内，至少要有这么多日收盘在线下。
/// 用来区分「首次有效突破」和「高位反复穿越」——后者前期已在线上，不算新突破。
const kPreBreakoutMinBelow = 4;

/// 有效突破要求的最少站稳天数：突破日距信号日至少这么多天。
const kBreakoutStandDays = 3;

/// 突破日最低乖离率（%）。低于此视为只是蹭到均线，不算突破。
const kBreakoutMinPct = 3.0;

/// 信号日最高乖离率（%）。高于此视为追高，短期回调压力过大。
const kBreakoutMaxBiasPct = 15.0;

/// 站稳期 / 回踩期允许的最多下穿幅度（相对当日 MA60）。
const kBreakoutDeepBreakTol = 0.02;

/// 突破日量比下限。缩量突破大多是假突破。
const kBreakoutMinVolumeRatio = 1.5;

/// 突破日量比上限。骤然天量多为一轮脉冲或对倒，后续容易衰竭。
const kBreakoutMaxVolumeRatio = 6.0;

/// 突破日成交额比下限。量价须同向放大，只放量不放额可疑。
const kBreakoutMinAmountRatio = 1.5;

/// 突破日 / 再启动日收盘位置下限 (close−low)/(high−low)。
/// 收盘位于当日振幅上半部 = 当日主动性买盘占优，是资金流入的 OHLCV 代理。
const kBreakoutMinClosePos = 0.5;

/// 有效突破（站稳）是否要求完整多头排列 MA5>MA10>MA20>MA60。
const bullAlignmentRequired = true;

/// 有效突破窗口长度 = 突破事件回溯 5 日 + 突破前考察 5 日 + 突破日本身 1 日。
const breakoutWindowLength = breakoutLookbackDays + kPreBreakoutCheckDays + 1;

/// 有效突破（站稳）规则所需最少 K 线根数：窗口起点还要能算出 MA60。
const breakoutMinBars = 60 + breakoutWindowLength - 1;

/// 突破回踩确认：突破日距信号日的最少天数。
/// 取 [kBreakoutStandDays] + 2（至少两日回踩）+ 1（再启动日本身）：
/// 少于这个天数就不存在完整的「站稳 → 回踩 → 再启动」三段。
const kPullbackMinGapDays = kBreakoutStandDays + 3;

/// 突破回踩确认：最低价落在 MA60 上方这个幅度内，才算「真的踩到了线」。
/// 回踩始终在均线上方较高位置浅幅整理，不构成有效回踩确认。
const kPullbackTouchTol = 0.03;

/// 突破回踩确认：回踩段最大日成交量 ≤ 突破日成交量 × 此值，即「回踩不再放量」。
/// 实测 0.8（严格缩量）过严：全市场 5586 只只有 1 只命中；放到 1.0 为 3 只。
const kPullbackShrinkMax = 1.0;

/// 突破回踩确认：信号日收盘须创出「近 N 日新高」（不含本事），即越过整理平台。
/// 不用「突破后的最高收盘」——强势股站稳段本身会创出高点，要求立刻创新高过强。
const kPullbackNewHighDays = 5;

/// 突破回踩确认窗口长度：覆盖「突破 → 站稳 → 缩量回踩 → 再启动」全过程。
const pullbackWindowLength = 20;

/// 突破回踩确认规则所需最少 K 线根数。
const pullbackMinBars = 60 + pullbackWindowLength - 1;

/// 突破回踩确认是否要求完整多头排列。
/// 置 false：真回踩必然把 MA5 打到 MA10 下方（实测形态末态 MA5 20.82 < MA10 20.92），
/// 若要求多头排列，「突破→回踩→再启动」这个形态会结构性不可能成立。
/// 改用 MA20 > MA60 判断能扛住回踩的中期趋势。
const pullbackBullAlignmentRequired = false;

/// 有效突破判定所需的近端日线切片。
/// 各列表等长、按时间升序。
///
/// 用固定窗口而不是在 [IndicatorSnapshot] 里平铺几十个 prevXxx 字段：
/// 突破 / 站稳 / 回踩 / 再启动都要看"前后若干天"的关系，平铺无法表达。
class BreakoutWindow {
  const BreakoutWindow({
    required this.opens,
    required this.closes,
    required this.lows,
    required this.volumes,
    required this.volumeRatios,
    required this.amountRatios,
    required this.closePoses,
    required this.ma60,
  });

  final List<double> opens;
  final List<double> closes;
  final List<double> lows;
  final List<double> volumes;

  /// 逐日量比（当日量 / 前 5 日均量）。
  final List<double> volumeRatios;

  /// 逐日成交额比；旧数据 amount 为 0 的日期为 0。
  final List<double> amountRatios;

  /// 逐日收盘位置。
  final List<double> closePoses;

  /// 与 [closes] 对齐的 MA60 序列。
  final List<double?> ma60;

  int get length => closes.length;

  /// 窗口内最近一次 MA60 上穿的下标（prevClose ≤ prevMA60 且 close > MA60）；无则 −1。
  int get crossUpIndex {
    for (var i = length - 1; i >= 1; i--) {
      final m = ma60[i], pm = ma60[i - 1];
      if (m == null || pm == null) continue;
      if (closes[i - 1] <= pm && closes[i] > m) return i;
    }
    return -1;
  }

  /// 取「以 [end] 为最后一天、长度 [length]」的窗口。
  ///
  /// [ma60] 必须与 [bars] 等长（`ma60[i]` = `bars[i]` 处的 MA60）——由调用方传入已算好的
  /// 序列，避免每天重算整条（回测逐日评规则时这是 O(n²) 与 O(n) 的差别）。
  /// `end + 1 < 60 + length − 1`（窗口起点算不出 MA60）时返回 null。
  static BreakoutWindow? endingAt(List<Bar> bars, List<double?> ma60, int end, int length) {
    if (length <= 0) throw ArgumentError('length 必须为正，实际 $length');
    if (bars.length != ma60.length) {
      throw ArgumentError('bars 与 ma60 必须等长，实际 ${bars.length} / ${ma60.length}');
    }
    if (end < 0 || end >= bars.length) {
      throw RangeError.value(end, 'end', '日线下标越界');
    }
    if (end < 58 + length) return null; // end+1 < 60+length-1
    final from = end - length + 1;
    return BreakoutWindow(
      opens: [for (var i = from; i <= end; i++) bars[i].open],
      closes: [for (var i = from; i <= end; i++) bars[i].close],
      lows: [for (var i = from; i <= end; i++) bars[i].low],
      volumes: [for (var i = from; i <= end; i++) bars[i].volume],
      // 顶层函数引用（编译期常量）而非内联闭包：回测逐日评规则时这个窗口
      // 按日构造，内联闭包每次都要分配一个对象。
      volumeRatios: [for (var i = from; i <= end; i++) ratioOf(bars, i, _barVolume)],
      amountRatios: [for (var i = from; i <= end; i++) ratioOf(bars, i, _barAmount)],
      closePoses: [for (var i = from; i <= end; i++) ind.closePos(bars[i])],
      ma60: [for (var i = from; i <= end; i++) ma60[i]],
    );
  }

  /// [bars[i]] 的取值 / 前 5 日均值。旧数据（amount 为 0）或分母为 0 时返回 0。
  /// 与 `ind.volumeRatio` / `ind.amountRatio` 同口径，只是按下标取、不重建子列表。
  static double ratioOf(List<Bar> bars, int i, double Function(Bar) pick) {
    if (i < 5) return 0;
    final cur = pick(bars[i]);
    if (cur <= 0) return 0;
    var sum = 0.0;
    for (var k = i - 5; k < i; k++) {
      sum += pick(bars[k]);
    }
    final avg = sum / 5;
    if (avg <= 0) return 0;
    return cur / avg;
  }
}

/// 某只股票最近一日的指标快照，含规则所需的前一日值（用于金叉/上穿判断）。
class IndicatorSnapshot {
  IndicatorSnapshot._({
    required this.close,
    required this.prevClose,
    required this.ma5,
    required this.prevMa5,
    required this.ma10,
    required this.prevMa10,
    required this.ma20,
    required this.dif,
    required this.prevDif,
    required this.dea,
    required this.prevDea,
    required this.k,
    required this.prevK,
    required this.d,
    required this.prevD,
    required this.j,
    required this.rsi14,
    required this.volumeRatio,
    required this.pctChange,
    required this.ma60,
    required this.prevMa60,
    required this.ma60Trend5,
    required this.bias60,
    required this.ma250,
    required this.ma250Trend5,
    required this.bias250,
    required this.amountRatio,
    required this.closePos,
    required this.bullAlignment,
    required this.series,
    required this.t,
  });

  /// 快照所需的完整历史：MA20 需 20 根，前一日 MA5/MA10 需 11 根。
  /// MA60 族字段可空，历史不足时规则自行不命中，不影响其它规则。
  static const minBars = 20;

  final double close;

  /// 前一日收盘价（MA60 上穿判断用）。
  final double prevClose;
  final double ma5;
  final double prevMa5;
  final double ma10;
  final double prevMa10;
  final double ma20;
  final double dif;
  final double prevDif;
  final double dea;
  final double prevDea;

  /// KDJ(9,3,3)：K/D 用于金叉死叉判断，J 用于超买超卖。
  final double k;
  final double prevK;
  final double d;
  final double prevD;
  final double j;
  final double rsi14;
  final double volumeRatio;
  final double pctChange;

  /// MA60；历史不足 61 根时为 null。
  final double? ma60;

  /// 前一日 MA60。
  final double? prevMa60;

  /// MA60 最近 5 日的变化量（元）；≥0 表示走平或上翘。
  final double? ma60Trend5;

  /// 收盘价相对 MA60 的乖离率（%）。
  final double? bias60;

  /// MA250（年线）；历史不足 250 根时为 null。
  final double? ma250;

  /// MA250 最近 5 日的变化量（元）；≥0 表示年线走平或上翘。
  final double? ma250Trend5;

  /// 收盘价相对 MA250 的乖离率（%）。正值 = 站在年线上方。
  final double? bias250;

  /// 当日成交额 / 前 5 日均额；旧数据 amount 为 0 时为 0。
  final double amountRatio;

  /// 当日收盘价在当日振幅中的位置（0~1）；一字板取 0.5。
  final double closePos;

  /// MA5>MA10>MA20>MA60 是否成立（只比较末日）。
  final bool bullAlignment;

  /// 构造三个窗口所需的上下文。
  ///
  /// 刻意存**引用与下标**而不是 `() => ...endingAt(...)` 闭包：快照在回测里
  /// 按日构造（全市场 336 万个），闭包方案每快照要分配 3 个捕获
  /// (bars/ma60/pivot/t) 的闭包对象，合计约 1000 万次分配。
  final IndicatorSeries series;
  final int t;

  /// 有效突破（突破并站稳）窗口；历史不足 [breakoutMinBars] 根时为 null。
  /// 惰性构建：内置规则只有少数几条看窗口，且回测逐日评估时绝大多数日
  /// 在标量条件上就短路——急切构建两个窗口约占逐日快照成本的九成。
  late final BreakoutWindow? window =
      BreakoutWindow.endingAt(series.bars, series.ma60, t, breakoutWindowLength);

  /// 突破回踩确认窗口；历史不足 [pullbackMinBars] 根时为 null。
  late final BreakoutWindow? pullbackWindow =
      BreakoutWindow.endingAt(series.bars, series.ma60, t, pullbackWindowLength);

  /// 中枢突破窗口；历史不足时规则不命中。
  late final PivotWindow? pivotWindow =
      PivotWindow.endingAt(series.bars, series.pivot, t, kPivotPullbackWindowLength);

  factory IndicatorSnapshot.fromStock(StockData stock) {
    final bars = stock.bars;
    if (bars.length < minBars) {
      throw StateError('${stock.symbol} 历史不足 $minBars 根，实际 ${bars.length}');
    }
    // 选股（末日快照）与回测（逐日快照）走同一套构造，两路指标口径不会分叉。
    return IndicatorSeries.from(bars).at(bars.length - 1);
  }
}

/// [BreakoutWindow.ratioOf] 的取值函数。顶层函数引用是编译期常量，
/// 避免逐日快照里每次分配 `(b) => b.amount` 闭包。
double _barAmount(Bar b) => b.amount;

/// [BreakoutWindow.ratioOf] 的成交量取值函数。同样用顶层引用（编译期常量、
/// 不分配闭包）——窗口在回测里按日构造，内联闭包每次都要分配一个对象。
double _barVolume(Bar b) => b.volume;

/// 一条日线序列上算好的指标序列。
///
/// 所有指标（smaSeries / emaSeries→MACD / KDJ / RSI / 量比 / 成交额比 /
/// [BreakoutWindow]）的第 t 天取值**只依赖 `bars[0..t]`**，因此整条序列算一次
/// 即可反复构造任意一天的快照。两个好处：
/// - 没有未来信息——回测逐日评规则时不存在前瞻偏差；
/// - 复杂度从「每天重算整条」的 O(n²)/股 降到 O(n)/股（5586 只 × 120 日是数量级差别）。
///
/// [fromStock] 也走这里，保证选股与回测两条路径用的是同一套构造逻辑。
class IndicatorSeries {
  IndicatorSeries._({
    required this.bars,
    required this.ma5,
    required this.ma10,
    required this.ma20,
    required this.ma60,
    required this.ma250,
    required this.dif,
    required this.dea,
    required this.k,
    required this.d,
    required this.j,
    required this.rsi14,
  });

  /// 从完整日线序列构造。[bars] 少于 [IndicatorSnapshot.minBars] 根时各字段仍会算出来，
  /// 但 [at] 在此之前就会抛 StateError。
  factory IndicatorSeries.from(List<Bar> bars) {
    final closes = [for (final b in bars) b.close];
    final m = ind.macd(closes);
    final kd = ind.kdj(bars);
    return IndicatorSeries._(
      bars: bars,
      ma5: ind.smaSeries(closes, 5),
      ma10: ind.smaSeries(closes, 10),
      ma20: ind.smaSeries(closes, 20),
      ma60: ind.smaSeries(closes, 60),
      ma250: ind.smaSeries(closes, 250),
      dif: m.dif,
      dea: m.dea,
      k: kd.k,
      d: kd.d,
      j: kd.j,
      rsi14: ind.rsiSeries(closes, 14),
    );
  }

  final List<Bar> bars;

  /// 以下各序列与 [bars] 等长、按下标对齐；MA 与 KDJ 前若干位为 null。
  final List<double?> ma5;
  final List<double?> ma10;
  final List<double?> ma20;
  final List<double?> ma60;

  /// MA250 序列；前 249 位为 null。
  final List<double?> ma250;
  final List<double> dif;
  final List<double> dea;
  final List<double?> k;
  final List<double?> d;
  final List<double?> j;
  final List<double?> rsi14;

  /// 箱体上沿 / 中枢宽度 / 中枢方向的逐日序列（见 [ind.pivotSeries]）。
  /// 惰性构建：仅中枢规则（经 [IndicatorSnapshot.pivotWindow]）读取。
  /// 主力规则及绝大多数规则不需要，急切构建白占 IndicatorSeries 55% 的耗时。
  late final ind.PivotSeries pivot = ind.pivotSeries(bars, kPivotLookbackBars);

  int get length => bars.length;

  /// 第 [t] 天的指标快照（只用 bars[0..t]，不含未来信息）。
  /// [t] 越界抛 RangeError；第 t 天历史不足 [IndicatorSnapshot.minBars] 根抛 StateError。
  IndicatorSnapshot at(int t) {
    if (t < 0 || t >= bars.length) {
      throw RangeError.index(t, bars, 't', '日线下标越界');
    }
    if (t + 1 < IndicatorSnapshot.minBars) {
      throw StateError('第 $t 天历史不足 ${IndicatorSnapshot.minBars} 根，无法构造快照');
    }
    final prev = t - 1;
    final prevClose = bars[prev].close;
    // 前 5 日均量/涨跌幅用下标与已有值直接算，不再每日切 sublist：
    // 回测 200 万+ 评估日时这是快照构造里的分配大户。
    // at() 已保证 t+1 ≥ minBars(20)，故 t-5 必然非负。
    var volSum = 0.0;
    for (var k = t - 5; k < t; k++) {
      volSum += bars[k].volume;
    }
    return IndicatorSnapshot._(
      close: bars[t].close,
      prevClose: prevClose,
      ma5: ma5[t]!,
      prevMa5: ma5[prev]!,
      ma10: ma10[t]!,
      prevMa10: ma10[prev]!,
      ma20: ma20[t]!,
      dif: dif[t],
      prevDif: dif[prev],
      dea: dea[t],
      prevDea: dea[prev],
      k: k[t]!,
      prevK: k[prev]!,
      d: d[t]!,
      prevD: d[prev]!,
      j: j[t]!,
      rsi14: rsi14[t]!,
      volumeRatio: bars[t].volume / (volSum / 5),
      pctChange: (bars[t].close - prevClose) / prevClose * 100,
      ma60: ma60[t],
      prevMa60: ma60[prev],
      ma60Trend5: ind.smaSeriesTrend(ma60, t),
      bias60: ma60[t] == null ? null : ind.biasPctOf(bars[t].close, ma60[t]!),
      ma250: ma250[t],
      ma250Trend5: ind.smaSeriesTrend(ma250, t),
      bias250: ma250[t] == null ? null : ind.biasPctOf(bars[t].close, ma250[t]!),
      amountRatio: BreakoutWindow.ratioOf(bars, t, _barAmount),
      closePos: ind.closePos(bars[t]),
      bullAlignment: ind.maBullAlignment(ma5[t], ma10[t], ma20[t], ma60[t]),
      series: this,
      t: t,
    );
  }
}

/// 一条选股规则：对末日指标快照做布尔判断。
class Rule {
  const Rule({
    required this.id,
    required this.name,
    required this.desc,
    required this.test,
  });

  final String id;
  final String name;

  /// 一句话说明这条规则在选什么。给 UI 的规则列表与回测页当"规则介绍"用。
  final String desc;
  final bool Function(IndicatorSnapshot) test;
}

/// 突破前 [kPreBreakoutCheckDays] 日内，收盘位于 MA60 下方的天数是否够多。
/// 不够说明前期已在线上反复穿越，不是首次有效突破。
bool _preBreakoutDigested(BreakoutWindow w, int j) {
  if (j - kPreBreakoutCheckDays < 0) return false;
  var below = 0;
  for (var k = j - kPreBreakoutCheckDays; k < j; k++) {
    final m = w.ma60[k];
    if (m == null) return false;
    if (w.closes[k] < m) below++;
  }
  return below >= kPreBreakoutMinBelow;
}

/// 突破日本身的质量：幅度 / 量比 / 成交额 / 收盘位置。
bool _breakoutBarQualifies(BreakoutWindow w, int j) {
  final m = w.ma60[j];
  if (m == null) return false;
  if ((w.closes[j] / m - 1) * 100 < kBreakoutMinPct) return false;
  if (w.volumeRatios[j] < kBreakoutMinVolumeRatio) return false;
  if (w.amountRatios[j] < kBreakoutMinAmountRatio) return false;
  if (w.closePoses[j] < kBreakoutMinClosePos) return false;
  return true;
}

/// [ma60BreakoutConfirmed] 的逐条件判定：返回第一个不满足的条件名；null = 通过。
/// 规则本体与诊断工具（tool/diag_breakout.dart）都走这一份判定，调阈值不会分叉。
///
/// 廉价标量条件前置：窗口字段惰性构建后，多数交易日在这里就短路，
/// 不会触发窗口构建（判定集合不变，只有多条件同时失败时报告的先后会变）。
String? explainMa60BreakoutConfirmed(IndicatorSnapshot s, {required int standDays}) {
  // 不追高：信号日乖离有上限。
  final bias = s.bias60;
  if (bias == null) return '乖离未知(历史不足 61 根)';
  if (bias > kBreakoutMaxBiasPct) return '信号日乖离>$kBreakoutMaxBiasPct%';
  // 趋势：MA60 走平或上翘，且均线多头排列。
  final trend = s.ma60Trend5;
  if (trend == null) return 'MA60 趋势未知(历史不足)';
  if (trend < 0) return 'MA60 仍下行';
  if (bullAlignmentRequired && !s.bullAlignment) return '非多头排列';

  final w = s.window;
  if (w == null) return '历史不足突破窗口';
  final j = w.crossUpIndex;
  if (j < 0) return '窗口内无上穿';
  final gap = w.length - 1 - j;
  if (gap < standDays) return '距突破不足 $standDays 日';
  // standDays=0（ma60_breakout_now）是「突破当日」变体：必须正好落在突破日。
  // 只靠下限 0 的话，最近一次上穿在 1~5 日内也会命中，规则名与其回测统计口径就对不上了。
  if (standDays == 0 && gap > 0) return '非突破当日';
  if (gap > breakoutLookbackDays) return '突破过久(>$breakoutLookbackDays 日)';

  // 站稳：突破日至信号日每日收盘都在当日 MA60 上方，且最低价未深破。
  for (var k = j; k < w.length; k++) {
    final m = w.ma60[k];
    if (m == null) return '站稳期 MA60 缺失';
    if (w.closes[k] <= m) return '站稳期收盘破 MA60';
    if (w.lows[k] < m * (1 - kBreakoutDeepBreakTol)) return '站稳期深破 MA60';
  }
  if (!_preBreakoutDigested(w, j)) return '突破前未在线下盘整';
  if (!_breakoutBarQualifies(w, j)) return '突破日质量(幅度/量比/额比/收盘位置)';
  return null;
}

/// 有效突破模式 A：突破并站稳 MA60。
///
/// [standDays] 是**唯一的旋钮**，也是本规则的全部设计变量：
/// - `0` → 突破当日记号，只做质量过滤、不等待（`ma60_breakout_now`）
/// - `kBreakoutStandDays`(3) → 要求站稳 3 日（`ma60_breakout_confirmed`）
///
/// 回测要回答的正是"多等几天更划算"，所以实现只有一份、参数化；
/// 避免为每个等待天数写一条规则导致逻辑分叉。
/// 共同的条件清单与判定顺序见 [explainMa60BreakoutConfirmed]。
bool ma60BreakoutConfirmed(IndicatorSnapshot s, {required int standDays}) =>
    explainMa60BreakoutConfirmed(s, standDays: standDays) == null;

/// 「突破当日」变体的站稳天数：0 = 不等，突破当日记号。
const kBreakoutNowStandDays = 0;

/// `rsi_oversold_volume`（RSI超卖·放量）的两个阈值。
///
/// 取值来自 20 组参数穷举（`tool/sweep_rsi_volume.dart --split-at 20250101`，
/// 三年 337 万可评估日）。RSI<20 量比>1.5 相比次优的 RSI<25 量比>2.0 在
/// 全年胜率（86.4% vs 75.5%）、平均收益（+19.05% vs +11.06%）、
/// 盈亏比（17.06 vs 5.82）、信号数（7496 vs 5079）上全面占优，
/// 且 2024/2025/2026 三年各自都跑赢当年基准。
///
/// 已核对：参数曲面在两个方向上都单调（越严胜率越高），该组合是角落解，
/// 不要再往 RSI<15 / 量比>1.2 继续扫——那是在追噪声。
const kRsiOversoldVolumeThreshold = 20.0;

/// 宽松版阈值：RSI<25 量比>1.5。
///
/// 与现役版（[kRsiOversoldVolumeThreshold]）是**同一策略的两个档位**，
/// 信号集合是超集（RSI<25 ⊃ RSI<20）。加它不是为了"更好"——
/// 宽松版在胜率/平均收益/盈亏比上都更低，但**信号数是现役版的 1.9 倍**
/// （14181 vs 7496），且 2026 年仍有约 11 个候选/日（现役版只剩约 2.8 个）。
/// 用途是对冲现役版的信号崩塌风险，同时提供"更差年份超额更高"的稳健档。
///
/// 三年数据对照（10 日）：
///   现役  RSI<20 量比>1.5：7496 信号 / 86.4% / +19.05% / PF 17.06
///   宽松  RSI<25 量比>1.5：14181 信号 / 78.5% / +13.04% / PF 8.95
const kRsiOversoldVolumeLooseThreshold = 25.0;
const kRsiOversoldVolumeVolumeRatio = 1.5;

// ── 中枢突破（缠论）阈值 ──────────────────────────────────────
// 中枢 = 近 N 日（不含当日）的箱体 [最低价, 最高价]；突破 = 放量收过上沿；
// 三买 = 突破后回抽最低价不破上沿。这里的「箱体」是缠论中枢的**可计算代理**——
// 真正的缠论中枢要靠笔/线段分解，那个依赖分型识别、没有唯一解。
// 用固定长度箱体替代后判据完全确定、可复现，代价是精度低于原教旨缠论。
//
// 「中枢方向」是关键：向后半段高低点均严格高于前半段（上涨中继中枢）。
// 公开资料反复强调方向错了突破大概率是诱多，所以它是硬条件而不是加分项。

/// 中枢考察的 K 线数（箱体长度）。
const kPivotLookbackBars = 20;

/// 中枢最大宽度（%）。(上沿−下沿)/下沿 超过此值视为宽幅震荡，不是有效中枢。
const kPivotMaxWidthPct = 25.0;

/// 中枢突破的回溯天数：突破日距信号日最多这么多天（0 = 必须当日突破）。
const kPivotBreakoutMaxGap = 0;

/// 突破日量比下限。缩量突破视为无效。
const kPivotMinVolumeRatio = 1.5;

/// 回抽确认（三买）的窗口长度：覆盖「突破 → 站稳 → 缩量回踩 → 再启动」。
const kPivotPullbackWindowLength = 8;

/// `near_ma250`：站上 MA250 的最高乖离（%）。超过视为已远离年线、年线不再是支撑，
/// 同时过滤掉刚突破年线、年线仍在头顶当压力的位置。
const kMa250MaxBiasPct = 15.0;
/// MA60 是否发生上穿：前一日收盘在 MA60 下方或等值，当日收在上方。
/// 用收盘价确认，不看盘中最高价（防骗线）。
bool ma60Upcross(IndicatorSnapshot s) {
  final m = s.ma60, pm = s.prevMa60;
  return m != null && pm != null && s.prevClose <= pm && s.close > m;
}

/// 可叠加到「MA60 上穿」上的过滤项。
///
/// 裸 [ma60Upcross] 的回测表现见 `docs/project-structure.md`；这些项是用来
/// 逐个验证"再加一层确认是否真有增量"的开关，全部关闭即裸上穿。
enum Ma60Filter {
  /// 突破幅度：乖离 ≥ [kBreakoutMinPct]%。低于此视为蹭线。
  breakoutPct,

  /// 量能：突破日量比落在 [kBreakoutMinVolumeRatio] ~ [kBreakoutMaxVolumeRatio]。
  /// 缩量突破多是假突破；骤然天量多是一轮脉冲。
  volumeWindow,

  /// 成交额：突破日成交额 / 前 5 日均额 ≥ [kBreakoutMinAmountRatio]。量价须同向放大。
  amountRatio,

  /// 资金流入的 OHLCV 代理：突破日收盘位于当日振幅上半部。
  closePos,

  /// 多头排列 MA5>MA10>MA20>MA60。
  bullAlignment,

  /// MA60 走平或上翘（近 5 日变动 ≥0）。别在均线明确下行时接飞刀。
  ma60Rising,

  /// 突破前 5 日中至少 [kPreBreakoutMinBelow] 日收盘在线下——区分首次突破
  /// 与高位反复穿越。
  digestedBelow,

  /// 不追高：乖离 ≤ [kBreakoutMaxBiasPct]%。
  noChase,

  /// 年线过滤：MA250 走平或上翘。
  ma250Up,

  /// 年线过滤：站在 MA250 上方且乖离 ≤ [kMa250MaxBiasPct]%。
  nearMa250,
}

/// 单个过滤项是否通过。[ma60BreakoutWith] 与回测扫描工具都走这里，
/// 保证"规则判定"和"逐项统计"用的是同一套逻辑，不会分叉。
bool ma60FilterPasses(IndicatorSnapshot s, Ma60Filter f) {
  switch (f) {
    case Ma60Filter.breakoutPct:
      return (s.bias60 ?? double.negativeInfinity) >= kBreakoutMinPct;
    case Ma60Filter.volumeWindow:
      return s.volumeRatio >= kBreakoutMinVolumeRatio &&
          s.volumeRatio <= kBreakoutMaxVolumeRatio;
    case Ma60Filter.amountRatio:
      return s.amountRatio >= kBreakoutMinAmountRatio;
    case Ma60Filter.closePos:
      return s.closePos >= kBreakoutMinClosePos;
    case Ma60Filter.bullAlignment:
      return s.bullAlignment;
    case Ma60Filter.ma60Rising:
      return (s.ma60Trend5 ?? double.negativeInfinity) >= 0;
    case Ma60Filter.digestedBelow:
      return _digestedBeforeUpcross(s);
    case Ma60Filter.noChase:
      return (s.bias60 ?? double.infinity) <= kBreakoutMaxBiasPct;
    case Ma60Filter.ma250Up:
      return (s.ma250Trend5 ?? double.negativeInfinity) >= 0;
    case Ma60Filter.nearMa250:
      final b = s.bias250;
      return b != null && b >= 0 && b <= kMa250MaxBiasPct;
  }
}

/// 「MA60 上穿 + 所选过滤项」的规则。[filters] 为空即裸 [ma60Upcross]。
///
/// 存在意义：确认类条件该不该加，只能由回测说话（见 `bin/backtest.dart`）。
/// 抽成可组合的开关，才能逐项、逐组合地量，而不是一次性拍死一整条规则。
Rule ma60BreakoutWith(Set<Ma60Filter> filters) {
  // id 必须区分具体组合：backtestAll / 报告都按 rule.id 分桶，
  // 只记数量的 id 会把「同数量、不同组合」的信号静默合并成一份假统计。
  final key =
      [for (final f in Ma60Filter.values) if (filters.contains(f)) f.name].join('+');
  return Rule(
    id: 'ma60_breakout_x{$key}',
    name: 'MA60上穿${filters.isEmpty ? '' : '+${filters.length}项过滤'}',
    desc: 'MA60 上穿 + 所选 ${filters.length} 项过滤（可组合开关，用于逐项验证增量）',
    test: (s) =>
        ma60Upcross(s) && filters.every((f) => ma60FilterPasses(s, f)),
  );
}

/// 中枢突破判定窗口：末日往前 [length] 天，每天带当日的「前 N 日箱体上沿」。
///
/// 与 [BreakoutWindow] 同构但压力位是**水平箱体上沿**而不是移动均线——
/// 这正是「中枢突破」与「均线突破」的本质区别：箱体是固定价位，
/// 均线是随价格漂移的曲线，两者筛选出的不是同一批股票。
class PivotWindow {
  PivotWindow({
    required this.bars,
    required this.pivot,
    required this.from,
    required this.end,
  });

  /// 窗口覆盖的完整日线（[from]..[end] 是窗口内的下标，[bars] 是全局下标）。
  final List<Bar> bars;
  final ind.PivotSeries pivot;
  final int from;
  final int end;

  int get length => end - from + 1;

  /// 各字段惰性生成（读到才分配，缓存后再读零成本）。
  ///
  /// 实测全市场 336 万个可评估日里 98.9% 都会构造本窗口（两条 pivot 规则都要读），
  /// 而 [pivot_breakout] 的第一步 [breakoutIndex] 在「当日收盘未破上沿」时立刻
  /// 返回 false——那 98.9% 里绝大多数读不到 lows/opens/volumes/closePoses。
  /// 急切构造要为 9 个字段各分配一个 List，合计约 2.1s；惰性后大部分日子只花
  /// closes+uppers 两个。
  late final List<double> closes = [
    for (var i = from; i <= end; i++) bars[i].close
  ];
  late final List<double> lows = [
    for (var i = from; i <= end; i++) bars[i].low
  ];
  late final List<double> opens = [
    for (var i = from; i <= end; i++) bars[i].open
  ];
  late final List<double> volumes = [
    for (var i = from; i <= end; i++) bars[i].volume
  ];

  /// 每日的「前 [kPivotLookbackBars] 日箱体上沿」，不含当日。
  late final List<double> uppers = [
    for (var i = from; i <= end; i++) pivot.uppers[i] ?? 0,
  ];

  /// 每日的中枢宽度（%）。
  late final List<double> widthPcts = [
    for (var i = from; i <= end; i++) pivot.widthPcts[i] ?? 0,
  ];

  /// 每日的中枢方向是否向上。
  late final List<bool> risings = [
    for (var i = from; i <= end; i++) pivot.risings[i]
  ];

  /// 逐日量比。用顶层函数引用而非内联闭包：窗口在 98.9% 的日子被构造，
  /// 内联闭包每次都要分配一个对象。
  late final List<double> volumeRatios = [
    for (var i = from; i <= end; i++)
      BreakoutWindow.ratioOf(bars, i, _barVolume)
  ];

  /// 逐日收盘位置。
  late final List<double> closePoses = [
    for (var i = from; i <= end; i++) ind.closePos(bars[i])
  ];

  /// 窗口内最近一次「收盘价突破箱体上沿」的下标；无则 −1。
  ///
  /// 刻意不先物化 [closes]/[uppers] 两个 List：规则只需比较
  /// `bars[i].close > pivot.uppers[i]`，按下标直接读即可，省掉两次切片分配。
  int get breakoutIndex {
    for (var i = length - 1; i >= 1; i--) {
      final t = from + i;
      if (bars[t].close > (pivot.uppers[t] ?? 0)) return i;
    }
    return -1;
  }

  /// 取「以 [end] 为最后一天、长度 [length]」的窗口；K 线不足返回 null。
  ///
  /// [pivot] 必须是整条序列已算好的箱体数据（见 [ind.pivotSeries]），按下标对齐
  /// [bars]——由调用方（[IndicatorSeries]）算一次传进来。刻意不在这里调标量版
  /// `highestHigh/sublist` 逐日重算：那样单股就是 O(len×n)，回测逐日评规则时
  /// 全市场 O(n²)，实测两条 pivot 规则合计吃掉 backtestAll 58s 中的 34.5s。
  static PivotWindow? endingAt(
      List<Bar> bars, ind.PivotSeries pivot, int end, int length) {
    if (length <= 0) throw ArgumentError('length 必须为正，实际 $length');
    if (end < 0 || end >= bars.length) {
      throw RangeError.value(end, 'end', '日线下标越界');
    }
    if (pivot.uppers.length != bars.length) {
      throw ArgumentError('pivot 与 bars 必须等长，实际 ${pivot.uppers.length} / ${bars.length}');
    }
    // 最早的突破日还要能算出它之前的箱体
    if (end + 1 < kPivotLookbackBars + length) return null;
    return PivotWindow(
      bars: bars,
      pivot: pivot,
      from: end - length + 1,
      end: end,
    );
  }
}

/// 上穿前 [kPreBreakoutCheckDays] 日内，收盘位于 MA60 下方的天数是否够多。
/// 参照的是**信号日前几日**（与 [ma60Upcross] 同一个突破日），不是窗口内
/// 更早的那次上穿。窗口不足（历史太短）时按不满足处理。
bool _digestedBeforeUpcross(IndicatorSnapshot s) {
  final w = s.window;
  if (w == null) return false;
  final last = w.length - 1;
  if (last - kPreBreakoutCheckDays < 0) return false;
  var below = 0;
  for (var k = last - kPreBreakoutCheckDays; k < last; k++) {
    final m = w.ma60[k];
    if (m == null) return false;
    if (w.closes[k] < m) below++;
  }
  return below >= kPreBreakoutMinBelow;
}

/// [_ma60BreakoutPullback] 的逐条件判定：返回第一个不满足的条件名；null = 通过。
/// 与 confirmed 的 explain 同目的：规则与诊断工具共用一份判定。
/// 廉价标量条件前置（理由同 [explainMa60BreakoutConfirmed]）。
String? explainMa60BreakoutPullback(IndicatorSnapshot s) {
  // 不追高 + 趋势。回踩必然搅乱短期均线，故这里只要求 MA20 > MA60。
  final bias = s.bias60;
  if (bias == null) return '乖离未知(历史不足 61 根)';
  if (bias > kBreakoutMaxBiasPct) return '信号日乖离>$kBreakoutMaxBiasPct%';
  final trend = s.ma60Trend5;
  if (trend == null) return 'MA60 趋势未知(历史不足)';
  if (trend < 0) return 'MA60 仍下行';
  // ma20 恒非空（快照需 ≥20 根），只有 ma60 可能为 null。
  final m60 = s.ma60;
  if (m60 == null) return 'MA60 缺失';
  if (s.ma20 <= m60) return 'MA20 ≤ MA60';
  if (pullbackBullAlignmentRequired && !s.bullAlignment) return '非多头排列';

  final w = s.pullbackWindow;
  if (w == null) return '历史不足回踩窗口';
  final j = w.crossUpIndex;
  if (j < kPreBreakoutCheckDays) return '窗口内无上穿/突破贴窗口头';
  if (w.length - 1 - j < kPullbackMinGapDays) return '距突破不足 $kPullbackMinGapDays 日';
  if (!_preBreakoutDigested(w, j)) return '突破前未在线下盘整';
  if (!_breakoutBarQualifies(w, j)) return '突破日质量(幅度/量比/额比/收盘位置)';

  // 回踩段 = 突破日次日 ～ 信号日前一日：不破线、未深破、真踩到线、不再放量。
  var touched = false;
  for (var k = j + 1; k < w.length - 1; k++) {
    final m = w.ma60[k];
    if (m == null) return '回踩段 MA60 缺失';
    if (w.closes[k] <= m) return '回踩收盘破 MA60';
    if (w.lows[k] < m * (1 - kBreakoutDeepBreakTol)) return '回踩深破 MA60';
    if (w.lows[k] <= m * (1 + kPullbackTouchTol)) touched = true; // 真踩到线
    if (w.volumes[k] > w.volumes[j] * kPullbackShrinkMax) return '回踩放量';
  }
  if (!touched) return '回踩未触及 MA60';

  // 再启动（信号日）：阳线 + 放量 + 收盘在振幅上半部 + 创近 N 日新高（越过整理平台）。
  final i = w.length - 1;
  if (w.closes[i] <= w.opens[i]) return '再启动非阳线';
  if (w.volumeRatios[i] < kBreakoutMinVolumeRatio) return '再启动量比不足';
  if (w.closePoses[i] < kBreakoutMinClosePos) return '再启动收盘位置偏低';
  if (w.amountRatios[i] < kBreakoutMinAmountRatio) return '再启动额比不足';
  final from = i - kPullbackNewHighDays;
  if (from < 0) return '新高窗口不足';
  for (var k = from; k < i; k++) {
    if (w.closes[i] <= w.closes[k]) return '再启动未创近 $kPullbackNewHighDays 日新高';
  }
  return null;
}

/// 有效突破模式 B：突破 → 缩量回踩不破 MA60 → 再放量阳线收复。
/// 触发日是「再放量阳线」当日，不是突破当日；突破日须在信号日前
/// kPullbackMinGapDays 个交易日以上，留出站稳与回踩的时间。
bool _ma60BreakoutPullback(IndicatorSnapshot s) =>
    explainMa60BreakoutPullback(s) == null;

/// `ma60_breakout_bull` 的规则实例。提成顶层常量是为了让判定复用同一个对象：
/// 内联在 [builtInRules] 里写成 `ma60BreakoutWith(const {...}).test(s)` 的话，
/// 每次判定都会重新遍历枚举拼字符串 id 并 new 一个 Rule，而回测逐日评规则
/// 会调用它数百万次。
final Rule ma60BreakoutBullRule = ma60BreakoutWith(const {
  Ma60Filter.bullAlignment,
  Ma60Filter.noChase,
});

/// 内置规则目录。UI 从这里列出可选规则；单规则选股传一条，组合选股传多条（AND）。
/// 当前主力规则 id。**不钉首位**（2026-10-07 起）：侧栏顺序完全由超额排序决定
/// （与回测统计行红绿同口径），UI 只在它名字旁挂「主力」徽标标识身份。
///
/// 选中它的依据是**跨市况稳健**而不是全样本胜率：宽松版全样本胜率 79.9%
/// 低于严格版 86.4%，但按 tool/rule_by_month.dart 的分档结果，它在下行 /
/// 中性 / 上行三种市况下的超额是 +14.0 / +14.1 / +29.0pp（样本 3887 / 398 /
/// 9321），而严格版 73.7% 的信号集中在 2024-02 单月、中性月只剩 85 个信号。
/// 这个判断随月度台账更新，改它要同步改文档。
const kMainRuleId = 'rsi_oversold_volume_loose';

final List<Rule> builtInRules = [
  // 顺序即“主力顺序”：宽松版 RSI超卖·放量 排在首位。
  // 依据见 tool/rule_by_month.dart 的分档结果——它在下行 / 中性 / 上行
  // 三种市况下都有足够样本量的正超额（+14.0 / +14.1 / +29.0pp），
  // 而严格版 73.7% 的信号集中在 2024-02 单月。
  // 顺序影响侧栏默认排布与命中规则的展示次序。
  Rule(
    id: 'rsi_oversold_volume_loose',
    name: 'RSI超卖·放量(宽松)',
    // 与 rsi_oversold_volume 同策略、RSI 阈值更松；见 [kRsiOversoldVolumeLooseThreshold]。
    desc: 'RSI14<25 且量比>1.5：宽松版，信号更多但单笔质量略低',
    test: (s) =>
        s.rsi14 < kRsiOversoldVolumeLooseThreshold &&
        s.volumeRatio > kRsiOversoldVolumeVolumeRatio,
  ),
  Rule(
    id: 'close_above_ma20',
    name: '收盘价站上MA20',
    desc: '收盘价站在 MA20 上方，短期趋势向上',
    test: (s) => s.close > s.ma20,
  ),
  Rule(
    id: 'ma5_golden_ma10',
    name: 'MA5上穿MA10',
    desc: 'MA5 上穿 MA10，短线金叉',
    test: (s) => s.prevMa5 <= s.prevMa10 && s.ma5 > s.ma10,
  ),
  Rule(
    id: 'macd_golden_cross',
    name: 'MACD金叉',
    desc: 'DIF 上穿 DEA，MACD 金叉',
    test: (s) => s.prevDif <= s.prevDea && s.dif > s.dea,
  ),
  Rule(
    id: 'rsi_oversold',
    name: 'RSI超卖(RSI14<30)',
    desc: 'RSI14<30 超卖，博反弹',
    test: (s) => s.rsi14 < 30,
  ),
  Rule(
    id: 'rsi_overbought',
    name: 'RSI超买(RSI14>70)',
    desc: 'RSI14>70 超买，注意风险',
    test: (s) => s.rsi14 > 70,
  ),
  Rule(
    id: 'volume_surge',
    name: '量比>2',
    desc: '量比>2，明显放量',
    test: (s) => s.volumeRatio > 2,
  ),
  Rule(
    id: 'pct_change_up',
    name: '当日涨幅>3%',
    desc: '当日涨幅超过 3%，短线强势',
    test: (s) => s.pctChange > 3,
  ),
  Rule(
    id: 'close_above_ma60',
    name: '收盘价站上MA60',
    desc: '收盘价站上 MA60（季线），中期趋势转强',
    test: (s) {
      final m = s.ma60;
      return m != null && s.close > m;
    },
  ),
  Rule(
    id: 'ma60_breakout',
    name: 'MA60上穿',
    desc: '收盘价上穿 MA60，突破当日',
    test: ma60Upcross,
  ),
  Rule(
    id: 'ma60_breakout_confirmed',
    name: '60日线有效突破(站稳)',
    desc: '上穿 MA60 后站稳 3~5 日，并叠加量价与趋势多重确认',
    test: (s) => ma60BreakoutConfirmed(s, standDays: kBreakoutStandDays),
  ),
  Rule(
    id: 'ma60_breakout_now',
    name: '60日线突破当日确认',
    desc: '上穿 MA60 当日即确认，不等站稳',
    test: (s) => ma60BreakoutConfirmed(s, standDays: kBreakoutNowStandDays),
  ),
  Rule(
    id: 'ma60_breakout_pullback',
    name: '60日线突破回踩确认',
    desc: '突破后缩量回踩不破 MA60，再放量阳线收复',
    test: _ma60BreakoutPullback,
  ),
  Rule(
    id: 'kdj_golden_cross',
    name: 'KDJ金叉',
    desc: 'K 上穿 D，短线金叉（与 MACD 金叉同口径：前值相等也算上穿）',
    test: (s) => s.prevK <= s.prevD && s.k > s.d,
  ),
  Rule(
    id: 'rsi_oversold_volume',
    name: 'RSI超卖·放量',
    // 三年样本（2024-01 ~ 2026-09，337 万个可评估日）按**日历年**切分后，
    // 这是唯一在每一年都跑赢当年基准的组合：
    // 2024 6318 信号 89.5%（基准 47.7%）、2025 662 信号 81.3%（基准 55.5%）、
    // 2026 516 信号 53.9%（基准 44.2%）。全样本 7496 信号 / 86.4% / PF 17.06。
    // 阈值来源见 [kRsiOversoldVolumeThreshold]。
    desc: 'RSI14<20 深跌且量比>1.5：有量的超卖反弹，三年样本唯一跨年稳健',
    test: (s) =>
        s.rsi14 < kRsiOversoldVolumeThreshold &&
        s.volumeRatio > kRsiOversoldVolumeVolumeRatio,
  ),
  Rule(
    id: 'pivot_breakout',
    name: '中枢突破',
    desc: '放量突破近20日箱体上沿，且中枢方向向上、宽度不过宽',
    test: (s) {
      final w = s.pivotWindow;
      if (w == null) return false;
      // 必须**当日**突破：窗口内最近一次突破若在几日之前，信号已陈旧
      if (w.breakoutIndex != w.length - 1) return false;
      final j = w.length - 1;
      // 中枢质量：宽度与方向
      if (w.widthPcts[j] > kPivotMaxWidthPct) return false;
      if (!w.risings[j]) return false;
      // 放量
      return w.volumeRatios[j] >= kPivotMinVolumeRatio;
    },
  ),
  Rule(
    id: 'pivot_breakout_pullback',
    name: '中枢突破回抽不破',
    desc: '突破箱体上沿后缩量回踩不破上沿，再放量阳线启动（缠论三买）',
    test: (s) {
      final w = s.pivotWindow;
      if (w == null) return false;
      var j = w.breakoutIndex;
      if (j < 0) return false;
      // 回退到允许的最早突破日
      final earliest = w.length - 1 - kPivotPullbackWindowLength;
      if (j < earliest) j = earliest;
      if (j < 0) return false;
      // 中枢质量（在突破日判定）
      if (w.widthPcts[j] > kPivotMaxWidthPct) return false;
      if (!w.risings[j]) return false;
      if (w.volumeRatios[j] < kPivotMinVolumeRatio) return false;
      final upper = w.uppers[j];
      // 突破日至信号日：最低价不破上沿（容差由 DEEP 常量控制）
      var maxPullClose = double.negativeInfinity;
      var loudest = 0.0;
      for (var k = j + 1; k < w.length; k++) {
        if (w.lows[k] < upper * (1 - kBreakoutDeepBreakTol)) return false;
        if (w.lows[k] < upper) return false; // 回抽不得跌回中枢内
        if (w.closes[k] > maxPullClose) maxPullClose = w.closes[k];
        if (w.volumes[k] > loudest) loudest = w.volumes[k];
      }
      // 缩量回踩
      if (loudest > w.volumes[j] * kPullbackShrinkMax) return false;
      // 再启动：阳线 + 放量 + 收复回踩段最高收盘
      final i = w.length - 1;
      if (w.closes[i] <= w.opens[i]) return false;
      if (w.volumeRatios[i] < kPivotMinVolumeRatio) return false;
      if (w.closePoses[i] < kBreakoutMinClosePos) return false;
      return w.closes[i] > maxPullClose;
    },
  ),
  Rule(
    id: 'ma250_up',
    name: 'MA250走平或上翘',
    desc: 'MA250 走平或上翘，别在年线明确下行时接飞刀',
    test: (s) => (s.ma250Trend5 ?? double.negativeInfinity) >= 0,
  ),  Rule(
    id: 'near_ma250',
    name: '站上年线且乖离≤15%',
    desc: '站在 MA250 上方且乖离≤15%，把年线当支撑',
    test: (s) {
      final b = s.bias250;
      return b != null && b >= 0 && b <= kMa250MaxBiasPct;
    },
  ),
  Rule(
    id: 'ma60_breakout_bull',
    name: 'MA60上穿·多头排列',
    desc: '上穿 MA60 且 MA5>MA10>MA20>MA60 多头排列（注意：未通过时间切半稳健性检验）',
    // 424 个交易日回测里 10 日持有期的最优组合（1024 个组合穷举）：
    // 795 信号 / 胜率 55.1% / 平均 +1.26% / 盈亏比 1.46 / 超额胜率 +5.4pp。
    // 在 5/10/20 日三个持有期与三个样本深度下都是唯一方向一致的正贡献项。
    test: ma60BreakoutBullRule.test,
  ),
];
/// 按 id 取内置规则。
Rule ruleById(String id) =>
    builtInRules.firstWhere((r) => r.id == id, orElse: () => throw ArgumentError('未知规则: $id'));
