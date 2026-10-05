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

/// 逐日 SMA 序列，前 n-1 天不足窗口。
List<double?> smaSeries(List<double> closes, int n) => [
      for (var i = 0; i < closes.length; i++)
        i < n - 1 ? null : closes.sublist(i - n + 1, i + 1).reduce((a, b) => a + b) / n,
    ];

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
double rsi(List<double> closes, int n) {
  if (n <= 0 || closes.length < n + 1) {
    throw ArgumentError('需要至少 ${n + 1} 个收盘价，实际 ${closes.length}');
  }
  var avgGain = 0.0, avgLoss = 0.0;
  for (var i = 1; i <= n; i++) {
    final d = closes[i] - closes[i - 1];
    avgGain += d > 0 ? d : 0;
    avgLoss += d < 0 ? -d : 0;
  }
  avgGain /= n;
  avgLoss /= n;
  for (var i = n + 1; i < closes.length; i++) {
    final d = closes[i] - closes[i - 1];
    avgGain = (avgGain * (n - 1) + (d > 0 ? d : 0)) / n;
    avgLoss = (avgLoss * (n - 1) + (d < 0 ? -d : 0)) / n;
  }
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

