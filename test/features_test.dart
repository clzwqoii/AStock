import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/features.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';

/// 30 根线性上行。用真实序列而不是手搓快照：
/// `IndicatorSnapshot` 只有私有构造器，公开入口是 `IndicatorSeries.at(t)`，
/// 走真实路径才不会测出一个和线上不一致的假对象。
IndicatorSeries rising() {
  final bars = [
    for (var i = 0; i < 30; i++)
      kbar(
        close: 10 + i * 0.1,
        open: 10 + i * 0.1,
        high: 10 + i * 0.1 + 0.05,
        low: 10 + i * 0.1 - 0.05,
        volume: 100 + i.toDouble(),
        date: DateTime(2024, 1, 1).add(Duration(days: i)),
      ),
  ];
  return IndicatorSeries.from(bars);
}

IndicatorSnapshot snapAt(IndicatorSeries s, int t) => s.at(t);

void main() {
  group('featureVector', () {
    test('固定维度与命名一一对应，且不含 NaN/inf', () {
      // 硬契约：系数 JSON 只存数字，顺序错一位整个模型报废。
      final v = featureVector(snapAt(rising(), 29), hitRuleIds: const []);
      expect(v.length, featureNames.length);
      for (var i = 0; i < featureNames.length; i++) {
        expect(v[i].isFinite, isTrue, reason: '${featureNames[i]} 出现 NaN/inf');
      }
    });

    test('bias20 由收盘价与 MA20 现算（不读可空字段）', () {
      // oracle（/tmp）：close=12.9, ma20=11.95 → bias20 = 7.949790795
      final v = featureVector(snapAt(rising(), 29), hitRuleIds: const []);
      expect(v[featureNames.indexOf('bias20')], closeTo(7.949790795, 1e-6));
    });

    test('历史不足 60 根时 bias60 等可空字段填 0，不炸', () {
      // 30 根 < 60，MA60 族为 null。填 0 而不是 NaN——
      // NaN 会顺着训练把整个模型污染掉。
      final v = featureVector(snapAt(rising(), 29), hitRuleIds: const []);
      expect(v[featureNames.indexOf('bias60')], 0);
      expect(v[featureNames.indexOf('ma60Trend5')], 0);
      for (final x in v) {
        expect(x.isFinite, isTrue);
      }
    });

    test('命中的规则转成 0/1，不改变维度', () {
      final v = featureVector(
        snapAt(rising(), 29),
        hitRuleIds: const ['rsi_oversold_volume'],
      );
      expect(v[featureNames.indexOf('rule_rsi_oversold_volume')], 1);
      expect(v[featureNames.indexOf('rule_kdj_golden_cross')], 0);
      expect(v.length, featureNames.length);
    });

    test('未登记但真实存在的规则 id 被忽略，不撑破维度', () {
      final v = featureVector(
        snapAt(rising(), 29),
        hitRuleIds: const ['pivot_breakout', '不存在'],
      );
      expect(v.length, featureNames.length);
      // 没登记的规则在向量里表现为全 0 的 rule_ 段
      expect(v.where((e) => e == 1).length, 0);
    });

    test('bullAlignment 布尔转 0/1', () {
      final v = featureVector(snapAt(rising(), 29), hitRuleIds: const []);
      final b = v[featureNames.indexOf('bullAlignment')];
      expect(b == 0 || b == 1, isTrue);
    });
  });
}
