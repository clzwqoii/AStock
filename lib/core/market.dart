/// A 股交易制度层面的纯函数：涨跌停幅度与除权日识别。
///
/// 为什么单独一个文件：这两件事都不是"指标"，而是**行情数据的口径规则**。
/// 本地库存的是**不复权**价（AGENTS.md 行情口径第 6 条），于是每个除权日
/// 都会在价格序列上留下一个永久的价位断层：10 转 4 那天，前收 22.90 元、
/// 今开 16.63 元，"当日跌幅 −27.4%"里没有一分钱是真实盈亏。
/// RSI(Wilder 14) 要把这个假跌幅平滑掉要十几根 K 线，MA60 更久——
/// 不识别它，任何"超卖/放量/金叉"规则都会在除权后连续多日拿到假信号。
///
/// 与 [indicators] 的分工：那边算数值，这边判"这一天到底是不是正常交易日"。
library;

import 'models.dart';

/// 每只股票每日价格相对前收盘的涨跌停幅度（%），按代码规则判定。
///
/// 取值来自交易所现行制度：主板 ±10%、创业板(300/301)与科创板(688) ±20%、
/// 北交所(920) ±30%。ST 股是 ±5%，但 ST 在选股入口已被剔除，
/// 这里不再按名称判定——那需要 stocks 表，而这个函数要能在只有代码时调用。
double dailyLimitPct(String tsCode) {
  if (tsCode.startsWith('300') || tsCode.startsWith('301')) return 20;
  if (tsCode.startsWith('688')) return 20;
  if (tsCode.startsWith('920')) return 30;
  return 10;
}

/// 除权/复牌护栏的默认回溯根数。
///
/// 实测依据（全样本 11169 个主规则信号、10 日持有、基准胜率 49.7%，
/// `tool/diag_main_rule.dart`）：落在除权后 20 根内的信号 10 日胜率 40.6%、
/// 均收益 −0.32%，**低于无条件基准**；护栏回溯取 14 根（RSI14 平滑期）与
/// 20 根（MA20 期）的收益差别已经很小（81.9% vs 82.1%），再拉到 60 根只多剔
/// 0.7% 的信号。取 20 = 覆盖主规则的 RSI 族与 MA20 族。
const kCorporateActionLookbackBars = 20;

const _neverSeen = 1 << 20;

/// 逐日"距最近一次除权/复牌有几根 K 线"。
///
/// `out[i] == 0` 表示第 i 天本身就是除权日/复牌日，`1` 表示前一天是，
/// 以此类推。从未出现过异常跳空时为 [_neverSeen]。
///
/// 整条一次算清：回测逐日评估时这是 O(n) 与 O(n×回溯窗口) 的差别
/// （全市场 337 万个可评估日 × 20 根 = 6700 万次跳空判定）。
List<int> barsSinceCorporateAction(String tsCode, List<Bar> bars) {
  final out = List<int>.filled(bars.length, _neverSeen);
  for (var i = 1; i < bars.length; i++) {
    out[i] = isCorporateActionGap(tsCode, bars[i - 1], bars[i]) ? 0 : out[i - 1] + 1;
  }
  return out;
}

/// 第 [t] 天是否是"干净"的信号日：**近 [lookbackBars] 根内（含当日）没有
/// 除权除息、也没有长期停牌复牌**。
///
/// 只看信号当日是不够的：不复权价在除权日留下的是**永久性价位断层**，
/// RSI14 要十几根才能把那个假跌幅平滑掉，MA20/MA60 更久。不回溯就会在除权后
/// 连续多日拿到"假超卖"信号——而那些信号历史上跑不赢基准
/// （见 [kCorporateActionLookbackBars] 的实测数据）。
///
/// `lookbackBars <= 0` 时恒为 true（护栏关闭，用于复现旧口径做对照）。
bool isCleanSignalDay(
  String tsCode,
  List<Bar> bars,
  int t, {
  int lookbackBars = kCorporateActionLookbackBars,
}) {
  if (lookbackBars <= 0) return true;
  if (t < 1 || t >= bars.length) return true; // 无前一日可判，不静默丢信号
  final from = t - lookbackBars + 1 < 1 ? 1 : t - lookbackBars + 1;
  for (var i = from; i <= t; i++) {
    if (isCorporateActionGap(tsCode, bars[i - 1], bars[i])) return false;
  }
  return true;
}

/// 判定 [tsCode] 在 [cur] 这一天是否发生了除权除息或长期停牌复牌。
///
/// 依据只有一条但很硬：**正常交易日内的开盘价不可能偏离前收盘超过当日
/// 涨跌停幅度**（主板 ±10%、双创 ±20%、北交所 ±30%）。超过就只能是
/// - 除权除息：送股/转增/派息让价位机械下移（10 转 4 就是 −28.6%）；
/// - 长期停牌复牌：停牌期间的基本面变化一次性反映在开盘价上。
/// 两者的共同点是：这一天的"涨跌幅/RSI/量比"都不是真实交易形成的，
/// 拿它当信号就是在抄一个不存在的底。
///
/// [tolerancePct] 是容差（默认 1pp）：贴近涨跌停的合法开盘（如 −20.5% 的
/// 创业板）不应被判成除权。
///
/// 已知局限（诚实记录，别当成完备判定）：
/// - 北交所 ±30% 内的送转（如 10 转 3 = −23%）会被判成合法跌停开盘而漏检；
/// - 停牌仅一两天后复牌、开盘价仍在涨跌停内时同样漏检。
/// 彻底的解法是引入 tushare `adj_factor` 把库内价格统一到同一口径，
/// 那是数据层+口径的改动，不是这个函数能覆盖的。
bool isCorporateActionGap(
  String tsCode,
  Bar prev,
  Bar cur, {
  double tolerancePct = 1.0,
}) {
  if (prev.close <= 0) return false; // 脏数据：宁可漏判也不静默丢信号
  final gap = (cur.open / prev.close - 1) * 100;
  return gap.abs() > dailyLimitPct(tsCode) + tolerancePct;
}
