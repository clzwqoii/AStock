/// 纯函数技术指标。所有函数只依赖传入数据，不持有状态。
library;

import 'dart:math' as math;

import 'models.dart';

/// 最近 n 个收盘价的简单移动平均。
double sma(List<double> closes, int n) {
  if (n <= 0 || closes.length < n) {
    throw ArgumentError('需要至少 $n 个收盘价，实际 ${closes.length}');
  }
  return closes.sublist(closes.length - n).reduce((a, b) => a + b) / n;
}

/// 逐日 SMA 序列，前 n-1 天不足窗口（返回 null，不抛异常——
/// 选股要在历史不足时安静跳过）。n<=0 是编程错误，抛 ArgumentError。
///
/// 前缀和实现：整条序列 O(n)。逐窗口 sublist+reduce 是 O(n×窗口)，
/// 全市场构建 5 条 MA（含 MA250）时差 30 倍以上，是选股/回测的公共热点。
List<double?> smaSeries(List<double> closes, int n) {
  if (n <= 0) throw ArgumentError('n 必须为正，实际 $n');
  final cum = List<double>.filled(closes.length + 1, 0.0);
  for (var i = 0; i < closes.length; i++) {
    cum[i + 1] = cum[i] + closes[i];
  }
  return [
    for (var i = 0; i < closes.length; i++)
      i < n - 1 ? null : (cum[i + 1] - cum[i - n + 1]) / n,
  ];
}

/// MA(n) 序列在最近 [days] 日区间内的变化量（元）。
/// 用来判断均线是"走平/上翘"还是"仍在下行"：≥0 即视为不再下跌。
/// 末值或回溯起点所在窗口不足时返回 null。
double? smaTrend(List<double> closes, int n, {int days = 5}) {
  if (n <= 0) throw ArgumentError('n 必须为正，实际 $n');
  if (days <= 0) throw ArgumentError('days 必须为正，实际 $days');
  return smaSeriesTrend(smaSeries(closes, n), closes.length - 1, days: days);
}

/// [smaTrend] 的序列形式：直接在已算好的 MA 序列上取 [last] 与 [last - days] 的差。
/// 回测要逐日构造快照，用它可以免去每天重算整条序列。
double? smaSeriesTrend(List<double?> maSeries, int last, {int days = 5}) {
  if (days <= 0) throw ArgumentError('days 必须为正，实际 $days');
  final prev = last - days;
  if (last < 0 || prev < 0 || maSeries[last] == null || maSeries[prev] == null) return null;
  return maSeries[last]! - maSeries[prev]!;
}

/// 收盘价相对 MA(n) 的乖离率（百分比，如 5.0 表示高出均线 5%）。
/// 历史不足 n 根（MA 无值）时返回 null。
double? biasPct(List<double> closes, int n) {
  if (n <= 0) throw ArgumentError('n 必须为正，实际 $n');
  if (closes.isEmpty) throw ArgumentError('closes 不能为空');
  final s = smaSeries(closes, n);
  if (s.last == null) return null;
  return biasPctOf(closes.last, s.last!);
}

/// [biasPct] 的标量形式。
double biasPctOf(double close, double ma) => (close / ma - 1) * 100;

/// EMA 序列，首日以首个值作种子。
List<double> emaSeries(List<double> values, int n) {
  final a = 2.0 / (n + 1);
  final out = <double>[values.first];
  for (var i = 1; i < values.length; i++) {
    out.add(a * values[i] + (1 - a) * out[i - 1]);
  }
  return out;
}

/// Wilder 平滑 RSI（同国内行情软件口径）。
/// 涨跌均值均为 0 时返回中性 50；只有涨或只有跌时返回 100 或 0。
/// 等价于 [rsiSeries] 的最后一个值。
double rsi(List<double> closes, int n) => rsiSeries(closes, n).last!;

/// 区间最高价：[bars] 中「往前第 [skipLast] 根」之前的最近 [n] 根的最高 high。
/// skipLast=1（默认）表示**不含当日**——用已完成的箱体做压力位，
/// 避免当日自身创新高把自己算成突破。区间不足返回 null。
double? highestHigh(List<Bar> bars, int n, {int skipLast = 1}) {
  if (n <= 0 || skipLast < 0) return null;
  final end = bars.length - skipLast; // 最后考察下标是 end-1
  if (end < n) return null;
  var h = bars[end - n].high;
  for (var i = end - n + 1; i < end; i++) {
    if (bars[i].high > h) h = bars[i].high;
  }
  return h;
}

