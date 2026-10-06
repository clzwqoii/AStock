/// 选股结果的「评分」：把命中规则的历史胜率聚合成一个 0~100 的分。
///
/// ## 这个分数是什么
///
/// `score = 命中规则的加权历史胜率 × 100`
///
/// 权重是各规则的**信号量**，不是等权。理由：一条三年只有 5 个信号的规则
/// 即使胜率 99% 也不该把一条 7496 个信号的规则拽走——用样本量加权等价于
/// 按"证据强度"投票，噪声规则自然被压下去。
///
/// ## 这个分数不是什么
///
/// - **不是概率承诺**。它是样本内的加权胜率，2026 年这条规则的超额已经
///   从 +41.2pp 衰减到 +8.7pp（见 `docs/project-structure.md` 顶部）。
///   界面必须常驻标注样本区间。
/// - **不区分同一规则内部的强弱**。RSI=15 和 RSI=19、量比=1.6 和 4.0
///   在方案 A 里同分。要区分得换方案 B（逻辑回归），接口保持不变即可替换。
/// - **不用"最好规则胜率"做归一化**。那样做会让当前最强的规则恒等于 100，
///   其余规则全在下面挤成一团，排序失去意义。直接用绝对胜率反而有区分度。
///
/// ## 低置信
///
/// 加权样本量 < [kScoreMinSampleCount] 时置 `lowConfidence`，
/// UI 必须据此降档展示——宁可显示"样本不足"，也不要给一个体面的中档分。
library;

import 'package:stock/core/backtest.dart';
import 'package:stock/core/features.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/logreg.dart';

/// 加权样本量低于此值时评分标为低置信。
const kScoreMinSampleCount = 30;

/// 评分档位边界（高 ≥85 / 中 70~85 / 低 <70）。
const kScoreHighTier = 85.0;
const kScoreMidTier = 70.0;

/// 评分与买卖预测价默认采用的回测持有期（日）。
/// 与报告里最常看的一列对齐，也让 ScoreRow 与回测页数字互相对得上。
const kScoreHorizon = 10;

/// 一条选股结果的评分与它赖以成立的证据。
class StockScore {
  const StockScore({
    required this.score,
    required this.rawWinRate,
    required this.baselineWinRate,
    required this.sampleCount,
    required this.hitRuleIds,
    required this.source,
    required this.lowConfidence,
    required this.reason,
  });

  /// 0~100。等于 [rawWinRate] × 100。
  final double score;

  /// 命中规则的加权历史胜率（0~1）。
  final double rawWinRate;

  /// 同一持有期的无条件基准胜率（0~1）。[score] 为 50 即"与随便买无异"。
  final double baselineWinRate;

  /// 加权样本量 = 各命中规则信号数之和。取值越小越不可信。
  final int sampleCount;

  /// 打分层用了哪套方案：`planA` = 命中规则的加权历史胜率；
  /// `planB` = 逻辑回归。UI 可据此标注，也便于回查是哪一版模型产出的排序。
  final String source;

  /// 参与加权的规则 id（已剔除未登记/无数据的）。
  final List<String> hitRuleIds;

  /// 证据不足时为 true。此时 [score] 仍然算得出来，但**不应当作结论**。
  final bool lowConfidence;

  /// 降级原因（低置信时非空，直接给 UI 展示）。
  final String reason;

  /// 相对基准的超额（百分点）。正表示历史上跑赢随便买。
  double get excessPp => (rawWinRate - baselineWinRate) * 100;

  StockScore copyWith({String? reason}) => StockScore(
        score: score,
        rawWinRate: rawWinRate,
        baselineWinRate: baselineWinRate,
        sampleCount: sampleCount,
        hitRuleIds: hitRuleIds,
        source: source,
        lowConfidence: lowConfidence,
        reason: reason ?? this.reason,
      );

  String get tier {
    if (score >= kScoreHighTier) return '高';
    if (score >= kScoreMidTier) return '中';
    return '低';
  }
}

