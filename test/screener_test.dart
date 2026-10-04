import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';

import 'fixtures.dart';

void main() {
  // 39 根横盘 10.0 + 最后一根 10.5（+5%）
  final bothPass = stockOf([...List.filled(39, 10.0), 10.5], symbol: 'S1', lastVolume: 300);
  final onlyPct = stockOf([...List.filled(39, 10.0), 10.5], symbol: 'S2');
  final onlyVolume = stockOf(List.filled(40, 10.0), symbol: 'S3', lastVolume: 300);
  final nonePass = stockOf(List.filled(40, 10.0), symbol: 'S4');
  final tooShort = stockOf(List.filled(10, 10.0), symbol: 'SHORT');
  final stocks = [bothPass, onlyPct, onlyVolume, nonePass, tooShort];

  final volume = ruleById('volume_surge');
  final pct = ruleById('pct_change_up');

  group('screen', () {
    test('组合规则 = 全部满足才入选', () {
      expect(screen(stocks, [volume, pct]).map((s) => s.symbol), ['S1']);
    });

    test('单规则选股（选哪条用哪条）', () {
      expect(screen(stocks, [pct]).map((s) => s.symbol), ['S1', 'S2']);
      expect(screen(stocks, [volume]).map((s) => s.symbol), ['S1', 'S3']);
    });

    test('空规则列表抛 ArgumentError', () {
      expect(() => screen(stocks, []), throwsArgumentError);
    });

    test('历史不足 20 根的股票被跳过', () {
      expect(screen([tooShort], [volume]), isEmpty);
    });
  });

  group('screenWithHits', () {
    test('返回每只入选股票命中的规则 id（组合 = 全部命中）', () {
      final hits = screenWithHits(stocks, [volume, pct]);
      expect(hits.map((h) => h.stock.symbol), ['S1']);
      expect(hits.single.matchedRuleIds, ['volume_surge', 'pct_change_up']);
    });

    test('规则顺序与传入一致，便于 UI 按勾选顺序展示', () {
      final hits = screenWithHits(stocks, [pct, volume]);
      expect(hits.single.matchedRuleIds, ['pct_change_up', 'volume_surge']);
    });

    test('单规则选股时命中列表就是那一条', () {
      expect(screenWithHits(stocks, [pct]).map((h) => h.matchedRuleIds.single), [
        'pct_change_up',
        'pct_change_up',
      ]);
    });

    test('空规则列表同样抛 ArgumentError（与 screen 一致）', () {
      expect(() => screenWithHits(stocks, []), throwsArgumentError);
    });

    test('与 screen 同口径：结果集完全一致', () {
      expect(screenWithHits(stocks, [volume, pct]).map((h) => h.stock), screen(stocks, [volume, pct]));
    });
  });
}