/// 区间最低价：与 [highestHigh] 同口径取最低 low。
double? lowestLow(List<Bar> bars, int n, {int skipLast = 1}) {
  if (n <= 0 || skipLast < 0) return null;
  final end = bars.length - skipLast;
  if (end < n) return null;
  var l = bars[end - n].low;
  for (var i = end - n + 1; i < end; i++) {
    if (bars[i].low < l) l = bars[i].low;
  }
  return l;
}

/// 中枢宽度（%）= (上沿 − 下沿) / 下沿 × 100。
/// 越窄说明盘整越充分；太宽说明是宽幅震荡、不是有效中枢。
double? pivotWidthPct(List<Bar> bars, int n, {int skipLast = 1}) {
  final hi = highestHigh(bars, n, skipLast: skipLast);
  final lo = lowestLow(bars, n, skipLast: skipLast);
  if (hi == null || lo == null || lo <= 0) return null;
  return (hi - lo) / lo * 100;
}

/// 中枢方向是否向上：把箱体的 [n] 根切成前后两半，
/// 后半段的最高价与最低价都**严格**高于前半段（即低点持续抬高、高点也抬高）。
/// 这就是「上涨中继中枢」与「下跌/顶部中枢」的区别——方向上错了，突破大概率是诱多。
bool pivotRising(List<Bar> bars, int n, {int skipLast = 1}) {
  if (n < 2 || skipLast < 0) return false;
  final end = bars.length - skipLast;
  if (end < n) return false;
  final half = n ~/ 2;
  if (half == 0) return false;
  // 前半段 [end-n, end-n+half)，后半段 [end-n+half, end)
  final mid = end - n + half;
  var h1 = bars[end - n].high, l1 = bars[end - n].low;
  for (var i = end - n + 1; i < mid; i++) {
    h1 = math.max(h1, bars[i].high);
    l1 = math.min(l1, bars[i].low);
  }
  var h2 = bars[mid].high, l2 = bars[mid].low;
  for (var i = mid + 1; i < end; i++) {
    h2 = math.max(h2, bars[i].high);
    l2 = math.min(l2, bars[i].low);
  }
  return h2 > h1 && l2 > l1;
}

/// 逐日箱体上沿 / 中枢宽度 / 中枢方向序列。与 [highestHigh] / [pivotWidthPct] /
/// [pivotRising] 同口径：第 t 天取「不含当日」的前 [n] 根。
///
/// 存在的理由只有复杂度：标量版每天都要重建 `sublist(0, t)` 再重扫 [n] 根，
/// 单股 O(len×n)。回测逐日评规则时这就是全市场 O(n²)——实测两条 pivot 规则
/// 合计吃掉 backtestAll 58s 里的 34.5s。窗口沿日线每次只前进一格，
/// 用单调队列维护极值即可整条 O(len)。
///
/// **口径必须与标量版逐位一致**（`test/pivot_indicators_test.dart` 已锁住）：
/// 旧调用点是 `highestHigh(bars.sublist(0, i), n)`，`skipLast=1` 使其实际考察
/// `[i-1-n, i-2]`——比 [highestHigh] 注释声称的「前 n 根不含当日」早一根。
/// 这里照搬**实际行为**而非注释语义：改窗口位置就是改信号数、毁掉已归档的
/// 月度台账口径（`~/.stock/backtest-history.json`），那是规则调优的事，不是性能优化。
/// 注释与实现的这根偏差留给规则重新调参时一并修正。
typedef PivotSeries = ({
  List<double?> uppers,
  List<double?> widthPcts,
  List<bool> risings,
});

