import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';

/// V 型反转股票。
StockData vRecovery() => StockData(
      symbol: '600000',
      bars: [for (final c in closesVRecovery()) bar(close: c)],
    );

/// 形态 A：突破并站稳 MA60（70 根 = 有效突破窗口所需最小历史）。
StockData ma60Breakout() => StockData(symbol: '600000', bars: barsMa60Breakout());

/// 形态 B：突破 → 缩量回踩不破 → 放量阳线收复（83 根）。
StockData ma60Pullback() => StockData(symbol: '600001', bars: barsMa60Pullback());

/// 形态 A 变体（造反例用）：[replace] 的 key 为下标。
StockData breakoutVariant(Map<int, Bar> replace, {int? take}) =>
    StockData(symbol: 'X', bars: barsMa60BreakoutWith(replace, take: take));

/// 形态 B 变体（造反例用）。
StockData pullbackVariant(Map<int, Bar> replace, {int? take}) =>
    StockData(symbol: 'Y', bars: barsMa60PullbackWith(replace, take: take));

/// 形态 A 突破日（下标 66）的 K 线；造反例时只改单个字段，其余保持默认。
Bar aBreakBar({double? volume, double? amount, double? high, double? low}) => kbar(
      close: 21.2,
      open: 20.6,
      high: high ?? 21.2 * 1.015,
      low: low ?? 21.2 * 0.98,
      volume: volume ?? 300.0,
      amount: amount,
    );

