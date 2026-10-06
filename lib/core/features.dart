/// 逻辑回归的输入特征：把 [IndicatorSnapshot] 摊平成固定顺序的向量。
///
/// ## 硬契约：顺序即接口
///
/// 系数 JSON 只存一串数字，**顺序错一位整个模型就报废**。所以
/// [featureNames] 是唯一事实来源，[featureVector] 按它取数，
/// 任何一侧改动都会让测试（维度/顺序断言）立刻红。
///
/// ## 为什么这些特征
///
/// 全部来自信号日**当天**及之前的快照，无前瞻。分三类：
///
/// 1. **超卖/动量**：rsi14、k/d/j、dif/dea。这是策略假设的核心——
///    「有量的超卖反弹」，模型要能区分 RSI=15 和 RSI=19。
/// 2. **量能**：volumeRatio、amountRatio、closePos。
/// 3. **位置/乖离**：bias20/60/250、均线趋势。控制"别在半山腰接刀"。
/// 4. **命中规则的 0/1**：让模型能吸收方案 A 已用到的离散信息，
///    从而 B 相对 A 是严格增强而不是另起一套假设。
///
/// ## 缺失值处理
///
/// MA60/MA250 族在历史不足时为 null，统一填 **0** 而不是 NaN：
/// 标准化后 0 会落在训练均值附近（如果训练集里同样缺），
/// 而 NaN 会顺着训练把整个模型污染成废料。
///
/// 乖离类做上限截断（[kBiasClampPct]）：一次涨停造成的 40% 乖离
/// 会把标准化拉歪，而它对"明天涨不涨"的信息量并不同比增加。
library;

import 'package:stock/core/rules.dart';

/// 乖离截断上限（%）。超出按此值计，防止极端值主导标准化。
const kBiasClampPct = 60.0;

/// 特征顺序。**改动即契约变更**，必须同步 `score-model.json` 并重训。
const featureNames = <String>[
  // 超卖 / 动量
  'rsi14',
  'k',
  'd',
  'j',
  'dif',
  'dea',
  'pctChange',
  // 量能
  'volumeRatio',
  'amountRatio',
  'closePos',
  // 位置 / 乖离
  'bias20',
  'bias60',
  'bias250',
  'ma60Trend5',
  'ma250Trend5',
  'bullAlignment',
  // 命中规则 0/1（由下方生成）
  ..._ruleFeaturePrefixes,
];

const _ruleFeaturePrefixes = <String>[
  'rule_rsi_oversold_volume',
  'rule_rsi_oversold_volume_loose',
  'rule_rsi_oversold',
  'rule_kdj_golden_cross',
  'rule_macd_golden_cross',
  'rule_close_above_ma20',
  'rule_close_above_ma60',
  'rule_volume_surge',
  'rule_pct_change_up',
  'rule_ma5_golden_ma10',
];

/// 把快照摊平成与 [featureNames] 等长、同序的向量。
///
/// [hitRuleIds] 命中哪些规则（id）。只认 [_ruleFeaturePrefixes] 里列出的，
/// 其余静默忽略——加新规则要在这里显式登记，避免"悄悄多出来的维度"
/// 让线上系数与训练时错位。
List<double> featureVector(IndicatorSnapshot s, {List<String> hitRuleIds = const []}) {
  final out = List<double>.filled(featureNames.length, 0);
  for (var i = 0; i < featureNames.length; i++) {
    final name = featureNames[i];
    final ruleId = _ruleIdOf[name];
    if (ruleId != null) {
      out[i] = hitRuleIds.contains(ruleId) ? 1 : 0;
    } else {
      out[i] = _scalarOf[name]?.call(s) ?? 0;
    }
  }
  return out;
}

/// 'rule_xxx' 特征名 → 规则 id 'xxx'。静态映射替代逐次 substring——
/// 训练按命中样本逐条调用（百万级），每次 10 个临时字符串是纯浪费。
final Map<String, String> _ruleIdOf = {
  for (final n in featureNames)
    if (n.startsWith('rule_')) n: n.substring(5),
};

/// 标量特征取值器。与 [featureNames] 非规则段一一对应（缺省 0 的语义不变）；
/// 静态 Map 让每次调用不再构建 16 项临时 Map。
final Map<String, double Function(IndicatorSnapshot)> _scalarOf = {
  'rsi14': (s) => s.rsi14,
  'k': (s) => s.k,
  'd': (s) => s.d,
  'j': (s) => s.j,
  'dif': (s) => s.dif,
  'dea': (s) => s.dea,
  'pctChange': (s) => s.pctChange,
  'volumeRatio': (s) => s.volumeRatio,
  'amountRatio': (s) => s.amountRatio,
  'closePos': (s) => s.closePos,
  'bias20': (s) => _bias(s.close, s.ma20),
  'bias60': (s) => s.bias60 ?? 0,
  'bias250': (s) => s.bias250 ?? 0,
  'ma60Trend5': (s) => s.ma60Trend5 ?? 0,
  'ma250Trend5': (s) => s.ma250Trend5 ?? 0,
  'bullAlignment': (s) => s.bullAlignment ? 1 : 0,
};

/// (收盘/均线 − 1) × 100，截断到 [kBiasClampPct]。
double _bias(double close, double ma) {
  if (ma <= 0) return 0;
  final v = (close / ma - 1) * 100;
  return v.isNaN ? 0 : v.clamp(-kBiasClampPct, kBiasClampPct);
}
