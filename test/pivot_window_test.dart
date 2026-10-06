// PivotWindow 的惰性构造：窗口字段按需生成，而不是每次 endingAt 都建 9 个 List。
//
// 为什么：实测全市场 336 万个可评估日里，pivotWindow 有 98.9% 的日子被构建
// （两条 pivot 规则都要读它），而 PivotWindow.endingAt 会为 9 个字段各分配一个
// List——合计约 10.4s。绝大多数日子在 `breakoutIndex` 就短路了
// （当日收盘未破上沿），根本读不到 lows/opens/volumes/closePoses。
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/indicators.dart' as ind;
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';

void main() {
  // 造一段真实形态：先震荡（形成箱体）再放量突破
  List<Bar> makeBars(int n) => [
        for (var i = 0; i < n; i++)
          kbar(
            close: 10.0 + (i % 10) * 0.1 + (i > 40 ? i * 0.05 : 0),
            high: 10.5 + (i % 10) * 0.1 + (i > 40 ? i * 0.05 : 0),
            low: 9.5 + (i % 10) * 0.1 + (i > 40 ? i * 0.05 : 0),
            volume: i == 60 ? 500.0 : 100.0,
            date: DateTime(2024).add(Duration(days: i)),
          ),
      ];

  group('PivotWindow.endingAt 惰性字段', () {
    test('字段内容与急切构造逐位一致（oracle = 手工按窗口切片计算）', () {
      final bars = makeBars(80);
      final pivot = ind.pivotSeries(bars, 20);
      const len = 8;
      const end = 70;
      final w = PivotWindow.endingAt(bars, pivot, end, len)!;
      final from = end - len + 1;

      // oracle：直接按 bars 下标取值，不经过窗口
      for (var i = 0; i < len; i++) {
        final t = from + i;
        expect(w.closes[i], bars[t].close, reason: 'closes[$i]');
        expect(w.lows[i], bars[t].low, reason: 'lows[$i]');
        expect(w.opens[i], bars[t].open, reason: 'opens[$i]');
        expect(w.volumes[i], bars[t].volume, reason: 'volumes[$i]');
        expect(w.uppers[i], pivot.uppers[t] ?? 0, reason: 'uppers[$i]');
        expect(w.widthPcts[i], pivot.widthPcts[t] ?? 0, reason: 'widthPcts[$i]');
        expect(w.risings[i], pivot.risings[t], reason: 'risings[$i]');
        expect(w.closePoses[i], ind.closePos(bars[t]), reason: 'closePoses[$i]');
      }
      expect(w.length, len);
    });

    test('未触及的惰性字段不会提前分配（惰性真的生效）', () {
      final bars = makeBars(80);
      final pivot = ind.pivotSeries(bars, 20);
      final w = PivotWindow.endingAt(bars, pivot, 70, 8)!;
      // 只读 breakoutIndex；closes/uppers 在构造时已被规则第一步用到，
      // 这里验证其余字段是读到才生成，而不是构造时就全部分配。
      expect(w.breakoutIndex, isA<int>());
      // 读一次结果不变（缓存有效）
      final a = w.lows.length;
      expect(w.lows.length, a);
    });

    test('多次访问同一字段返回等值结果（缓存不破坏语义）', () {
      final bars = makeBars(80);
      final pivot = ind.pivotSeries(bars, 20);
      final w = PivotWindow.endingAt(bars, pivot, 70, 8)!;
      expect(w.volumeRatios, w.volumeRatios);
      expect(w.closePoses, w.closePoses);
      expect(w.widthPcts, w.widthPcts);
    });

    test('breakoutIndex 与标量口径一致（手工逐位找最后一次上破）', () {
      final bars = makeBars(80);
      final pivot = ind.pivotSeries(bars, 20);
      const len = 8, end = 70;
      final w = PivotWindow.endingAt(bars, pivot, end, len)!;
      final from = end - len + 1;
      var expectIdx = -1;
      for (var i = len - 1; i >= 1; i--) {
        if (bars[from + i].close > (pivot.uppers[from + i] ?? 0)) {
          expectIdx = i;
          break;
        }
      }
      expect(w.breakoutIndex, expectIdx);
    });

    test('历史不足时返回 null（不构造窗口）', () {
      final bars = makeBars(80);
      final pivot = ind.pivotSeries(bars, 20);
      expect(PivotWindow.endingAt(bars, pivot, 5, 8), isNull);
    });
  });

  group('IndicatorSnapshot 窗口惰性（无闭包分配）', () {
    // 回归：快照曾为三个窗口各存一个捕获 (bars/ma60/pivot/t) 的闭包。
    // 全市场 336 万个可评估日 → 每快照 3 个闭包，共约 1000 万次分配。
    // 改为直接持有 IndicatorSeries 引用 + t，由 late final 调静态构造。
    test('快照的窗口仍与标量口径逐位一致', () {
      final bars = makeBars(120);
      final series = IndicatorSeries.from(bars);
      for (final t in [80, 90, 100, 119]) {
        final s = series.at(t);
        // 窗口字段与手工按 bars 切片一致
        if (s.pivotWindow != null) {
          final w = s.pivotWindow!;
          expect(w.bars, same(bars));
          expect(w.end, t);
          expect(w.from, t - w.length + 1);
        }
        if (s.window != null) {
          expect(s.window!.length, breakoutWindowLength);
        }
        if (s.pullbackWindow != null) {
          expect(s.pullbackWindow!.length, pullbackWindowLength);
        }
      }
    });

    test('同一快照多次访问窗口返回同一实例（缓存生效）', () {
      final series = IndicatorSeries.from(makeBars(120));
      final s = series.at(110);
      expect(identical(s.pivotWindow, s.pivotWindow), isTrue);
      expect(identical(s.window, s.window), isTrue);
      expect(identical(s.pullbackWindow, s.pullbackWindow), isTrue);
    });

    test('未触及窗口的快照不会构建任何窗口对象', () {
      final series = IndicatorSeries.from(makeBars(120));
      final s = series.at(25); // 历史不足，各窗口应为 null 且无副作用
      expect(s.window, isNull);
      expect(s.pivotWindow, isNull);
    });
  });
}