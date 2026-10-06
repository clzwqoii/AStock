/// App/CLI 共用的重活入口：把 SQLite 读取与计算放进后台 isolate，避免卡 UI。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as h;
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/features.dart';
import 'package:stock/core/logreg.dart';
import 'package:stock/core/score.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/report_store.dart';
import 'package:stock/data/sina_client.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tushare_client.dart';

/// 当前应用版本（发布新包时同步修改，与 pubspec.version 保持一致）。
const kAppVersion = '2.5.0';

/// 更新清单候选源（并发竞速，第一个响应的胜出）。
/// 国内网络优先命中 Gitee；jsDelivr 镜像可加速 GitHub raw。建仓库后替换为你的地址。
const kUpdateCheckUrls = <String>[
  'https://gitee.com/clzwqoii/astock/raw/main/update.json', // 国内优先
  'https://raw.githubusercontent.com/clzwqoii/AStock/main/update.json',
  'https://cdn.jsdelivr.net/gh/clzwqoii/AStock@main/update.json', // GitHub CDN 镜像
];

/// 更新清单请求超时。
const kUpdateTimeout = Duration(seconds: 15);

class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    this.assets = const <String, String>{},
  });

  final String latestVersion;
  final String downloadUrl;

  /// 各平台安装包直链（键 android / macos / windows）；
  /// 缺失的平台没有应用内自更新条件（iOS 系统限制 / Windows 包未产出），走 [downloadUrl] 页面兜底。
  final Map<String, String> assets;
}

class _Attempt {
  _Attempt(this.info, this.error);

  /// 解析成功（[info] 为 null 表示已是最新）。
  final UpdateInfo? info;
  final Object? error;

  bool get ok => error == null;

  /// 承载本次尝试的 future（竞速结束后用它把自己从待办列表移除）。
  Future<_Attempt>? self;
}

/// 检查更新：并发请求所有候选源，第一个成功的决定结果（境内 Gitee / 境外 GitHub 自动分流）；
/// 某源失败自动换下一个，全部失败才抛错。
Future<UpdateInfo?> checkForUpdate({
  String? currentVersion,
  h.Client? client,
  List<String>? urls,
}) async {
  final cur = currentVersion ?? kAppVersion;
  final c = client ?? h.Client();
  Future<_Attempt> attempt(String url) async {
    try {
      final res = await c.get(Uri.parse(url)).timeout(kUpdateTimeout);
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final latest = data['version'] as String;
      final assetsRaw = data['assets'] as Map<String, dynamic>?;
      return _Attempt(_isNewer(latest, cur)
          ? UpdateInfo(
              latestVersion: latest,
              downloadUrl: (data['url'] ?? '') as String,
              assets: assetsRaw?.map((k, v) => MapEntry(k, v as String)) ?? const {},
            )
          : null, null);
    } catch (e) {
      return _Attempt(null, e);
    }
  }

  final pending = <Future<_Attempt>>[];
  for (final url in (urls ?? kUpdateCheckUrls)) {
    late final Future<_Attempt> f;
    f = attempt(url).then((a) {
      a.self = f;
      return a;
    });
    pending.add(f);
  }
  // 竞速，但不能被「某个源说没有新版」盖掉结论。
  //
  // update.json 刚发布时各源缓存刷新有差（真机实测：首次点检查更新说已是最新，
  // 再点一次才拿到新版本——先返回的是 CDN 上的旧版本）。所以：
  // - 任一源说「有新版」→ 立刻返回，不等其它源（慢源没理由推翻它）；
  // - 只有当**所有**源都说「无新版」或失败，才判定为「已是最新」。
  // 代价是最坏情况多等一个超时（15s），换来的是不会漏报新版本。
  Object? lastError;
  UpdateInfo? found;
  var anyUsable = false;
  while (pending.isNotEmpty) {
    final r = await Future.any(pending);
    pending.remove(r.self);
    if (!r.ok) {
      lastError = r.error;
      continue;
    }
    anyUsable = true;
    if (r.info != null) {
      found = r.info;
      break;
    }
  }
  if (found != null) return found;
  if (anyUsable) return null; // 所有可用源一致：已是最新
  throw lastError ?? StateError('没有可用的更新源');
}

