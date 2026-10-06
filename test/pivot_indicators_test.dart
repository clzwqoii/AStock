import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/indicators.dart';
import 'package:stock/core/models.dart';


/// 造一串带指定 high/low 的 Bar，便于精确控制中枢上下沿。
List<Bar> box(String symbol, List<double> closes, List<double> highs, List<double> lows) => [
      for (var i = 0; i < closes.length; i++)
        Bar(
          date: DateTime(2024, 1, 1).add(Duration(days: i)),
          open: closes[i],
          high: highs[i],
          low: lows[i],
          close: closes[i],
          volume: 100,
          amount: closes[i] * 100,
        ),
    ];

void main() {
  group('highestHigh / lowestLow', () {
    test('默认不含当日（用历史箱体做压力位）', () {
      // 11 根：前 10 根 high 上限 10.4，末日 high=12
      final bars = box('T', List.filled(11, 10.0), [10.1, 10.15, 10.2, 10.05, 10.12, 10.2, 10.25, 10.3, 10.35, 10.4, 12.0],
          [9.9, 9.92, 9.95, 9.88, 9.9, 9.98, 9.95, 10.0, 10.05, 10.1, 11.0]);
      expect(highestHigh(bars, 10), closeTo(10.4, 1e-9));
      expect(lowestLow(bars, 10), closeTo(9.88, 1e-9));
    });

    test('skipLast=0 时含当日', () {
      final bars = box('T', List.filled(11, 10.0), [10.1, 10.15, 10.2, 10.05, 10.12, 10.2, 10.25, 10.3, 10.35, 10.4, 12.0],
          [9.9, 9.92, 9.95, 9.88, 9.9, 9.98, 9.95, 10.0, 10.05, 10.1, 11.0]);
      expect(highestHigh(bars, 10, skipLast: 0), closeTo(12.0, 1e-9));
      expect(lowestLow(bars, 10, skipLast: 0), closeTo(9.88, 1e-9));
    });

    test('历史不足返回 null', () {
      final bars = box('T', List.filled(5, 10.0), List.filled(5, 10.1), List.filled(5, 9.9));
      expect(highestHigh(bars, 10), isNull);
      expect(lowestLow(bars, 10), isNull);
      expect(highestHigh(bars, 0), isNull);
    });
  });

  group('pivotWidthPct 中枢宽度', () {
    test('(上沿-下沿)/下沿 × 100，与独立基准一致', () {
      final bars = box('T', List.filled(11, 10.0), [10.1, 10.15, 10.2, 10.05, 10.12, 10.2, 10.25, 10.3, 10.35, 10.4, 12.0],
          [9.9, 9.92, 9.95, 9.88, 9.9, 9.98, 9.95, 10.0, 10.05, 10.1, 11.0]);
      // (10.4-9.85)/9.85*100 = 5.5837...
      expect(pivotWidthPct(bars, 10), closeTo(5.263157894736838, 1e-9));
    });

    test('历史不足返回 null', () {
      final bars = box('T', List.filled(5, 10.0), List.filled(5, 10.1), List.filled(5, 9.9));
      expect(pivotWidthPct(bars, 10), isNull);
    });
  });

  group('pivotRising 中枢方向', () {
    // 前 5 根 HH=10.35 LL=9.85；后 5 根 HH=10.4 LL=9.95 → 上升
    final up = box('T', List.filled(11, 10.0), [10.1, 10.15, 10.2, 10.05, 10.12, 10.2, 10.25, 10.3, 10.35, 10.4, 12.0],
        [9.9, 9.92, 9.95, 9.88, 9.9, 9.98, 9.95, 10.0, 10.05, 10.1, 11.0]);
    test('后半段高低点均高于前半段 → 上升', () {
      expect(pivotRising(up, 10), isTrue);
    });

    test('后半段低点更低 → 不是上升', () {
      // 后半段 LL 降到 9.8
      final dn = box('T', List.filled(11, 10.0),
          [10.1, 10.2, 10.4, 10.05, 10.3, 10.15, 10.25, 10.1, 10.35, 10.2, 12.0],
          [9.9, 9.95, 9.9, 9.85, 9.95, 9.9, 9.8, 9.85, 9.9, 9.95, 11.0]);
      expect(pivotRising(dn, 10), isFalse);
    });

    test('高低点持平 → 不是上升（必须严格抬高）', () {
      final flat = box('T', List.filled(11, 10.0), List.filled(11, 10.4), List.filled(11, 9.85));
      expect(pivotRising(flat, 10), isFalse);
    });

    test('历史不足或 n<2 返回 false', () {
      final bars = box('T', List.filled(5, 10.0), List.filled(5, 10.4), List.filled(5, 9.85));
      expect(pivotRising(bars, 10), isFalse);
      expect(pivotRising(box('T', List.filled(11, 10.0), List.filled(11, 10.4), List.filled(11, 9.85)), 1), isFalse);
    });
  });

  // 逐日序列版：回测逐日评规则时需要「第 t 天的箱体」，
  // 若每天重建 sublist(0,t) 再扫 n 根，单股就是 O(t×n)，全市场 O(n²)。
  // 序列版整条 O(n) 一次算完，且每个下标必须与标量版逐位一致。
  group('pivotSeries 与标量版逐位一致', () {
    test('序列值 == 标量版逐日取值', () {
      final bars = box('T', List.filled(11, 10.0),
          [10.1, 10.15, 10.2, 10.05, 10.12, 10.2, 10.25, 10.3, 10.35, 10.4, 12.0],
          [9.9, 9.92, 9.95, 9.88, 9.9, 9.98, 9.95, 10.0, 10.05, 10.1, 11.0]);
      const n = 10;
      final s = pivotSeries(bars, n);
      expect(s.uppers.length, bars.length);
      expect(s.widthPcts.length, bars.length);
      expect(s.risings.length, bars.length);
      for (var t = 0; t < bars.length; t++) {
        // 契约：对齐 `PivotWindow` 的旧调用点 `highestHigh(bars.sublist(0, t), n)`，
        // 不是对齐 `sublist(0, t+1)`。skipLast=1 使它实际考察 [t-1-n, t-2]，
        // 比 highestHigh 注释声称的窗口早一根——序列版必须照搬这个实际行为。
        final prefix = t == 0 ? const <Bar>[] : bars.sublist(0, t);
        expect(s.uppers[t], prefix.length < n ? null : highestHigh(prefix, n),
            reason: 'upper 第 $t 天不一致');
        expect(s.widthPcts[t], prefix.length < n ? null : pivotWidthPct(prefix, n),
            reason: 'width 第 $t 天不一致');
        expect(s.risings[t], prefix.length < 2 ? false : pivotRising(prefix, n),
            reason: 'rising 第 $t 天不一致');
      }
    });

    test('历史不足 n 根：uppers/widthPcts 为 null，risings 为 false', () {
      final bars = box('T', List.filled(5, 10.0), List.filled(5, 10.1), List.filled(5, 9.9));
      final s = pivotSeries(bars, 10);
      expect(s.uppers, everyElement(isNull));
      expect(s.widthPcts, everyElement(isNull));
      expect(s.risings, everyElement(isFalse));
    });

    test('n 非法（<=1）整条为 null/false，不抛', () {
      final bars = box('T', List.filled(11, 10.0), List.filled(11, 10.1), List.filled(11, 9.9));
      final s = pivotSeries(bars, 1);
      expect(s.uppers, everyElement(isNull));
      expect(s.risings, everyElement(isFalse));
    });

    test('空序列安全', () {
      final s = pivotSeries(const [], 10);
      expect(s.uppers, isEmpty);
    });
  });
}
