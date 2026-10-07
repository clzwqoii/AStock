/// 市场状态判定测试。期望值全部手算(见各用例注释),不依赖实现自算。
library;

import 'package:stock/core/market_state.dart';
import 'package:stock/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

StockData _stock(List<double> closes, {String symbol = 'T', int dayOffset = 0}) =>
    StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          Bar(
            date: DateTime(2026, 1, 1)
                .add(Duration(days: i + dayOffset)),
            open: closes[i],
            high: closes[i],
            low: closes[i],
            close: closes[i],
            volume: 100,
          ),
      ],
    );

void main() {
  group('classifyRegime(阈值边界,直接手算)', () {
    test('MA 上方 + ret20 达到 +3 → 牛市', () {
      expect(classifyRegime(maGap: 1.0, ret20: 3.0), MarketRegime.bull);
      expect(classifyRegime(maGap: 7.4, ret20: 5.0), MarketRegime.bull);
    });

    test('MA 上方但 ret20 未达 +3 → 震荡(反抽不算牛)', () {
      expect(classifyRegime(maGap: 1.0, ret20: 2.9), MarketRegime.sideways);
    });

    test('MA 下方 + ret20 达到 -3 → 熊市', () {
      expect(classifyRegime(maGap: -1.0, ret20: -3.0), MarketRegime.bear);
    });

    test('MA 下方 + 偏离 ≤ -5 → 熊市(即便近 20 日没再跌)', () {
      expect(classifyRegime(maGap: -5.0, ret20: 0.0), MarketRegime.bear);
    });

    test('MA 下方但偏离 -4.9、ret20 -2.9 → 震荡(慢跌磨底不算熊)', () {
      expect(classifyRegime(maGap: -4.9, ret20: -2.9), MarketRegime.sideways);
    });

    test('MA 上方 + ret20 = -1 → 震荡', () {
      expect(classifyRegime(maGap: 0.5, ret20: -1.0), MarketRegime.sideways);
    });
  });

  group('assessMarketState(小参数全手算)', () {
    // maPeriod=5, recentDays=10, statWindow=3。
    // 两只股票各 10 根:
    //   A = [10,10,10,10,10,10,10,10,10,10]
    //   B = [10,11,12,13,14,15,16,17,18,19]
    // 等权指数 = 两股均值:
    //   [10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 14, 14.5]
    // MA5 = (12.5+13+13.5+14+14.5)/5 = 13.5
    // maGap = (14.5-13.5)/13.5*100 = 7.407407...%
    // ret3(末值 / 3 根之前) = (14.5/13.0-1)*100 = 11.538462...% → 牛市
    // 宽度: A 末值 10 vs MA3(10,10,10)=10 → 不上穿(严格大于);
    //       B 末值 19 vs MA3(17,18,19)=18 → 上穿 → 1/2 = 0.5
    // 新高新低差: A 末值 10 同时是末 4 根的最大与最小 → 高低都算,净 0;
    //            B 末值 19 = 末 4 根最大 → 新高 → (2-1)/2 = 0.5
    final bull = assessMarketState(
      [_stock(List.filled(10, 10.0), symbol: 'A'),
       _stock([10.0, 11, 12, 13, 14, 15, 16, 17, 18, 19], symbol: 'B')],
      maPeriod: 5,
      recentDays: 10,
      statWindow: 3,
    );

    test('单边上涨 → 牛市', () {
      expect(bull.regime, MarketRegime.bull);
    });

    test('maGap 手算 = 7.4074%', () {
      expect(bull.maGap, closeTo(7.4074, 0.0001));
    });

    test('ret20 手算 = 11.5385%', () {
      expect(bull.ret20, closeTo(11.5385, 0.0001));
    });

    test('宽度手算 = 0.5', () {
      expect(bull.breadthAboveMa20, closeTo(0.5, 1e-9));
    });

    test('新高新低差手算 = 0.5', () {
      expect(bull.newHighLowDiff20, closeTo(0.5, 1e-9));
    });

    test('截至日与参与统计的股票数', () {
      expect(bull.asOfDate, '2026-01-10');
      expect(bull.stockCount, 2);
    });

    test('单边下跌 → 熊市(maGap = -8.6957%,ret3 = -12.5%)', () {
      // A 平,B = [20,19,18,17,16,15,14,13,12,11]
      // 指数 = [15,14.5,14,13.5,13,12.5,12,11.5,11,10.5]
      // MA5 = (12.5+12+11.5+11+10.5)/5 = 11.5
      // maGap = (10.5-11.5)/11.5*100 = -8.6957%
      // ret3 = (10.5/12.0-1)*100 = -12.5% → 熊市
      final r = assessMarketState(
        [_stock(List.filled(10, 10.0), symbol: 'A'),
         _stock([20, 19, 18, 17, 16, 15, 14, 13, 12, 11], symbol: 'B')],
        maPeriod: 5,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.bear);
      expect(r.maGap, closeTo(-8.6957, 0.0001));
    });

    test('MA 下方小幅回落 → 震荡', () {
      // 单只股票,指数 = 其收盘:
      //   [10,10,10,10,10,10.4,10.4,10.4,10.3,10.2]
      // MA5 = (10.4+10.4+10.4+10.3+10.2)/5 = 10.34
      // maGap = (10.2-10.34)/10.34*100 = -1.3540%
      // ret3  = (10.2/10.4-1)*100      = -1.9231% → 震荡
      final r = assessMarketState(
        [_stock([10, 10, 10, 10, 10, 10.4, 10.4, 10.4, 10.3, 10.2])],
        maPeriod: 5,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.sideways);
      expect(r.maGap, closeTo(-1.3540, 0.0001));
      expect(r.ret20, closeTo(-1.9231, 0.0001));
    });

    test('指数横盘但宽度分裂 → 震荡,新高新低差 = 0', () {
      // A = [10×7,11,12,13](尾端涨), B = [20×7,19,18,17](尾端跌)
      // 指数每日均值恒 = 15 → maGap = 0,ret3 = 0 → 震荡
      // 宽度: A 13 > MA3(11,12,13)=12 → 上;B 17 < MA3(19,18,17)=18 → 不上 → 0.5
      // 新高: A 13 = 末4最大 → 高;新低: B 17 = 末4最小 → 低 → (1-1)/2 = 0
      final r = assessMarketState(
        [_stock([10, 10, 10, 10, 10, 10, 10, 11, 12, 13], symbol: 'A'),
         _stock([20, 20, 20, 20, 20, 20, 20, 19, 18, 17], symbol: 'B')],
        maPeriod: 5,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.sideways);
      expect(r.breadthAboveMa20, closeTo(0.5, 1e-9));
      expect(r.newHighLowDiff20, closeTo(0.0, 1e-9));
    });

    test('交易日不足 recentDays → 用全部可用交易日', () {
      // 只有 6 个交易日,maPeriod=5 够,不判数据不足。
      // A = [10,10,10,10,10,11]: 指数 = A。
      // MA5 = (10+10+10+10+11)/5 = 10.2;maGap = (11-10.2)/10.2 = 7.8431%
      // ret3 = (11/10-1)*100 = 10% → 牛市
      final r = assessMarketState(
        [_stock([10, 10, 10, 10, 10, 11])],
        maPeriod: 5,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.bull);
      expect(r.maGap, closeTo(7.8431, 0.0001));
    });

    test('历史不足以同时算 MA 与 ret20 → 数据不足', () {
      // 6 个交易日 < maPeriod(8)。
      final r = assessMarketState(
        [_stock([10, 10, 10, 10, 10, 11])],
        maPeriod: 8,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.insufficient);
      expect(r.stockCount, 0);
    });

    test('交易日数恰 = maPeriod → 刚好够(边界)', () {
      // 8 个交易日 = maPeriod(8):MA 取全部 8 根,ret3 取末 4 根。
      // A = [10×7,11]:MA8 = (70+11)/8 = 10.125;maGap = (11-10.125)/10.125
      //   = 8.6420% ;ret3 = 10% → 牛市
      final r = assessMarketState(
        [_stock([10, 10, 10, 10, 10, 10, 10, 11])],
        maPeriod: 8,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.bull);
      expect(r.maGap, closeTo(8.6420, 0.0001));
    });

    test('太短的股票不进宽度/新高新低统计,但进等权指数', () {
      // A 10 根平盘,B 只有 3 根(= statWindow,不满足 statWindow+1)。
      // B 不进 stockCount;指数末 3 天被 B 的 30 拉高。
      // 指数末 3 天 = (10+30)/2 = 20;MA5 = (10+10+20+20+20)/5 = 16
      // maGap = (20-16)/16 = 25% ; ret3 = (20/10-1) = 100% → 牛市
      // 宽度只看 A:10 vs MA3(10,10,10)=10 → 不上穿 → 0/1 = 0
      final r = assessMarketState(
        [_stock(List.filled(10, 10.0), symbol: 'A'),
         _stock([30, 30, 30], symbol: 'B', dayOffset: 7)],
        maPeriod: 5,
        recentDays: 10,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.bull);
      expect(r.stockCount, 1);
      expect(r.breadthAboveMa20, closeTo(0.0, 1e-9));
    });

    test('末根滞后超过容忍值(停牌/退市)的股票不进宽度统计', () {
      // A 40 根(D1~D40);B 30 根(止于 D30,滞后 10 个交易日)。
      // B 尾端 20 → 20.5 → 21 → 21.5:末根 21.5 > MA3(20.5,21,21.5)=21 → 上穿,
      // 且逐根涨幅都在涨跌停内(不触发除权护栏,两个护栏互不干扰);
      // A 平盘 10 → 不上穿。
      // 容忍 3:B 被剔除 → 0/1 = 0;容忍 20:B 保留 → 1/2 = 0.5。
      final a = _stock(List.filled(40, 10.0), symbol: 'A');
      final b = _stock([...List.filled(27, 20.0), 20.5, 21.0, 21.5], symbol: 'B');

      final strict = assessMarketState([a, b],
          maPeriod: 5, recentDays: 40, statWindow: 3, maxLastBarLagTradingDays: 3);
      expect(strict.stockCount, 1);
      expect(strict.breadthAboveMa20, closeTo(0.0, 1e-9));

      final loose = assessMarketState([a, b],
          maPeriod: 5, recentDays: 40, statWindow: 3, maxLastBarLagTradingDays: 20);
      expect(loose.stockCount, 2);
      expect(loose.breadthAboveMa20, closeTo(0.5, 1e-9));
    });

    test('末根附近有除权断层的股票不进宽度统计', () {
      // B 末根 20 → 10(-50%,超主板 ±10% 涨跌停)→ 判除权,剔除;
      // 关掉除权护栏(回溯 0)则保留 —— 证明是护栏在起作用。
      final a = _stock(List.filled(40, 10.0), symbol: 'A');
      final b = _stock([...List.filled(39, 20.0), 10.0], symbol: 'B');

      final clean = assessMarketState([a, b],
          maPeriod: 5, recentDays: 40, statWindow: 3);
      expect(clean.stockCount, 1);

      final raw = assessMarketState([a, b],
          maPeriod: 5, recentDays: 40, statWindow: 3,
          corporateActionLookbackBars: 0);
      expect(raw.stockCount, 2);
    });

    test('除权断层离末根超过回溯期不影响计数', () {
      // B 第 6 根 20 → 10,之后 10 平盘到末根:距末根 34 根 > 20 → 保留。
      final a = _stock(List.filled(40, 10.0), symbol: 'A');
      final b = _stock([...List.filled(5, 20.0), ...List.filled(35, 10.0)],
          symbol: 'B');
      final r = assessMarketState([a, b],
          maPeriod: 5, recentDays: 40, statWindow: 3);
      expect(r.stockCount, 2);
    });

    test('JSON 往返', () {
      final j = bull.toJson();
      final back = MarketState.fromJson(j);
      expect(back.regime, bull.regime);
      expect(back.asOfDate, bull.asOfDate);
      expect(back.stockCount, bull.stockCount);
      expect(back.maGap, bull.maGap);
      expect(back.ret20, bull.ret20);
      expect(back.breadthAboveMa20, bull.breadthAboveMa20);
      expect(back.newHighLowDiff20, bull.newHighLowDiff20);
    });

    test('空股票列表 → 数据不足', () {
      expect(
        assessMarketState(const [], maPeriod: 5, recentDays: 10, statWindow: 3)
            .regime,
        MarketRegime.insufficient,
      );
    });

    test('recentDays 小于 need 时自动防御扩展，不抛 RangeError', () {
      // 10 根 K 线，maPeriod=8，但 recentDays 误传为 5 (< maPeriod 8)
      final r = assessMarketState(
        [_stock(List.filled(10, 10.0))],
        maPeriod: 8,
        recentDays: 5,
        statWindow: 3,
      );
      expect(r.regime, MarketRegime.sideways);
    });
  });
}
