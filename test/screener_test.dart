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
}