/// 给一次选股结果打分。
///
/// [report] 为 null（报告缺失或损坏）或命中规则都没有数据 → 返回基准分 50
/// 且 `lowConfidence = true`；选股能力不该被一份报表绑架。
/// [horizon] 取报告里那一列统计，默认 10 日。
StockScore scoreOf(
  BacktestReport? report, {
  List<String> hitRuleIds = const [],
  int horizon = 10,
  LogRegModel? model,
  IndicatorSnapshot? snapshot,
  bool fallbackToPlanA = false,
}) {
  final base = report?.baseline[horizon];
  final baseWin = base?.winRate;

  // 逐条规则累加「胜率 × 信号数」与「信号数」，未登记或无数据的直接跳过。
  var gain = 0.0;
  var count = 0;
  final used = <String>[];
  for (final id in hitRuleIds) {
    final st = report?.result(id, horizon);
    if (st == null || st.count <= 0) continue;
    gain += st.winRate * st.count;
    count += st.count;
    used.add(id);
  }

  // 没有任何可用证据：退到基准，绝不假装有结论。
  if (report == null) {
    return StockScore(
      score: 50,
      rawWinRate: 0.5,
      baselineWinRate: baseWin ?? 0.5,
      sampleCount: 0,
      hitRuleIds: const [],
      source: 'planA',
      lowConfidence: true,
      reason: '暂无回测报告，评分不可用',
    );
  }
  if (baseWin == null) {
    return StockScore(
      score: 50,
      rawWinRate: 0.5,
      baselineWinRate: 0.5,
      sampleCount: 0,
      hitRuleIds: const [],
      source: 'planA',
      lowConfidence: true,
      reason: '回测报告缺 $horizon 日基准，评分不可用',
    );
  }
  if (count == 0) {
    return StockScore(
      score: baseWin * 100,
      rawWinRate: baseWin,
      baselineWinRate: baseWin,
      sampleCount: 0,
      hitRuleIds: const [],
      source: 'planA',
      lowConfidence: true,
      reason: '未命中任何已回测规则',
    );
  }

  final raw = gain / count;
  var reason = '';
  if (count < kScoreMinSampleCount) {
    reason = '历史样本仅 $count 个，评分不可信';
  }
  final planA = StockScore(
    score: raw * 100,
    rawWinRate: raw,
    baselineWinRate: baseWin,
    sampleCount: count,
    hitRuleIds: used,
    source: 'planA',
    lowConfidence: count < kScoreMinSampleCount,
    reason: reason,
  );

  // 方案 B：有模型且维度对得上就用它。
  //
  // 为什么值得替：方案 A 对「同一条规则」下的所有股票给出**同一个分**，
  // 实测 holdout AUC 只有 0.512（≈随机）。方案 B 用 rsi14 等连续特征区分
  // 规则内部的强弱，holdout AUC 0.530。两者的分数口径一致（0~100），
  // 所以这里可以直接替换，UI 与 CSV 都不用改。
  if (model != null) {
    try {
      if (snapshot == null) {
        throw ArgumentError('要用模型打分就必须传 snapshot，否则没有特征向量');
      }
      final vec = featureVector(snapshot, hitRuleIds: hitRuleIds);
      if (vec.length != model.featureCount) {
        throw ArgumentError(
            '模型特征数 ${model.featureCount} ≠ featureNames ${vec.length}，'
            '系数会整体错位');
      }
      final p = model.predictProba(vec);
      return StockScore(
        score: p * 100,
        rawWinRate: p,
        baselineWinRate: baseWin,
        // 样本量与命中规则仍取方案 A 的统计——那部分与用不用模型无关，
        // 而且它是"有多少历史证据支撑"的诚实度量。
        sampleCount: planA.sampleCount,
        hitRuleIds: used,
        source: 'planB',
        lowConfidence: planA.lowConfidence,
        reason: planA.reason,
      );
    } on ArgumentError catch (e) {
      // 维度不符 = 系数错位，比不打分危险。要么按调用方要求回退，
      // 要么直接抛——悄悄给个错分是最坏的选择。
      if (fallbackToPlanA) {
        return planA.copyWith(
            reason: '模型与特征表不匹配（$e），已回退加权胜率评分');
      }
      rethrow;
    }
  }
  return planA;
}


/// 一次选股结果的「买卖预测价」。
///
/// ## 原则：不做点预测，做分布预测
///
/// 报一个目标价必然错。这里用策略自身的历史收益分位数推三个价位，
/// 全部来自回测报告里已有的统计量，**不引入任何新模型**：
///
/// ```
/// 入场价   = 当前收盘价（不是预测，就是今天的买入点）
/// 目标价   = 入场价 × (1 + 命中规则加权 avgReturn)      ← 中性预期
/// 乐观价   = 入场价 × (1 + 命中规则加权 p75)             ← 好的情形
/// 止损价   = 入场价 × (1 + 命中规则加权 p10)             ← 差的情形
/// 盈亏比   = (目标价 − 入场价) / (入场价 − 止损价)
/// ```
///
/// 加权口径与 [scoreOf] 一致（按信号量），两条路径必须给出同一批聚合值，
/// 否则"评分说好、价格说不好"会自相矛盾。
///
/// ## 什么时候必须留空
///
/// - **止损价 ≥ 入场价**（加权 p10 ≥ 0）：历史最差 10% 也是赚的，
///   分母变成负数，盈亏比是个负数——显示出来只会误导，直接给 null。
/// - **报告没有分位数字段**（2026-10-06 之前的旧报告）：止损/乐观价留 null，
///   目标价仍可用（avgReturn 是老字段）。UI 据此隐藏对应列。
/// - **无命中或无报告**：全空 + `lowConfidence`。
///
/// 所有价位都是**样本内**统计，衰减曲线（2026 年超额只剩 +8.7pp）意味着
/// 越近的年份越不可信。界面必须标注数据截止日。
class PriceForecast {
  const PriceForecast({
    required this.entry,
    required this.target,
    required this.stop,
    required this.optimistic,
    required this.riskReward,
    required this.lowConfidence,
    required this.reason,
  });