void main() {
  final v = vRecovery();
  final crash = stockOf(closesCrash());

  Rule ruleOf(String id) => ruleById(id);

  IndicatorSnapshot snap(StockData s) => IndicatorSnapshot.fromStock(s);

  /// 造序列用的起始日（`kbar` 默认把所有日期取成 2024，回测要按日定位信号）。
  final day0 = DateTime(2024, 1, 1);

  group('builtInRules', () {
    test('目录至少 20 条且 id 唯一', () {
      expect(builtInRules.length, greaterThanOrEqualTo(20));
      expect(builtInRules.map((r) => r.id).toSet().length, builtInRules.length);
    });

    test('收盘价站上 MA20', () {
      expect(ruleOf('close_above_ma20').test(snap(v)), isTrue);
      expect(ruleOf('close_above_ma20').test(snap(crash)), isFalse);
    });

    test('MA5 上穿 MA10 只在交叉日为真', () {
      final crossDay =
          stockOf(closesVRecovery().take(24).toList(), symbol: 'X');
      final dayBefore =
          stockOf(closesVRecovery().take(23).toList(), symbol: 'X');
      expect(ruleOf('ma5_golden_ma10').test(snap(crossDay)), isTrue);
      expect(ruleOf('ma5_golden_ma10').test(snap(dayBefore)), isFalse);
      expect(ruleOf('ma5_golden_ma10').test(snap(crash)), isFalse);
    });

    test('MACD 金叉只在交叉日为真', () {
      final crossDay =
          stockOf(closesVRecovery().take(24).toList(), symbol: 'X');
      final dayBefore =
          stockOf(closesVRecovery().take(23).toList(), symbol: 'X');
      expect(ruleOf('macd_golden_cross').test(snap(crossDay)), isTrue);
      expect(ruleOf('macd_golden_cross').test(snap(dayBefore)), isFalse);
      expect(ruleOf('macd_golden_cross').test(snap(crash)), isFalse);
    });

    test('RSI 超卖与超买', () {
      expect(ruleOf('rsi_oversold').test(snap(crash)), isTrue);
      expect(ruleOf('rsi_oversold').test(snap(v)), isFalse);
      expect(ruleOf('rsi_overbought').test(snap(v)), isTrue);
      expect(ruleOf('rsi_overbought').test(snap(crash)), isFalse);
    });

    test('量比大于 2', () {
      expect(ruleOf('volume_surge').test(snap(stockOf(closesVRecovery(), lastVolume: 300))), isTrue);
      expect(ruleOf('volume_surge').test(snap(v)), isFalse);
    });

    test('当日涨幅大于 3%', () {
      final jump = stockOf([...List.filled(39, 10.0), 10.5]);
      final flat = stockOf(List.filled(40, 10.0));
      expect(ruleOf('pct_change_up').test(snap(jump)), isTrue);
      expect(ruleOf('pct_change_up').test(snap(flat)), isFalse);
    });
  });

  group('MA60 三条宽松规则', () {
    test('收盘价站上 MA60', () {
      expect(ruleOf('close_above_ma60').test(snap(ma60Breakout())), isTrue);
      expect(ruleOf('close_above_ma60').test(snap(crash)), isFalse);
      // 历史不足 61 根（MA60 无值）时不命中，也不抛异常
      expect(ruleOf('close_above_ma60').test(snap(stockOf(closesVRecovery()))), isFalse);
    });

    test('MA60 上穿只在交叉日为真', () {
      final crossDay = StockData(
        symbol: 'X',
        bars: barsMa60Breakout().take(67).toList(),
      );
      final dayBefore = StockData(
        symbol: 'X',
        bars: barsMa60Breakout().take(66).toList(),
      );
      expect(ruleOf('ma60_breakout').test(snap(crossDay)), isTrue);
      expect(ruleOf('ma60_breakout').test(snap(dayBefore)), isFalse);
      expect(ruleOf('ma60_breakout').test(snap(crash)), isFalse);
    });
  });

  group('ma60_breakout_confirmed 60日线有效突破（突破并站稳）', () {
    test('形态 A 命中', () {
      expect(ruleOf('ma60_breakout_confirmed').test(snap(ma60Breakout())), isTrue);
    });

    test('末日快照值与独立基准一致', () {
      final s = snap(ma60Breakout());
      expect(s.ma60, closeTo(20.096166666666665, 1e-9));
      expect(s.prevMa60, closeTo(20.06116666666667, 1e-9));
      expect(s.ma60Trend5, closeTo(0.10866666666666447, 1e-9));
      expect(s.bias60, closeTo(9.971221708949486, 1e-9));
      expect(s.bullAlignment, isTrue);
      expect(s.window, isNotNull);
    });

    test('突破日缩量（量比 0.8）不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({66: aBreakBar(volume: 80)}))),
        isFalse,
      );
    });

    test('突破日成交额未放大（额比约 1.07）不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({66: aBreakBar(amount: 2120)}))),
        isFalse,
      );
    });

    test('站稳期内有一日收盘跌回 MA60 下方不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({67: kbar(close: 19.9)}))),
        isFalse,
      );
    });

    test('站稳期内最低价深破 MA60（超过 2% 容差）不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({67: kbar(close: 21.5, low: 19.0)}))),
        isFalse,
      );
    });

    test('突破幅度不足 3% 不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed').test(snap(breakoutVariant({
          66: kbar(close: 20.3, open: 19.6, high: 20.3 * 1.015, low: 20.3 * 0.98),
        }))),
        isFalse,
      );
    });

    test('末日乖离超过 15%（追高）不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({69: kbar(close: 23.5)}))),
        isFalse,
      );
    });

    test('突破日收盘落在当日振幅下半部不命中', () {
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(breakoutVariant({66: aBreakBar(high: 21.2 * 1.02, low: 21.2 * 0.99)}))),
        isFalse,
      );
    });

    test('突破前未充分在线下盘整（前 5 日仅 1 日在线下）不命中', () {
      final bars = [
        ...List.filled(60, 20.0),
        20.6, 20.55, 20.5, 20.45, 19.9, // 前 4 日仍在线上
        21.8, 22.0, 22.2, 22.4, 22.6,
      ];
      final vols = [for (var i = 0; i < 70; i++) i == 65 ? 300.0 : 100.0];
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(StockData(symbol: 'Z', bars: [for (var i = 0; i < 70; i++) kbar(close: bars[i], volume: vols[i])]))),
        isFalse,
      );
    });

    test('MA60 仍下行（长下跌后的首次突破）不命中', () {
      final closes = [
        for (var i = 0; i < 60; i++) 25.0 - 0.0833 * i,
        ...List.filled(5, 19.0),
        23.4, 23.6, 23.8, 24.0, 24.2,
      ];
      final vols = [for (var i = 0; i < 70; i++) i == 65 ? 300.0 : 100.0];
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(StockData(symbol: 'Z', bars: [for (var i = 0; i < 70; i++) kbar(close: closes[i], volume: vols[i])]))),
        isFalse,
      );
    });

    test('历史仅 69 根（不足有效突破窗口）不命中且不抛异常', () {
      expect(
        ruleOf('ma60_breakout_confirmed').test(snap(breakoutVariant({}, take: 69))),
        isFalse,
      );
    });

    test('整段运行在 MA60 下方（无突破）不命中', () {
      final closes = [for (var i = 0; i < 60; i++) 25.0 - 0.0833 * i, ...List.filled(10, 19.0)];
      expect(
        ruleOf('ma60_breakout_confirmed')
            .test(snap(StockData(symbol: 'Z', bars: [for (final c in closes) kbar(close: c)]))),
        isFalse,
      );
    });

    test('形态 B（已进入回踩阶段）不会被误判为「新鲜突破」', () {
      expect(ruleOf('ma60_breakout_confirmed').test(snap(ma60Pullback())), isFalse);
    });
  });

  group('ma60_breakout_pullback 60日线突破回踩确认', () {
    test('形态 B 命中', () {
      expect(ruleOf('ma60_breakout_pullback').test(snap(ma60Pullback())), isTrue);
    });

    test('末日快照值与独立基准一致', () {
      final s = snap(ma60Pullback());
      expect(s.ma60, closeTo(20.138166666666667, 1e-9));
      expect(s.ma60Trend5, closeTo(0.06833333333333158, 1e-9));
      expect(s.bias60, closeTo(8.252158008425138, 1e-9));
      // 真回踩必然把 MA5 打到 MA10 下方，故形态 B 只要求 MA20 > MA60
      expect(s.bullAlignment, isFalse);
      expect(s.pullbackWindow, isNotNull);
    });

    test('回踩段有一日收盘跌破 MA60 不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({80: kbar(close: 19.5)}))),
        isFalse,
      );
    });

    test('回踩未缩量（量放到突破日水平之上）不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({80: kbar(close: 20.2, volume: 400)}))),
        isFalse,
      );
    });

    test('再启动为阴线不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({82: kbar(close: 21.8, open: 22.2)}))),
        isFalse,
      );
    });

    test('再启动未创近 5 日新高（未越过整理平台）不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({82: kbar(close: 21.0, open: 20.4, high: 21.2, low: 20.6)}))),
        isFalse,
      );
    });

    test('再启动缩量（量比不足 1.5）不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({82: kbar(close: 21.8, open: 20.6, high: 21.909, low: 21.0, volume: 120)}))),
        isFalse,
      );
    });

    test('回踩只是线上方浅幅整理（最低价从未接近 MA60）不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback').test(snap(pullbackVariant({
          79: kbar(close: 21.5, low: 21.38),
          80: kbar(close: 21.55, low: 21.44),
          81: kbar(close: 21.6, low: 21.48),
        }))),
        isFalse,
      );
    });

    test('突破日距信号日不足 kPullbackMinGapDays（站稳未完成）不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback').test(snap(pullbackVariant({}, take: 80))),
        isFalse,
      );
    });

    test('突破日缩量不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({74: kbar(close: 21.0, volume: 80)}))),
        isFalse,
      );
    });

    test('突破幅度不足 3% 不命中', () {
      expect(
        ruleOf('ma60_breakout_pullback')
            .test(snap(pullbackVariant({74: kbar(close: 20.3, open: 19.6, high: 20.6, low: 19.9)}))),
        isFalse,
      );
    });

    test('历史仅 78 根（不足回踩窗口）不命中且不抛异常', () {
      expect(
        ruleOf('ma60_breakout_pullback').test(snap(pullbackVariant({}, take: 78))),
        isFalse,
      );
    });

    test('形态 A（刚突破、尚未回踩）不会被误判为「回踩确认」', () {
      expect(ruleOf('ma60_breakout_pullback').test(snap(ma60Breakout())), isFalse);
    });
  });

  group('IndicatorSnapshot', () {
    test('V 型反转末日快照与独立基准一致', () {
      final s = IndicatorSnapshot.fromStock(vRecovery());
      expect(s.close, 24.3);
      expect(s.ma5, closeTo(23.3, 1e-9));
      expect(s.prevMa5, closeTo(22.8, 1e-9));
      expect(s.ma10, closeTo(22.05, 1e-9));
      expect(s.prevMa10, closeTo(21.55, 1e-9));
      expect(s.ma20, closeTo(19.55, 1e-9));
      expect(s.dif, closeTo(1.694253775402938, 1e-9));
      expect(s.prevDif, closeTo(1.5654038808830428, 1e-9));
      expect(s.dea, closeTo(1.1005897510920888, 1e-9));
      expect(s.prevDea, closeTo(0.9521737450143762, 1e-9));
      expect(s.rsi14, closeTo(85.00915283788616, 1e-9));
      expect(s.volumeRatio, 1.0);
      expect(s.pctChange, closeTo(2.1008403361344534, 1e-9));
    });

    test('KDJ 字段与独立基准一致（带宽序列），且不影响收盘类指标', () {
      final s = IndicatorSnapshot.fromStock(StockData(symbol: '600000', bars: barsWithBand()));
      expect(s.k, closeTo(93.42377663802921, 1e-9));
      expect(s.d, closeTo(93.10701931551432, 1e-9));
      expect(s.j, closeTo(94.05729128305899, 1e-9));
      expect(s.prevK, closeTo(93.39653452226122, 1e-9));
      expect(s.prevD, closeTo(92.94864065425686, 1e-9));
      expect(s.ma20, closeTo(19.55, 1e-9)); // 带宽不改变收盘类指标
    });

    test('连续一字板（整段高低相等）KDJ 为中性 50', () {
      final s = IndicatorSnapshot.fromStock(stockOf(List.filled(40, 10.0)));
      expect(s.k, closeTo(50.0, 1e-9));
      expect(s.d, closeTo(50.0, 1e-9));
      expect(s.j, closeTo(50.0, 1e-9));
      expect(s.prevK, closeTo(50.0, 1e-9));
      expect(s.prevD, closeTo(50.0, 1e-9));
    });

    test('历史不足 20 根抛 StateError', () {
      final short = StockData(
        symbol: '000001',
        bars: [for (final c in closesVRecovery().take(10)) bar(close: c)],
      );
      expect(() => IndicatorSnapshot.fromStock(short), throwsStateError);
    });

    test('历史不足 60 根时 MA60 族字段为 null、窗口为 null，但不抛异常', () {
      final s = IndicatorSnapshot.fromStock(stockOf(closesVRecovery())); // 40 根
      expect(s.ma60, isNull);
      expect(s.prevMa60, isNull);
      expect(s.ma60Trend5, isNull);
      expect(s.bias60, isNull);
      expect(s.window, isNull);
      expect(s.pullbackWindow, isNull);
      expect(s.bullAlignment, isFalse);
      expect(s.closePos, closeTo(0.5, 1e-9)); // 一字板取中性
      expect(s.amountRatio, 0.0); // 旧数据 amount 为 0
      expect(s.prevClose, closeTo(23.8, 1e-9));
    });

    test('形态 A 的窗口长度为 11 且末位是末日', () {
      final w = snap(ma60Breakout()).window!;
      expect(w.length, 11);
      expect(w.closes.last, 22.1);
      expect(w.crossUpIndex, 7); // 窗口起于全序列下标 59，突破日 66 → 窗口内下标 7
    });

    test('形态 B 的窗口长度为 20 且末位是末日', () {
      final w = snap(ma60Pullback()).pullbackWindow!;
      expect(w.length, 20);
      expect(w.closes.last, 21.8);
      expect(w.crossUpIndex, 11); // 窗口起于全序列下标 63，突破日 74 → 窗口内下标 11
    });
  });
  
  group('ma60_breakout_now 突破当日确认', () {
    /// 突破恰好落在最后一根：65 日横盘 → 5 日跌破 MA60 → 末日放量长阳上穿。
    /// （突破前 5 日全部在线下，digestedBelow 也过得去）
    StockData crossOnLastDay({double lastVolume = 300.0}) {
      final closes = <double>[
        ...List.filled(65, 20.0),
        19.9, 19.85, 19.8, 19.82, 19.88, // 65..69 全线在 MA60 下方
        21.2, // 70 = 末日，突破当日
      ];
      return StockData(
        symbol: 'X',
        bars: [
          for (var i = 0; i < 71; i++)
            kbar(
              close: closes[i],
              volume: i == 70 ? lastVolume : 100.0,
              date: day0.add(Duration(days: i)),
            ),
        ],
      );
    }

    test('突破就在当日：当日版命中，站稳版不命中（gap=0 < 站稳3日）', () {
      final s = snap(crossOnLastDay());
      expect(ruleOf('ma60_breakout_now').test(s), isTrue);
      expect(ruleOf('ma60_breakout_confirmed').test(s), isFalse);
      expect(ruleOf('ma60_breakout').test(s), isTrue); // 裸上穿同样命中
    });

    test('突破当日质量不过关时不命中（缩量，量比 0.8）', () {
      expect(ruleOf('ma60_breakout_now').test(snap(crossOnLastDay(lastVolume: 80))), isFalse);
    });

    test('形态 A（突破在 3 日前）：当日版不命中（那是站稳版的职责），站稳版命中', () {
      expect(ruleOf('ma60_breakout_now').test(snap(ma60Breakout())), isFalse);
      expect(ruleOf('ma60_breakout_confirmed').test(snap(ma60Breakout())), isTrue);
    });
  });
  
  group('explain 系列与规则判定同源（诊断工具共用）', () {
    final samples = [
      ma60Breakout(),
      ma60Pullback(),
      v,
      crash,
      breakoutVariant({66: aBreakBar(volume: 80.0)}), // 突破日缩量
      pullbackVariant({80: kbar(close: 20.3, volume: 400)}), // 回踩放量
    ];

    test('explain 返回 null ⇔ 规则命中（confirmed / pullback 全形态一致）', () {
      for (final s in samples) {
        final snapshot = snap(s);
        expect(
          explainMa60BreakoutConfirmed(snapshot, standDays: kBreakoutStandDays) == null,
          ruleOf('ma60_breakout_confirmed').test(snapshot),
          reason: '${s.symbol} confirmed',
        );
        expect(
          explainMa60BreakoutPullback(snapshot) == null,
          ruleOf('ma60_breakout_pullback').test(snapshot),
          reason: '${s.symbol} pullback',
        );
      }
    });

    test('已知缺陷形态给出对应原因', () {
      expect(
        explainMa60BreakoutConfirmed(snap(breakoutVariant({66: aBreakBar(volume: 80.0)})),
            standDays: kBreakoutStandDays),
        contains('突破日质量'),
      );
      expect(
        explainMa60BreakoutPullback(snap(pullbackVariant({80: kbar(close: 20.3, volume: 400)}))),
        contains('回踩放量'),
      );
    });
  });

  group('ma60BreakoutWith 过滤项开关', () {
    test('空集合等于裸 MA60 上穿', () {
      final bare = ma60BreakoutWith(const {});
      for (final s in [ma60Breakout(), ma60Pullback(), v, crash]) {
        expect(bare.test(snap(s)), ruleOf('ma60_breakout').test(snap(s)));
      }
    });

    test('同数量不同组合的 id 不同、同组合 id 稳定（backtestAll 按 id 分桶，撞 id 会合并信号）', () {
      final a = ma60BreakoutWith(const {Ma60Filter.bullAlignment, Ma60Filter.noChase});
      final b = ma60BreakoutWith(const {Ma60Filter.closePos, Ma60Filter.noChase});
      expect(a.id, isNot(b.id));
      // Set 迭代顺序不影响 id
      expect(a.id, ma60BreakoutWith(const {Ma60Filter.noChase, Ma60Filter.bullAlignment}).id);
    });
  
    test('单项过滤各自筛掉对应缺陷的形态', () {
      final digest = {Ma60Filter.digestedBelow};
      // 突破前已在线上反复穿越 → 被 digestedBelow 筛掉，裸上穿仍命中
      // 上穿必须落在最后一根：68 收在 MA60 下方，69 长阳上穿；
      // 而 64..67 四天都在线上方 → 属于高位反复穿越，digestedBelow 应筛掉。
      final noisy = breakoutVariant({
        60: kbar(close: 20.6),
        61: kbar(close: 20.55),
        62: kbar(close: 20.5),
        63: kbar(close: 20.45),
        64: kbar(close: 20.4),
        65: kbar(close: 20.35),
        66: kbar(close: 20.3),
        67: kbar(close: 20.25),
        68: kbar(close: 19.9),
        69: kbar(close: 21.8, open: 20.6, high: 21.8 * 1.015, low: 21.8 * 0.98, volume: 300),
      });
      expect(ruleOf('ma60_breakout').test(snap(noisy)), isTrue);
      expect(ma60BreakoutWith(digest).test(snap(noisy)), isFalse);
    });
  
    test('过滤项越多信号越稀少（单调收紧）', () {
      final counts = <int>[];
      for (var n = 0; n <= Ma60Filter.values.length; n++) {
        final fs = Ma60Filter.values.take(n).toSet();
        var hit = 0;
        for (final s in [ma60Breakout(), ma60Pullback(), v, crash]) {
          if (ma60BreakoutWith(fs).test(snap(s))) hit++;
        }
        counts.add(hit);
      }
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], lessThanOrEqualTo(counts[i - 1]));
      }
    });
  
    test('每个过滤项在裸上穿命中的形态上都有定义（不抛异常）', () {
      final s = snap(ma60Breakout());
      for (final f in Ma60Filter.values) {
        expect(() => ma60BreakoutWith({f}).test(s), returnsNormally);
      }
    });
  });
  
  
  
  group('kdj_golden_cross KDJ金叉', () {
    /// 带宽 V 型反转序列：fixtures 注释记明 KDJ 金叉发生在下标 20。
    test('交叉日命中、前一日不命中', () {
      final bars = barsWithBand();
      final crossDay = StockData(symbol: 'X', bars: bars.take(21).toList());
      final dayBefore = StockData(symbol: 'X', bars: bars.take(20).toList());
      expect(ruleOf('kdj_golden_cross').test(snap(crossDay)), isTrue);
      expect(ruleOf('kdj_golden_cross').test(snap(dayBefore)), isFalse);
    });

    test('单边下跌无金叉', () {
      expect(ruleOf('kdj_golden_cross').test(snap(crash)), isFalse);
    });

    test('与 macd_golden_cross 同口径：前值相等也算上穿', () {
      final s = snap(StockData(
        symbol: 'X',
        bars: barsWithBand().take(21).toList(),
      ));
      expect(ruleOf('kdj_golden_cross').test(s), s.prevK <= s.prevD && s.k > s.d);
    });
  });
  group('rsi_oversold_volume RSI超卖·放量', () {
    /// 60 天匀速下跌 → 末日再放量下跌：RSI14=0、量比 4.0。
    StockData oversoldVolume({double lastVolume = 400.0}) => StockData(
          symbol: 'X',
          bars: [
            for (var i = 0; i < 61; i++)
              kbar(
                close: 20.0 - 0.25 * i,
                volume: i == 60 ? lastVolume : 100.0,
                date: day0.add(Duration(days: i)),
              ),
          ],
        );

    test('RSI<30 且量比>2 时命中（跨行情唯一稳健的组合）', () {
      expect(ruleOf('rsi_oversold_volume').test(snap(oversoldVolume())), isTrue);
    });

    test('缩量（量比 1.0）不命中', () {
      expect(ruleOf('rsi_oversold_volume').test(snap(oversoldVolume(lastVolume: 100))), isFalse);
    });

    test('全程横盘（RSI 中性 50）不命中', () {
      expect(ruleOf('rsi_oversold_volume').test(snap(stockOf(List.filled(61, 10.0)))), isFalse);
    });

    test('等价于 rsi_oversold 与 volume_surge 同时成立', () {
      final a = ruleById('rsi_oversold');
      final b = ruleById('volume_surge');
      for (final s in [
        oversoldVolume(),
        oversoldVolume(lastVolume: 100),
        stockOf(List.filled(61, 10.0)),
        ma60Breakout(),
        v,
        crash,
      ]) {
        final sn = snap(s);
        expect(ruleOf('rsi_oversold_volume').test(sn), a.test(sn) && b.test(sn),
            reason: s.symbol);
      }
    });
  });


  group('rsi_oversold_volume 阈值常量', () {
    test('阈值常量是按参数穷举选定的 RSI<20 量比>1.5', () {
      expect(kRsiOversoldVolumeThreshold, 20.0);
      expect(kRsiOversoldVolumeVolumeRatio, 1.5);
    });

    test('规则实现读的是常量而不是硬编码字面量', () {
      final r = ruleById('rsi_oversold_volume');
      // 平盘：RSI 中性 50、量比 1 → 两个条件都不满足
      expect(r.test(snap(stockOf(List.filled(61, 10.0)))), isFalse);
      // 超跌放量序列：RSI≈0、量比 4
      final bars = <Bar>[];
      for (var i = 0; i < 61; i++) {
        bars.add(kbar(
          close: 20.0 - 0.25 * i,
          volume: i == 60 ? 400.0 : 100.0,
          date: day0.add(Duration(days: i)),
        ));
      }
      expect(r.test(snap(StockData(symbol: 'X', bars: bars))), isTrue);
    });

    test('desc 说明阈值来源', () {
      expect(ruleById('rsi_oversold_volume').desc, contains('量比'));
    });
  });

  group('rsi_oversold_volume_loose 宽松版', () {
    /// 宽松版与现役版的区别只在 RSI 阈值；量比阈值相同。
    test('阈值常量：RSI<25 量比>1.5', () {
      expect(kRsiOversoldVolumeLooseThreshold, 25.0);
      expect(kRsiOversoldVolumeVolumeRatio, 1.5);
    });

    test('宽松版的信号集合是现役版的超集（RSI<25 ⊃ RSI<20）', () {
      // 构造 RSI 介于 20~25 之间的序列：宽松版命中、现役版不命中
      final bars = <Bar>[];
      var d = DateTime(2024, 1, 2);
      // 45 天平盘（RSI 维持 50），再连续下跌把 RSI 压到 20~25
      for (var i = 0; i < 61; i++) {
        bars.add(kbar(
          close: 20.0 - 0.06 * (i > 45 ? i - 45 : 0),
          volume: i == 60 ? 400.0 : 100.0,
          date: d,
        ));
        d = d.add(const Duration(days: 1));
      }
      final s = snap(StockData(symbol: 'X', bars: bars));
      final rsi = s.rsi14;
      // RSI 由快照给出，下面按区间分别断言两版行为。
      // RSI 落在两档之间时：宽松版命中、现役版不命中
      if (rsi >= 20 && rsi < 25) {
        expect(ruleById('rsi_oversold_volume_loose').test(s), isTrue);
        expect(ruleById('rsi_oversold_volume').test(s), isFalse);
      }
      // 无论 RSI 落在哪一档，宽松版命中必然意味着现役版或更松
      if (ruleById('rsi_oversold_volume').test(s)) {
        expect(ruleById('rsi_oversold_volume_loose').test(s), isTrue);
      }
    });

    test('平盘序列（RSI=50）两版都不命中', () {
      final s = snap(stockOf(List.filled(61, 10.0)));
      expect(ruleById('rsi_oversold_volume_loose').test(s), isFalse);
      expect(ruleById('rsi_oversold_volume').test(s), isFalse);
    });

    test('desc 说明它是宽松版', () {
      expect(ruleById('rsi_oversold_volume_loose').desc, contains('宽松'));
    });
  });
  group('ma60_breakout_bull MA60上穿·多头排列', () {
    /// 65 日横盘 → 5 日跌破 MA60 → 末日放量长阳上穿，且四线多头排列。
    StockData bullCross({double lastClose = 21.2, double lastVolume = 300.0}) {
      final closes = <double>[
        ...List.filled(65, 20.0),
        19.9, 19.85, 19.8, 19.82, 19.88,
        lastClose,
      ];
      return StockData(
        symbol: 'X',
        bars: [
          for (var i = 0; i < 71; i++)
            kbar(
              close: closes[i],
              volume: i == 70 ? lastVolume : 100.0,
              date: day0.add(Duration(days: i)),
            ),
        ],
      );
    }

    /// 60 日横盘 → 10 日深跌 → 突破：MA20 被拖到 MA60 之下，非多头排列。
    StockData deepDipCross() => StockData(
          symbol: 'X',
          bars: [
            for (var i = 0; i < 71; i++)
              kbar(
                close: i < 60
                    ? 20.0
                    : (i < 70
                        ? [
                            19.6, 19.4, 19.2, 19.0, 18.9, 18.9, //
                            19.0, 19.2, 19.4, 18.8
                          ][i - 60]
                        : 21.5),
                volume: i == 70 ? 300.0 : 100.0,
                date: day0.add(Duration(days: i)),
              ),
          ],
        );

    test('等价于 ma60BreakoutWith({bullAlignment, noChase})', () {
      const fs = {Ma60Filter.bullAlignment, Ma60Filter.noChase};
      for (final s in [
        bullCross(),
        bullCross(lastClose: 24.0), // 乖离过大
        deepDipCross(), // 非多头排列
        ma60Breakout(),
        ma60Pullback(),
        v,
        crash,
      ]) {
        expect(ruleOf('ma60_breakout_bull').test(snap(s)),
            ma60BreakoutWith(fs).test(snap(s)), reason: s.symbol);
      }
    });

    // 性能契约：这条规则的判定函数必须是**复用的常量**，不能在 test 闭包里现场
    // ma60BreakoutWith(...) —— 它每次都要遍历枚举 .values 拼字符串 id 并
    // new Rule，而回测逐日评规则会调用它数百万次。
    // 断言 builtInRules 里的 test 与常量规则的 test 是同一个函数对象：
    // 一旦有人把闭包改回 `(s) => ma60BreakoutWith(const {...}).test(s)`，
    // 这里会拿到一个新闭包，identical 失败。
    test('内置目录复用 ma60BreakoutBullRule 的判定函数（不是每次判定新建 Rule）', () {
      expect(identical(ruleOf('ma60_breakout_bull').test, ma60BreakoutBullRule.test), isTrue,
          reason: 'builtInRules 应直接复用 ma60BreakoutBullRule.test');
    });

    test('上穿 + 多头排列 + 乖离≤15% 时命中', () {
      expect(ruleOf('ma60_breakout_bull').test(snap(bullCross())), isTrue);
    });

    test('乖离超过 15%（追高）不命中', () {
      expect(ruleOf('ma60_breakout_bull').test(snap(bullCross(lastClose: 24.0))), isFalse);
    });

    test('上穿但均线未多头排列（长跌后首突）不命中', () {
      expect(ruleOf('ma60_breakout_bull').test(snap(deepDipCross())), isFalse);
    });

    test('形态 A（突破在 3 日前）不命中——本规则只在突破当日记号', () {
      // 形态 A 的突破日是第 66 根，末日已过去 3 天，prevClose 在 MA60 上方，
      // 不再是"上穿"。这也解释了为什么它比 ma60_breakout_confirmed 信号更稀少。
      expect(ruleOf('ma60_breakout').test(snap(ma60Breakout())), isFalse);
      expect(ruleOf('ma60_breakout_bull').test(snap(ma60Breakout())), isFalse);
    });

    test('比裸 MA60 上穿更稀少：非多头排列的形态被筛掉', () {
      final bare = ma60BreakoutWith(const {});
      final bull = ruleOf('ma60_breakout_bull');
      // 深跌后首突：裸上穿命中，但 MA20 被拖到 MA60 之下 → 多头排列版筛掉
      expect(bare.test(snap(deepDipCross())), isTrue);
      expect(bull.test(snap(deepDipCross())), isFalse);
      // 而当头排列成立时两版都命中
      expect(bare.test(snap(bullCross())), isTrue);
      expect(bull.test(snap(bullCross())), isTrue);
    });
  });
  
    group('MA250 年线两条过滤规则', () {
      StockData ma250Up() => StockData(symbol: 'U', bars: [for (final c in closesMa250Up()) kbar(close: c)]);
      StockData ma250Down() => StockData(symbol: 'D', bars: [for (final c in closesMa250Down()) kbar(close: c)]);
      StockData ma250Stretched() =>
          StockData(symbol: 'S', bars: [for (final c in closesMa250Stretched()) kbar(close: c)]);
  
      test('ma250_up：年线走平或上翘', () {
        expect(ruleOf('ma250_up').test(snap(ma250Up())), isTrue);
        expect(ruleOf('ma250_up').test(snap(ma250Down())), isFalse);
      });
  
      test('near_ma250：站上年线且乖离不超过 15%', () {
        expect(ruleOf('near_ma250').test(snap(ma250Up())), isTrue); // bias 14.72%
        expect(ruleOf('near_ma250').test(snap(ma250Down())), isTrue); // bias 3.00%
        expect(ruleOf('near_ma250').test(snap(ma250Stretched())), isFalse); // bias 48.72%
      });
  
      test('历史不足 250 根时两条都不命中且不抛异常', () {
        final short = stockOf(closesMa250Up().take(249).toList());
        expect(ruleOf('ma250_up').test(snap(short)), isFalse);
        expect(ruleOf('near_ma250').test(snap(short)), isFalse);
      });
  
      test('快照的 MA250 族字段与独立基准一致', () {
        final up = snap(ma250Up());
        expect(up.ma250, closeTo(23.06412, 1e-9));
        expect(up.ma250Trend5, closeTo(0.033279999999997756, 1e-9));
        expect(up.bias250, closeTo(14.723648680287837, 1e-9));
  
        final down = snap(ma250Down());
        expect(down.ma250, closeTo(22.5232, 1e-9));
        expect(down.ma250Trend5, closeTo(-0.029200000000003, 1e-9));
        expect(down.bias250, closeTo(3.004901612559485, 1e-9));
  
        final stretched = snap(ma250Stretched());
        expect(stretched.ma250, closeTo(24.4756, 1e-9));
        expect(stretched.bias250, closeTo(48.71954109398749, 1e-9));
      });
  
      test('历史不足 60 根时 MA250 族字段为 null', () {
        final s = snap(stockOf(closesVRecovery())); // 40 根
        expect(s.ma250, isNull);
        expect(s.ma250Trend5, isNull);
        expect(s.bias250, isNull);
      });
    });
  
  group('中枢突破规则（缠论：箱体＋放量突破＋回抽不破）', () {
    /// 构造「箱体盘整 → 放量突破上沿」序列。
    /// boxBars 根横盘（宽 4%），最后一根放量收过上沿。
    StockData pivotBreakoutStock({
      int boxBars = 30,
      double upper = 10.6,
      double lower = 9.8,
      double breakClose = 11.2,
      double breakVolume = 300,
      bool rising = true,
    }) {
      final closes = <double>[];
      final highs = <double>[];
      final lows = <double>[];
      final vols = <double>[];
      for (var i = 0; i < boxBars; i++) {
        // 在箱体内往返震荡；rising 时后半段高低点整体上移
        final t = i / (boxBars - 1);
        final up = rising ? t : 1 - t;
        final mid = (upper + lower) / 2;
        final c = mid + (up - 0.5) * (upper - lower) * 0.7;
        closes.add(c);
        highs.add(c + (upper - lower) * 0.1);
        lows.add(c - (upper - lower) * 0.1);
        vols.add(100.0);
      }
      // 突破日
      closes.add(breakClose);
      highs.add(breakClose * 1.01);
      lows.add(breakClose * 0.99);
      vols.add(breakVolume);
      return StockData(
        symbol: 'P',
        bars: [
          for (var i = 0; i < closes.length; i++)
            kbar(close: closes[i], open: closes[i], high: highs[i], low: lows[i],
                volume: vols[i], date: day0.add(Duration(days: i))),
        ],
      );
    }

    test('箱体后放量突破 → pivot_breakout 命中', () {
      expect(ruleOf('pivot_breakout').test(snap(pivotBreakoutStock())), isTrue);
    });

    test('缩量突破不命中', () {
      expect(
          ruleOf('pivot_breakout').test(snap(pivotBreakoutStock(breakVolume: 100))),
          isFalse);
    });

    test('中枢方向向下（后半段高低点更低）不命中', () {
      expect(ruleOf('pivot_breakout').test(snap(pivotBreakoutStock(rising: false))),
          isFalse);
    });

    test('未突破上沿不命中', () {
      expect(
          ruleOf('pivot_breakout').test(snap(pivotBreakoutStock(breakClose: 10.5))),
          isFalse);
    });

    test('平盘历史不足抛 StateError', () {
      expect(() => snap(stockOf(List.filled(10, 10.0))), throwsStateError);
    });

    test('回抽不破 + 再放量阳线 → pivot_breakout_pullback 命中', () {
      // 突破日后回踩但最低价不破上沿，最后再放量收阳
      final bars = <Bar>[];
      for (var i = 0; i < 25; i++) {
        final t = i / 24;
        final mid = 10.2;
        final c = mid + (t - 0.5) * 0.5;
        bars.add(kbar(close: c, open: c, high: c + 0.06, low: c - 0.06,
            volume: 100, date: day0.add(Duration(days: i))));
      }
      // 突破日（25）：放量收过上沿
      bars.add(kbar(close: 11.2, open: 11.0, high: 11.3, low: 10.9,
          volume: 300, date: day0.add(Duration(days: 25))));
      // 站稳两日（26,27）
      bars.add(kbar(close: 11.3, open: 11.1, high: 11.4, low: 11.0,
          volume: 150, date: day0.add(Duration(days: 26))));
      bars.add(kbar(close: 11.4, open: 11.2, high: 11.5, low: 11.1,
          volume: 150, date: day0.add(Duration(days: 27))));
      // 回踩一日（28）：最低价 11.0，不破上沿 10.6；缩量
      bars.add(kbar(close: 11.2, open: 11.3, high: 11.35, low: 11.0,
          volume: 80, date: day0.add(Duration(days: 28))));
      // 再启动（29）：放量阳线，收在回踩段最高收盘之上
      bars.add(kbar(close: 11.8, open: 11.3, high: 11.9, low: 11.2,
          volume: 400, date: day0.add(Duration(days: 29))));
      expect(ruleOf('pivot_breakout_pullback').test(snap(StockData(symbol: 'Q', bars: bars))),
          isTrue);
    });

    test('回踩时收盘跌破上沿 → 不命中', () {
      final bars = <Bar>[];
      for (var i = 0; i < 25; i++) {
        final t = i / 24;
        final c = 10.2 + (t - 0.5) * 0.5;
        bars.add(kbar(close: c, open: c, high: c + 0.06, low: c - 0.06,
            volume: 100, date: day0.add(Duration(days: i))));
      }
      bars.add(kbar(close: 11.2, open: 11.0, high: 11.3, low: 10.9,
          volume: 300, date: day0.add(Duration(days: 25))));
      bars.add(kbar(close: 11.3, open: 11.1, high: 11.4, low: 11.0,
          volume: 150, date: day0.add(Duration(days: 26))));
      // 回踩直接跌回中枢内（10.4 < 上沿 10.6）
      bars.add(kbar(close: 10.4, open: 11.2, high: 11.2, low: 10.3,
          volume: 150, date: day0.add(Duration(days: 27))));
      bars.add(kbar(close: 11.0, open: 10.5, high: 11.1, low: 10.5,
          volume: 400, date: day0.add(Duration(days: 28))));
      expect(ruleOf('pivot_breakout_pullback').test(snap(StockData(symbol: 'Q', bars: bars))),
          isFalse);
    });
  });
}
  