bool _isNewer(String latest, String current) {
  List<int> parts(String v) =>
      v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// 一行选股结果的展示数据（工作台表格直接消费）。
/// [name] 为 null 表示本地名单未拉到，UI 需降级显示。
class ScreenRow {
  const ScreenRow({
    required this.symbol,
    required this.name,
    required this.close,
    required this.change,
    required this.changePct,
    required this.volumeRatio,
    required this.amountWan,
    required this.ma20,
    this.matchedRules = const [],
    this.score,
    this.forecast,
    this.signalDate = '',
    this.ret20 = 0,
  });

  final String symbol;
  final String? name;
  final double close;
  final double change;
  final double changePct;
  final double volumeRatio;
  final double amountWan;
  final double ma20;

  /// 信号日（该股最后一根 K 线的日期，`YYYY-MM-DD`）。护栏默认会把滞后
  /// [kMaxLastBarLagDays] 天以上的票挡掉，所以正常情况下它就是数据截止日；
  /// 停牌几周的票会短一些。
  final String signalDate;

  /// 信号日之前 20 个交易日的累计涨跌（%）。超卖/放量类规则选出来的必然是
  /// "已经跌了很多"的票，这一列让"我在抄什么底"一目了然，而不是只看当日涨跌。
  final double ret20;

  /// 命中的规则名（可多条；组合选股时按勾选顺序展示）。CLI/旧调用方可能为空。
  final List<String> matchedRules;

  /// 评分（0~100）。无回测报告时为 null——UI 必须显示"评分不可用"，
  /// 不能把 null 当 0 分展示成"最差"。
  final StockScore? score;

  /// 买卖预测价；分位数据缺失时其内部字段为 null，由 UI 隐藏对应列。
  final PriceForecast? forecast;
}

/// 结果表可排序列（与工作台表头一一对应；点表头切换升降序）。
enum SortField { close, changePct, volumeRatio, amount, ma20, score, riskReward }

/// 按 [field] 排序（默认降序）；同值保持入参顺序（稳定排序，表头重复点击不抖动）。
/// 返回新列表，不改 [rows]。
List<ScreenRow> sortRows(List<ScreenRow> rows, SortField field, {bool ascending = false}) {
  double? nullableValue(ScreenRow r) => switch (field) {
        SortField.score => r.score?.score,
        SortField.riskReward => r.forecast?.riskReward,
        _ => null,
      };
  double value(ScreenRow r) => switch (field) {
        SortField.close => r.close,
        SortField.changePct => r.changePct,
        SortField.volumeRatio => r.volumeRatio,
        SortField.amount => r.amountWan,
        SortField.ma20 => r.ma20,
        SortField.score => r.score?.score ?? double.negativeInfinity,
        SortField.riskReward => r.forecast?.riskReward ?? double.negativeInfinity,
      };
  final nullable = field == SortField.score || field == SortField.riskReward;
  final decorated = [for (var i = 0; i < rows.length; i++) (v: rows[i], i: i)];
  decorated.sort((a, b) {
    // 可空列的空值**恒沉底**，与升降序无关。
    // 曾经用负无穷当哨兵，结果降序沉底、升序浮顶——一行"暂无数据"爬到
    // 第一名比不显示更糟，所以这里显式判空。
    if (nullable) {
      final an = nullableValue(a.v);
      final bn = nullableValue(b.v);
      if (an == null || bn == null) {
        if (an == null && bn == null) return a.i.compareTo(b.i);
        return an == null ? 1 : -1;
      }
    }
    final c = value(a.v).compareTo(value(b.v));
    if (c != 0) return ascending ? c : -c;
    return a.i.compareTo(b.i);
  });
  return [for (final d in decorated) d.v];
}

/// CSV 单元格转义：含逗号/引号/换行时按 RFC4180 加双引号并转义内部引号。
String _csvCell(Object? v) {
  final s = v == null ? '' : '$v';
  return s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// 选股结果 → CSV 文本（UTF-8 文本，导出时由 [exportRowsCsv] 加 BOM 以便 Excel 识别中文）。
/// 第一行是说明行（含数据日期与规则组合），第二行起是表头与数据，列序与工作台表头一致。
String rowsToCsv(
  List<ScreenRow> rows, {
  String? dataDate,
  String? combo,
  bool withScore = false,
  bool withSignalDay = false,
}) {
  // 列序：默认与旧版逐字节一致。新列只追加在最后，且要显式传 [withScore] /
  // [withSignalDay] 才有——CSV 是被外部脚本消费的格式，"突然多出六列"会让它们
  // 整行错位。追加在最末列对按下标读的脚本是安全的，但严格校验列数的会炸。
  const scoreHeader = ',评分,档位,目标价,止损价,盈亏比,样本数,评分来源';
  const signalDayHeader = ',信号日,20日%';
  final buf = StringBuffer()
    ..writeln('# A股选股结果（不复权·手）'
        '${dataDate == null ? '' : '  数据截至 $dataDate'}'
        '${combo == null || combo.isEmpty ? '' : '  规则：$combo'}')
    ..writeln('代码,名称,收盘,涨跌,涨跌幅%,量比,成交额(万),MA20,数据截至,规则组合'
        '${withScore ? scoreHeader : ''}${withSignalDay ? signalDayHeader : ''}');
  for (final r in rows) {
    final cells = [
      _csvCell(r.symbol),
      _csvCell(r.name ?? ''),
      r.close.toStringAsFixed(2),
      '${r.change >= 0 ? '+' : '-'}${r.change.abs().toStringAsFixed(2)}',
      '${r.changePct >= 0 ? '+' : '-'}${r.changePct.abs().toStringAsFixed(2)}',
      r.volumeRatio.toStringAsFixed(2),
      r.amountWan.toStringAsFixed(2),
      r.ma20.toStringAsFixed(2),
      _csvCell(dataDate ?? ''),
      _csvCell(combo ?? ''),
    ];
    if (withScore) {
      final sc = r.score;
      final f = r.forecast;
      cells.addAll([
        // 无数据一律写空串：写 0 会被下游读成"0 分/最差"，比留空危险得多。
        sc == null ? '' : sc.score.toStringAsFixed(1),
        sc == null ? '' : sc.tier,
        f?.target == null ? '' : f!.target!.toStringAsFixed(2),
        f?.stop == null ? '' : f!.stop!.toStringAsFixed(2),
        f?.riskReward == null ? '' : f!.riskReward!.toStringAsFixed(2),
        sc == null ? '' : sc.sampleCount.toString(),
        // planA / planB。回查某一版 CSV 是哪套模型产出的排序时用得上。
        sc == null ? '' : sc.source,
      ]);
    }
    if (withSignalDay) {
      cells.addAll([
        r.signalDate,
        '${r.ret20 >= 0 ? '+' : '-'}${r.ret20.abs().toStringAsFixed(2)}',
      ]);
    }
    buf.writeln(cells.join(','));
  }
  return buf.toString();
}

/// 写文件回调（测试注入假实现；默认用 dart:io 写库同目录）。
typedef WriteCsvFn = Future<void> Function(String path, List<int> bytes);

/// 导出 CSV 到 [dirPath]（传数据库所在目录：桌面 ~/.stock、移动端沙盒应用目录）。
/// `DateTime` → `YYYY-MM-DD`（选股行展示信号日用）。
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// 文件名带日期时间戳，重复导出不覆盖。返回落盘路径（UI 弹提示用）。
Future<String> exportRowsCsv(
  List<ScreenRow> rows, {
  required String dirPath,
  String? dataDate,
  String? combo,
  WriteCsvFn? write,
}) async {
  final stamp = _stamp();
  final file = File('$dirPath/选股结果-$stamp.csv');
  await (write ?? (p, bytes) async {
        await File(p).parent.create(recursive: true);
        await File(p).writeAsBytes(bytes);
      })(file.path, [
    0xEF, 0xBB, 0xBF, // BOM：没有它 Excel 打开中文 CSV 会乱码
    ...utf8.encode(rowsToCsv(rows, dataDate: dataDate, combo: combo)),
  ]);
  return file.path;
}

/// `YYYYMMDD-HHMMSS` 本地时间戳（写到文件名里避免覆盖上次导出）。
String _stamp() {
  final n = DateTime.now();
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${p2(n.month)}${p2(n.day)}-${p2(n.hour)}${p2(n.minute)}${p2(n.second)}';
}

/// 选股：后台 isolate 里打开库 → 全量加载（剔除 ST / 退市 / 科创板）→ 规则筛选 → 组装展示行 → 关库。
/// 返回股票总数、入选行、数据截止交易日，以及两个数据卫生护栏各挡掉多少只
/// （不显示这个数，用户只会看到"入选变少了"而不知道原因）。
Future<
        ({int total, List<ScreenRow> picked, String? dataDate, int blockedStale,
            int blockedCorporateAction})>
    runScreening(
  String dbPath,
  List<Rule> rules,
) =>
    Isolate.run(() {
      final repo = BarRepository(dbPath);
      try {
        final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
        final names = repo.stockNames();
        final picked = <ScreenRow>[];
        final report = loadBacktestReport(dbPath);
        final model = loadScoreModel(dbPath);
        final screened = screenDiagnostics(stocks, rules);
        for (final hit in screened.hits) {
          final s = hit.stock;
          final snap = hit.snapshot; // 筛选时已构建，直接复用
          final prevClose = s.bars[s.bars.length - 2].close;
          final ids = hit.matchedRuleIds;
          picked.add(ScreenRow(
            symbol: s.symbol,
            name: names[s.symbol],
            close: snap.close,
            change: snap.close - prevClose,
            changePct: snap.pctChange,
            volumeRatio: snap.volumeRatio,
            amountWan: s.last.amount / 10,
            ma20: snap.ma20,
            matchedRules: [for (final id in ids) ruleById(id).name],
            signalDate: _ymd(s.last.date),
            ret20: s.bars.length > 21
                ? (s.last.close / s.bars[s.bars.length - 21].close - 1) * 100
                : 0,
            // 有 score-model.json 就走方案 B（holdout AUC 0.530）；没有就退回
            // 方案 A。模型缺失是常态（首次安装、还没训练过），不该影响选股。
            score: scoreOf(
              report,
              hitRuleIds: ids,
              horizon: kScoreHorizon,
              model: model,
              snapshot: snap,
              fallbackToPlanA: true,
            ),
            forecast: priceForecast(
              report,
              close: snap.close,
              hitRuleIds: ids,
              horizon: kScoreHorizon,
            ),
          ));
        }
        return (
          total: stocks.length,
          picked: picked,
          dataDate: repo.maxTradeDate(),
          blockedStale: screened.blockedStale,
          blockedCorporateAction: screened.blockedCorporateAction,
        );
      } finally {
        repo.close();
      }
    });

/// 读回测报告缓存；无文件或文件损坏返回 null（报表不该影响选股）。
BacktestReport? loadBacktestReport(String dbPath, {String? reportPath}) =>
    ReportStore(reportPath ?? reportPathFor(dbPath)).load();

/// 读评分模型（方案 B）。文件缺失/损坏/维度与当前特征表不符时返回 null，
/// 由 [scoreOf] 回退方案 A——模型是加速器，不是选股的前置条件。
LogRegModel? loadScoreModel(String dbPath, {String? modelPath}) {
  final f = File(modelPath ?? '${File(dbPath).parent.path}/score-model.json');
  if (!f.existsSync()) return null;
  final m = LogRegModel.fromJsonString(f.readAsStringSync());
  if (m == null) return null;
  if (m.featureCount != featureNames.length) {
    // 特征表改过而模型没重训：维度不符等同系数整体错位，宁可不用。
    return null;
  }
  return m;
}

/// 回测全部内置规则 × [kDefaultHorizons] 持有期，结果落盘后返回（后台 isolate）。
/// 实测约 20 秒（5623 只 × 424 根）；落盘后页面秒开。
Future<BacktestReport> runBacktest(String dbPath, {String? reportPath}) =>
    Isolate.run(() {
      final store = ReportStore(reportPath ?? reportPathFor(dbPath));
      final repo = BarRepository(dbPath);
      try {
        final stocks = repo.loadAllStocks();
        final report =
            backtestAll(stocks, builtInRules, horizons: kDefaultHorizons);
        store.save(report);
        return report;
      } finally {
        repo.close();
      }
    });

/// 个股详情：单只股票的完整日线 + 末日指标快照。
/// [name] 为 null 表示本地名单未拉到，UI 降级显示代码。
class StockDetail {
  const StockDetail({
    required this.symbol,
    required this.name,
    required this.bars,
    required this.snapshot,
  });

  final String symbol;
  final String? name;
  final List<Bar> bars;
  final IndicatorSnapshot snapshot;
}

/// 加载单只股票详情（数据量小，主 isolate 直接算）。
/// 本地无该股或历史不足 [IndicatorSnapshot.minBars] 根时返回 null。
Future<StockDetail?> loadStockDetail(String dbPath, String symbol) async {
  final repo = BarRepository(dbPath);
  try {
    final bars = repo.barsFor(symbol);
    if (bars.length < IndicatorSnapshot.minBars) return null;
    final stock = StockData(symbol: symbol, bars: bars);
    return StockDetail(
      symbol: symbol,
      name: repo.stockNames()[symbol],
      bars: bars,
      snapshot: IndicatorSnapshot.fromStock(stock),
    );
  } finally {
    repo.close();
  }
}

/// 增量同步：网络等待型任务，直接在当前 isolate 跑（onProgress 才能实时回调 UI）；
/// 库操作按交易日分批，单批几千行不会卡界面。
/// [clientFactory] / [sinaFactory] 供测试注入假客户端；生产用默认值。
/// 新浪备源必须接上（AGENTS 行情口径第 6 条的降级链）：不传时 tushare 日线
/// 一故障就原样抛出，40203 限频还会空转 5 次 65 秒。
/// [fromDate] / [rateDelay] 透传给 [SyncService.sync]：区间补拉用（见 [runBackfillSync]）。
Future<SyncResult> runSync({
  required String dbPath,
  required String token,
  DateTime Function()? now,
  TushareClient Function(String token)? clientFactory,
  SinaClient Function()? sinaFactory,
  void Function(String msg)? onProgress,
  String? fromDate,
  Duration rateDelay = const Duration(milliseconds: 350),
}) async {
  final repo = BarRepository(dbPath);
  try {
    final client = clientFactory?.call(token) ?? TushareClient(token: token);
    return await SyncService(client, repo, now: now,
            sina: sinaFactory?.call() ?? SinaClient())
        .sync(onProgress: onProgress, fromDate: fromDate, rateDelay: rateDelay);
  } finally {
    repo.close();
  }
}

/// tushare daily 低积分限 50 次/分 → 间隔 ≥1.2s 才能整段区间不撞 40203。
/// 撞了会被 maxAttempts=1 立刻甩进逐股新浪备源：约 33 分钟且新浪只有
/// 400 根深度，3 年区间补不满——慢而可控好过快而断。
const kBackfillRateDelay = Duration(milliseconds: 1200);

/// 回补历史的同步入口：绕过水位线，强制拉 [fromDate]（`YYYYMMDD`）起
/// 全部已收盘交易日。手机端首次回填没跑成时，历史深度只能靠它补——
/// 水位线增量永远只拉「已同步最大交易日之后」，补不了早于水位的历史。
Future<SyncResult> runBackfillSync({
  required String dbPath,
  required String token,
  required String fromDate,
  DateTime Function()? now,
  TushareClient Function(String token)? clientFactory,
  SinaClient Function()? sinaFactory,
  void Function(String msg)? onProgress,
  Duration rateDelay = kBackfillRateDelay,
}) =>
    runSync(dbPath: dbPath, token: token, now: now,
        clientFactory: clientFactory, sinaFactory: sinaFactory,
        onProgress: onProgress, fromDate: fromDate, rateDelay: rateDelay);

/// 回补历史的注入端口（外壳字段用）；生产用 [runBackfillSync]。
typedef RunBackfillFn = Future<SyncResult> Function({
  required String dbPath,
  required String token,
  required String fromDate,
  void Function(String msg)? onProgress,
});