  /// 入场价（= 当前收盘价）。
  final double entry;

  /// 中性目标价；无可用统计时为 null。
  final double? target;

  /// 止损价；无分位数据或方向错误时为 null。
  final double? stop;

  /// 乐观目标价（p75）；无分位数据时为 null。
  final double? optimistic;

  /// 盈亏比；[stop] 为空或不在入场价下方时为 null。
  final double? riskReward;

  final bool lowConfidence;

  /// 降级原因（直接给 UI 展示）。
  final String reason;

  /// 相对入场价的预期涨跌幅（%），便于列表里以百分比展示。
  double? get targetPct =>
      target == null ? null : (target! / entry - 1) * 100;

  double? get stopPct => stop == null ? null : (stop! / entry - 1) * 100;
}

/// 给 [close]（当前收盘价）算一组的买卖预测价。签名与 [scoreOf] 对齐。
PriceForecast priceForecast(
  BacktestReport? report, {
  required double close,
  List<String> hitRuleIds = const [],
  int horizon = 10,
}) {
  if (report == null) {
    return PriceForecast(
      entry: close,
      target: null,
      stop: null,
      optimistic: null,
      riskReward: null,
      lowConfidence: true,
      reason: '暂无回测报告',
    );
  }
  if (report.baseline[horizon] == null) {
    return PriceForecast(
      entry: close,
      target: null,
      stop: null,
      optimistic: null,
      riskReward: null,
      lowConfidence: true,
      reason: '回测报告缺 $horizon 日基准',
    );
  }

  // 加权聚合（与 scoreOf 同口径）
  var gain = 0.0, w = 0.0, tail10 = 0.0, tail75 = 0.0, w10 = 0.0, w75 = 0.0;
  var count = 0;
  var allHave10 = true, allHave75 = true, any = false;
  for (final id in hitRuleIds) {
    final st = report.result(id, horizon);
    if (st == null || st.count <= 0) continue;
    final ww = st.count.toDouble();
    any = true;
    gain += st.avgReturn * ww;
    w += ww;
    count += st.count;
    if (st.p10 == null) {
      allHave10 = false;
    } else {
      tail10 += st.p10! * ww;
      w10 += ww;
    }
    if (st.p75 == null) {
      allHave75 = false;
    } else {
      tail75 += st.p75! * ww;
      w75 += ww;
    }
  }
  if (!any || count == 0 || w == 0) {
    return PriceForecast(
      entry: close,
      target: null,
      stop: null,
      optimistic: null,
      riskReward: null,
      lowConfidence: true,
      reason: '未命中任何已回测规则',
    );
  }

  final avg = gain / w;
  final target = close * (1 + avg / 100);
  // 全都有分位才报；缺一条就整体缺口，避免用部分规则的尾部冒充全体
  final p10 = allHave10 ? tail10 / w10 : null;
  final p75 = allHave75 ? tail75 / w75 : null;
  final stop = p10 == null ? null : close * (1 + p10 / 100);
  final optimistic = p75 == null ? null : close * (1 + p75 / 100);

  var reason = '';
  double? rr;
  if (stop == null) {
    reason = '报告缺分位数据，无法给止损';
  } else if (stop >= close) {
    reason = '历史最差一成也是盈利（p10≥0），无有效止损位';
  } else {
    final risk = close - stop;
    rr = risk <= 0 ? null : (target - close) / risk;
    if (rr != null && target <= close) {
      reason = '历史平均收益为负，目标价低于买入价';
    }
  }

  return PriceForecast(
    entry: close,
    target: target,
    stop: stop,
    optimistic: optimistic,
    riskReward: rr,
    lowConfidence: count < kScoreMinSampleCount || rr == null,
    reason: reason,
  );
}