/// 见 [PivotSeries]。[n] <= 1 时整条为空值/false（与标量版返回 null/false 一致）。
PivotSeries pivotSeries(List<Bar> bars, int n) {
  final len = bars.length;
  final uppers = List<double?>.filled(len, null);
  final widthPcts = List<double?>.filled(len, null);
  final risings = List<bool>.filled(len, false);
  if (n <= 1) return (uppers: uppers, widthPcts: widthPcts, risings: risings);

  // high/low 的单调队列（存下标，值单调）。第 t 天考察 [t-1-n, t-2]。
  // 用「head 指针」而不是 removeAt(0)：后者每次都搬移剩余元素，退化成 O(len)。
  final hq = <int>[];
  final lq = <int>[];
  var hHead = 0, lHead = 0;
  final half = n ~/ 2;
  for (var t = 1; t < len; t++) {
    final j = t - 2; // 本轮纳入的根（第 t 天的窗口右端是 t-2）
    if (j < 0) continue;
    while (hq.length > hHead && bars[hq.last].high <= bars[j].high) {
      hq.removeLast();
    }
    hq.add(j);
    while (lq.length > lHead && bars[lq.last].low >= bars[j].low) {
      lq.removeLast();
    }
    lq.add(j);
    final lo = t - 1 - n; // 窗口左端（含）
    while (hHead < hq.length && hq[hHead] < lo) {
      hHead++;
    }
    while (lHead < lq.length && lq[lHead] < lo) {
      lHead++;
    }
    if (lo < 0) continue; // 窗口未满，对应标量版的 end < n → null/false

    final hi = bars[hq[hHead]].high;
    final lv = bars[lq[lHead]].low;
    uppers[t] = hi;
    widthPcts[t] = lv > 0 ? (hi - lv) / lv * 100 : null;

    // 中枢方向：前 half 根 [lo, lo+half) 与后 half 根 [lo+half, t-1) 比极值。
    if (half > 0) {
      final mid = lo + half;
      final h1 = _rangeHigh(bars, lo, mid), l1 = _rangeLow(bars, lo, mid);
      final h2 = _rangeHigh(bars, mid, t - 1), l2 = _rangeLow(bars, mid, t - 1);
      risings[t] = h2 > h1 && l2 > l1;
    }
  }
  return (uppers: uppers, widthPcts: widthPcts, risings: risings);
}

double _rangeHigh(List<Bar> bars, int from, int to) {
  var h = bars[from].high;
  for (var i = from + 1; i < to; i++) {
    if (bars[i].high > h) h = bars[i].high;
  }
  return h;
}

double _rangeLow(List<Bar> bars, int from, int to) {
  var l = bars[from].low;
  for (var i = from + 1; i < to; i++) {
    if (bars[i].low < l) l = bars[i].low;
  }
  return l;
}

/// 逐日 Wilder 平滑 RSI 序列（同国内行情软件口径），前 n 个交易无值。
/// 种子为前 n 个涨跌的简单均值，之后按 (旧值×(n−1) + 当日) / n 递推，
/// 因此第 t 天的值只依赖 closes[0..t]——回测可整条算一次再按日取。
List<double?> rsiSeries(List<double> closes, int n) {
  if (n <= 0 || closes.length < n + 1) {
    throw ArgumentError('需要至少 ${n + 1} 个收盘价，实际 ${closes.length}');
  }
  final out = List<double?>.filled(closes.length, null);
  var avgGain = 0.0, avgLoss = 0.0;
  for (var i = 1; i <= n; i++) {
    final d = closes[i] - closes[i - 1];
    avgGain += d > 0 ? d : 0;
    avgLoss += d < 0 ? -d : 0;
  }
  avgGain /= n;
  avgLoss /= n;
  out[n] = _rsiOf(avgGain, avgLoss);
  for (var i = n + 1; i < closes.length; i++) {
    final d = closes[i] - closes[i - 1];
    avgGain = (avgGain * (n - 1) + (d > 0 ? d : 0)) / n;
    avgLoss = (avgLoss * (n - 1) + (d < 0 ? -d : 0)) / n;
    out[i] = _rsiOf(avgGain, avgLoss);
  }
  return out;
}

double _rsiOf(double avgGain, double avgLoss) {
  if (avgGain == 0 && avgLoss == 0) return 50.0;
  if (avgLoss == 0) return 100.0;
  if (avgGain == 0) return 0.0;
  return 100.0 * avgGain / (avgGain + avgLoss);
}

/// 量比 = 当日成交量 / 前 5 日平均成交量。
double volumeRatio(List<Bar> bars) {
  if (bars.length < 6) {
    throw ArgumentError('量比需要至少 6 根 Bar，实际 ${bars.length}');
  }
  final prev5 = bars.sublist(bars.length - 6, bars.length - 1);
  final avg =
      prev5.map((b) => b.volume).reduce((a, b) => a + b) / prev5.length;
  return bars.last.volume / avg;
}

/// 当日涨跌幅（百分比，如 5.0 表示 +5%）。
double pctChange(List<Bar> bars) {
  if (bars.length < 2) {
    throw ArgumentError('涨跌幅需要至少 2 根 Bar，实际 ${bars.length}');
  }
  final prev = bars[bars.length - 2].close;
  return (bars.last.close - prev) / prev * 100;
}

/// 成交额比 = 当日成交额 / 前 [n] 日平均成交额。与 [volumeRatio] 同构。
/// [Bar.amount] 为 0 或均额为 0（旧数据缺失）时返回 0，由调用方按"不满足"处理，
/// 避免用一条缺失字段把整个规则打挂。
double amountRatio(List<Bar> bars, {int n = 5}) {
  if (n <= 0) throw ArgumentError('n 必须为正，实际 $n');
  if (bars.length < n + 1) {
    throw ArgumentError('成交额比需要至少 ${n + 1} 根 Bar，实际 ${bars.length}');
  }
  if (bars.last.amount <= 0) return 0;
  final prev = bars.sublist(bars.length - n - 1, bars.length - 1);
  if (prev.any((b) => b.amount <= 0)) return 0;
  final avg = prev.map((b) => b.amount).reduce((a, b) => a + b) / prev.length;
  if (avg <= 0) return 0;
  return bars.last.amount / avg;
}

/// 收盘价在当日振幅中的位置（0~1）。越高说明当日主动性买盘越强，
/// 是无资金流数据时对"资金流入"最简的 OHLCV 代理。
/// 一字板（高低相等）取中性 0.5。
double closePos(Bar b) {
  if (b.high <= b.low) return 0.5;
  return (b.close - b.low) / (b.high - b.low);
}

/// MA5/10/20/60 是否构成多头排列（严序 MA5 > MA10 > MA20 > MA60）。
/// 任一为 null（历史不足 60 根）即 false。
bool maBullAlignment(double? ma5, double? ma10, double? ma20, double? ma60) {
  if (ma5 == null || ma10 == null || ma20 == null || ma60 == null) return false;
  return ma5 > ma10 && ma10 > ma20 && ma20 > ma60;
}


/// MACD(12,26,9)。hist 为国内软件惯例 (dif-dea)*2。
({List<double> dif, List<double> dea, List<double> hist}) macd(
  List<double> closes, {
  int fast = 12,
  int slow = 26,
  int signal = 9,
}) {
  final emaFast = emaSeries(closes, fast);
  final emaSlow = emaSeries(closes, slow);
  final dif = [for (var i = 0; i < closes.length; i++) emaFast[i] - emaSlow[i]];
  final dea = emaSeries(dif, signal);
  final hist = [for (var i = 0; i < dif.length; i++) (dif[i] - dea[i]) * 2];
  return (dif: dif, dea: dea, hist: hist);
}

/// 随机指标 KDJ(n, m1, m2)，国内行情软件口径：
/// RSV = (C − N日最低低) / (N日最高高 − N日最低低) × 100（窗口含当日，
/// 高低相等的一字板取 50）；K = SMA(RSV, m1, 1)、D = SMA(K, m2, 1)
/// （即 K = ((m1−1)·K' + RSV) / m1），J = 3K − 2D。
/// 前 n−1 根无值；递推种子 50（窗口满后与主流软件差异收敛到可忽略）。
({List<double?> k, List<double?> d, List<double?> j}) kdj(
  List<Bar> bars, {
  int n = 9,
  int m1 = 3,
  int m2 = 3,
}) {
  if (n <= 0 || m1 <= 0 || m2 <= 0 || bars.length < n) {
    throw ArgumentError('KDJ 需要至少 $n 根 Bar，实际 ${bars.length}');
  }
  final kOut = List<double?>.filled(bars.length, null);
  final dOut = List<double?>.filled(bars.length, null);
  final jOut = List<double?>.filled(bars.length, null);
  var k = 50.0, d = 50.0;
  for (var i = n - 1; i < bars.length; i++) {
    var hh = bars[i].high, ll = bars[i].low;
    for (var w = i - n + 1; w <= i; w++) {
      hh = math.max(hh, bars[w].high);
      ll = math.min(ll, bars[w].low);
    }
    final rsv = hh <= ll ? 50.0 : (bars[i].close - ll) / (hh - ll) * 100.0;
    k = ((m1 - 1) * k + rsv) / m1;
    d = ((m2 - 1) * d + k) / m2;
    kOut[i] = k;
    dOut[i] = d;
    jOut[i] = 3 * k - 2 * d;
  }
  return (k: kOut, d: dOut, j: jOut);
}

