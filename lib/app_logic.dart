/// App/CLI 共用的重活入口：把 SQLite 读取与计算放进后台 isolate，避免卡 UI。
library;

import 'dart:async';
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
import 'package:stock/data/eastmoney_client.dart';
import 'package:stock/data/sina_client.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tushare_client.dart';

export 'package:stock/data/bar_repository.dart' show HistoryCoverage;

/// 当前应用版本（发布新包时同步修改，与 pubspec.version 保持一致）。
const kAppVersion = '2.6.5';

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
///
/// 单发路径：每次调用全量重读库。App 内的连续选股走 [ScreeningService]
/// （池子跨次复用），CLI 进程即用即走适合单发。
Future<ScreenResult> runScreening(String dbPath, List<Rule> rules) =>
    Isolate.run(() {
      final repo = BarRepository(dbPath);
      try {
        final sw = Stopwatch()..start();
        final pool = _loadPool(repo, dbPath);
        final loadMs = sw.elapsedMilliseconds;
        return _screenWithPool(pool, rules,
            dataDate: repo.maxTradeDate(), loadMs: loadMs, poolReused: false);
      } finally {
        repo.close();
      }
    });

/// 选股各阶段耗时（毫秒）。手机端结果区展示，让"慢在哪"可见：
/// loadMs=池子加载（复用时 0）、screenMs=护栏+快照+规则、assembleMs=命中行组装。
typedef ScreenTimings = ({
  int loadMs,
  int screenMs,
  int assembleMs,
  int totalMs,
  bool poolReused,
});

/// 一次选股的完整结果（App/CLI/UI 共用；[timings] 见 [ScreenTimings]）。
typedef ScreenResult = ({
  int total,
  List<ScreenRow> picked,
  String? dataDate,
  int blockedStale,
  int blockedCorporateAction,
  int blockedSuspension,
  ScreenTimings? timings,
});

/// 选股池：一次加载、可跨次复用的重活产物（仅在后台 isolate 内持有）。
typedef _Pool = ({
  List<StockData> stocks,
  Map<String, String> names,
  BacktestReport? report,
  LogRegModel? model,
});

_Pool _loadPool(BarRepository repo, String dbPath) => (
      stocks: repo.loadAllStocks(excludeSpecialStocks: true),
      names: repo.stockNames(),
      report: loadBacktestReport(dbPath),
      model: loadScoreModel(dbPath),
    );

/// 对已加载的池子跑规则并组装展示行。[loadMs]/[poolReused] 由调用方按加载方式填。
ScreenResult _screenWithPool(
  _Pool pool,
  List<Rule> rules, {
  required String? dataDate,
  required int loadMs,
  required bool poolReused,
}) {
  final sw = Stopwatch()..start();
  final screened = screenDiagnostics(pool.stocks, rules);
  final screenMs = sw.elapsedMilliseconds;
  sw.reset();
  final picked = <ScreenRow>[];
  for (final hit in screened.hits) {
    final s = hit.stock;
    final snap = hit.snapshot; // 筛选时已构建，直接复用
    final prevClose = s.bars[s.bars.length - 2].close;
    final ids = hit.matchedRuleIds;
    picked.add(ScreenRow(
      symbol: s.symbol,
      name: pool.names[s.symbol],
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
      // 有 score-model.json 就走方案 B；没有就退回方案 A。模型缺失是常态
      // （首次安装、还没训练过），不该影响选股。
      // 具体 AUC 不写死在注释里——它每次重训都变，写死必然过期，
      // 看 score-model.json 的 holdoutAuc 与 planAAuc 字段。
      score: scoreOf(
        pool.report,
        hitRuleIds: ids,
        horizon: kScoreHorizon,
        model: pool.model,
        snapshot: snap,
        fallbackToPlanA: true,
      ),
      forecast: priceForecast(
        pool.report,
        close: snap.close,
        hitRuleIds: ids,
        horizon: kScoreHorizon,
      ),
    ));
  }
  final assembleMs = sw.elapsedMilliseconds;
  return (
    total: pool.stocks.length,
    picked: picked,
    dataDate: dataDate,
    blockedStale: screened.blockedStale,
    blockedCorporateAction: screened.blockedCorporateAction,
    blockedSuspension: screened.blockedSuspension,
    timings: (
      loadMs: loadMs,
      screenMs: screenMs,
      assembleMs: assembleMs,
      totalMs: loadMs + screenMs + assembleMs,
      poolReused: poolReused,
    ),
  );
}

/// 常驻后台 isolate 的选股服务：池子加载一次跨次复用，数据/报告变了自动重载。
///
/// 为什么常驻：全市场池子加载是选股耗时的绝对大头（桌面实测 3.9 秒），
/// `Isolate.run` 单发路径每次点「开始选股」都要全量重读。池子占内存数百 MB 量级，
/// 必须留在后台 isolate，主 isolate 只收结果行；空闲 [idleTimeout] 后回收 isolate
/// 释放内存（发关闭消息让它自己关库退出），下次选股重新孵化。
///
/// 失效指纹（[_poolFingerprint]）：库水位+行指纹 ⊕ 回测报告文件 ⊕ 评分模型文件。
/// 同步推进水位、回补历史改行指纹、回测页重跑报告换文件——任一变化都重载。
class ScreeningService {
  ScreeningService({this.idleTimeout = const Duration(minutes: 5)});

  /// 空闲多久后回收常驻 isolate（回收路径见 [_drop]）。
  final Duration idleTimeout;

  Isolate? _iso;
  ReceivePort? _inbox;
  ReceivePort? _errors;
  Completer<SendPort>? _ready;

  /// 常驻 isolate 的请求端口。回收时用它发「关库退出」而不是直接 kill。
  SendPort? _workerPort;

  final _pending = <int, Completer<Object?>>{};
  var _seq = 0;
  Timer? _idle;
  var _disposed = false;

  /// 进行中的 [screen] 次数（含"已调用、isolate 还没就绪"的孵化期）。
  /// 内存压力回收要避开它：此刻池子正在被使用，回收只会把即将到手的结果变成错误。
  var _inflight = 0;

  /// 用池子跑一次选股；规则列表映射成 id 传给 isolate（Rule 带闭包不可跨 isolate）。
  Future<ScreenResult> screen(String dbPath, List<Rule> rules) {
    if (_disposed) return Future.error(StateError('ScreeningService 已销毁'));
    _idle?.cancel();
    _inflight++;
    final f = _withWorker().then((send) {
      final id = _seq++;
      final c = Completer<Object?>();
      _pending[id] = c;
      send.send([
        id,
        dbPath,
        [for (final r in rules) r.id],
      ]);
      return c.future.then((payload) {
        if (payload is String) throw StateError(payload);
        return payload as ScreenResult;
      });
    });
    return f.whenComplete(() {
      _inflight--;
      _armIdle();
    });
  }

  /// 释放常驻 isolate（App 退出/测试收尾用；之后再 screen 会抛错）。
  void dispose() {
    _disposed = true;
    _idle?.cancel();
    _drop(null);
  }

  /// 只丢池子、不销毁服务：系统内存压力（didHaveMemoryPressure）时调用，
  /// 立即归还常驻 isolate 的内存；下次 [screen] 自动重新孵化并重载，
  /// 代价只是那一次退回单发速度。
  ///
  /// 有请求在途（含孵化期）时不回收：池子正在被使用，丢掉的只是这次结果，
  /// 内存也省不下来（isolate 本来就在跑）。等它收尾，空闲回收自会接手。
  void releasePool() {
    if (_inflight > 0) return;
    _idle?.cancel();
    _drop(null);
  }

  Future<SendPort> _withWorker() {
    final existing = _ready;
    if (existing != null) return existing.future;
    final fresh = Completer<SendPort>();
    _ready = fresh;
    final inbox = ReceivePort();
    final errors = ReceivePort();
    _inbox = inbox;
    _errors = errors;
    Isolate.spawn(_screeningWorkerMain, inbox.sendPort, onError: errors.sendPort)
        .then((iso) {
      if (_ready != fresh) {
        // spawn 期间服务已被回收/销毁（releasePool/dispose）：杀掉刚孵化的
        // isolate，否则它会空等一个已关闭的端口，永不释放。
        iso.kill(priority: Isolate.beforeNextEvent);
        return;
      }
      _iso = iso;
      inbox.listen((m) {
        if (m is SendPort) {
          _workerPort = m;
          if (!fresh.isCompleted) fresh.complete(m);
          return;
        }
        final msg = m as List;
        final c = _pending.remove(msg[0] as int);
        if (c == null) return;
        if (msg[1] is String) {
          c.completeError(StateError(msg[1] as String));
        } else {
          c.complete(msg[1]);
        }
      });
      errors.listen((m) => _drop('选股 isolate 崩溃: $m'));
    }).catchError((Object e) {
      _drop('选股 isolate 启动失败: $e');
    });
    return fresh.future;
  }

  /// 回收常驻 isolate 并让所有在途请求以错误收场；[message] 为 null 表示正常回收（空闲/销毁）。
  void _drop(String? message) {
    if (message == null && !_disposed && _inflight > 0) return;
    final ready = _ready;
    _ready = null;
    final worker = _workerPort;
    _workerPort = null;
    if (worker != null) {
      // 端口已建立：让 worker 自己 repo.close() 再退出。kill 掉的 isolate 不保证
      // 跑到释放在途 native 资源（SQLite 句柄）的 finalizer，而池子下一刻就会被
      // 重新加载——空闲每回收一轮，就漏一次。消息按序处理，worker 关掉自己的
      // ReceivePort 后自然退出（它已经空闲，不用等）。
      worker.send(_kWorkerShutdown);
    } else {
      // 还没拿到端口（孵化中/启动失败）：只能强杀，否则它会空等一个已关闭的端口。
      _iso?.kill(priority: Isolate.beforeNextEvent);
    }
    _iso = null;
    _inbox?.close();
    _inbox = null;
    _errors?.close();
    _errors = null;
    final err = StateError(message ?? '选股服务已回收');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
    // 未就绪的等待者一律收场：只回收 isolate 不完成它，[screen] 的 Future 会
    // 永久挂起（加载框关不掉，只能杀 App）。回收（message == null）同样如此——
    // 孵化期被 releasePool/dispose 打断时，等待者已经拿不到任何结果了。
    if (ready != null && !ready.isCompleted) {
      ready.completeError(err);
    }
  }

  void _armIdle() {
    _idle?.cancel();
    if (_inflight == 0) {
      _idle = Timer(idleTimeout, () => _drop(null));
    }
  }
}

/// 回收消息：主 isolate 发给常驻 worker，让它关库后自行退出（见 [ScreeningService._drop]）。
const String _kWorkerShutdown = 'close';

/// [ScreeningService] 的常驻 isolate 主体。
/// 请求：`[请求id, dbPath, 规则id列表]`（或回收消息 [String]）；
/// 回包：`[请求id, ScreenResult 或错误字符串]`。
void _screeningWorkerMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  BarRepository? repo;
  String? openedPath;
  String? fingerprint;
  _Pool? pool;
  // ReceivePort 的 async 回调会并发进入，池子状态必须串行演化。
  var busy = Future<void>.value();

  inbox.listen((m) {
    if (m == _kWorkerShutdown) {
      // 串到 busy 之后：正在跑的选股先收尾，再关库、关端口退出。
      busy = busy.then((_) {
        repo?.close();
        repo = null;
        pool = null;
        inbox.close(); // 没有活动端口后 isolate 自然结束
      });
      return;
    }
    final msg = m as List;
    busy = busy.then((_) async {
      final id = msg[0] as int;
      try {
        final dbPath = msg[1] as String;
        final rules = [for (final rid in msg[2] as List) ruleById(rid as String)];
        if (repo == null || openedPath != dbPath) {
          repo?.close();
          repo = BarRepository(dbPath);
          openedPath = dbPath;
          fingerprint = null;
        }
        final key = _poolFingerprint(repo!, dbPath);
        var loadMs = 0;
        var reused = true;
        if (key != fingerprint) {
          final sw = Stopwatch()..start();
          pool = _loadPool(repo!, dbPath);
          fingerprint = key;
          loadMs = sw.elapsedMilliseconds;
          reused = false;
        }
        out.send([
          id,
          _screenWithPool(pool!, rules,
              dataDate: repo!.maxTradeDate(),
              loadMs: loadMs,
              poolReused: reused),
        ]);
      } catch (e, st) {
        out.send([id, '选股失败: $e\n$st']);
      }
    });
  });
}

/// 选股池失效指纹：库指纹 ⊕ 报告/模型文件指纹。报告与模型是选股评分的输入，
/// 回测页重跑后必须跟着换，文件按 长度:mtime 指纹化（缺失记 `-`）。
String _poolFingerprint(BarRepository repo, String dbPath) {
  String fileFp(String path) {
    final f = File(path);
    if (!f.existsSync()) return '-';
    return '${f.lengthSync()}:${f.lastModifiedSync().millisecondsSinceEpoch}';
  }

  return '${repo.poolFingerprint()}'
      '|${fileFp(reportPathFor(dbPath))}'
      '|${fileFp('${File(dbPath).parent.path}/score-model.json')}';
}

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
///
/// 同时把快照写入同目录的月度台账（同一数据截止日只留最新一条），
/// 与 `tool/report_all.dart --archive` 同格式——「连红」计数要求两边口径一致。
Future<BacktestReport> runBacktest(String dbPath, {String? reportPath}) =>
    Isolate.run(() {
      final rp = reportPath ?? reportPathFor(dbPath);
      final store = ReportStore(rp);
      final repo = BarRepository(dbPath);
      try {
        final stocks = repo.loadAllStocks();
        final report = backtestAll(stocks, builtInRules,
            horizons: kDefaultHorizons,
            recentWindowTradingDays: kRecentWindowTradingDays);
        store.save(report);
        final dataDate = repo.maxTradeDate();
        if (dataDate != null) {
          final hp = historyPathFor(rp);
          final prev = loadBacktestHistory(hp) ?? const BacktestHistory([]);
          saveBacktestHistory(
              hp, prev.upsert(BacktestSnapshot.of(report, dataDate)));
        }
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
      name: repo.stockName(symbol),
      bars: bars,
      snapshot: IndicatorSnapshot.fromStock(stock),
    );
  } finally {
    repo.close();
  }
}

/// 增量同步：网络等待型任务，直接在当前 isolate 跑（onProgress 才能实时回调 UI）；
/// 库操作按交易日分批，单批几千行不会卡界面。
/// [clientFactory] / [sinaFactory] / [eastmoneyFactory] 供测试注入假客户端；生产用默认值。
/// 备源必须接上（AGENTS 行情口径第 6 条的降级链，东财 → 新浪）：不传时
/// tushare 日线一故障就原样抛出，40203 限频还会空转 5 次 65 秒。
/// [fromDate] / [force] / [rateDelay] 透传给 [SyncService.sync]：区间补拉用（见 [runBackfillSync]）。
Future<SyncResult> runSync({
  required String dbPath,
  required String token,
  DateTime Function()? now,
  TushareClient Function(String token)? clientFactory,
  SinaClient Function()? sinaFactory,
  EastmoneyClient Function()? eastmoneyFactory,
  void Function(String msg)? onProgress,
  String? fromDate,
  bool force = false,
  Duration rateDelay = const Duration(milliseconds: 350),
}) async {
  final repo = BarRepository(dbPath);
  try {
    final client = clientFactory?.call(token) ?? TushareClient(token: token);
    return await SyncService(client, repo, now: now,
            eastmoney: eastmoneyFactory?.call() ?? EastmoneyClient(),
            sina: sinaFactory?.call() ?? SinaClient())
        .sync(
            onProgress: onProgress,
            fromDate: fromDate,
            force: force,
            rateDelay: rateDelay);
  } finally {
    repo.close();
  }
}

/// tushare daily 低积分限 50 次/分 → 间隔 ≥1.2s 才能整段区间不撞 40203。
/// 撞了会先等 65s 重试（最多 3 次）再降级逐股新浪备源：备源 5675 只逐股
/// 要近 1 小时且新浪只有 400 根深度——能不进就不进，慢而可控好过快而断。
const kBackfillRateDelay = Duration(milliseconds: 1200);

/// 回补历史的同步入口：绕过水位线，拉 [fromDate]（`YYYYMMDD`）起
/// 全部**库里缺失**的已收盘交易日（已有数据的日期跳过）。
/// [force] 忽略该跳过、整段重拉：某天只入库了部分股票（备源逐股中断留下的
/// 半截日）或数据源口径修正后用——没有它，这两种情况在 App 内永远修不回。
/// 手机端首次回填没跑成时，历史深度只能靠它补——
/// 水位线增量永远只拉「已同步最大交易日之后」，补不了早于水位的历史。
Future<SyncResult> runBackfillSync({
  required String dbPath,
  required String token,
  required String fromDate,
  DateTime Function()? now,
  TushareClient Function(String token)? clientFactory,
  SinaClient Function()? sinaFactory,
  EastmoneyClient Function()? eastmoneyFactory,
  void Function(String msg)? onProgress,
  bool force = false,
  Duration rateDelay = kBackfillRateDelay,
}) =>
    runSync(
        dbPath: dbPath,
        token: token,
        now: now,
        clientFactory: clientFactory,
        sinaFactory: sinaFactory,
        eastmoneyFactory: eastmoneyFactory,
        onProgress: onProgress,
        fromDate: fromDate,
        force: force,
        rateDelay: rateDelay);

/// 回补历史的注入端口（外壳字段用）；生产用 [runBackfillSync]。
typedef RunBackfillFn = Future<SyncResult> Function({
  required String dbPath,
  required String token,
  required String fromDate,
  bool force,
  void Function(String msg)? onProgress,
});

/// 读取本地库历史行情覆盖情况（供设置页与回补弹窗诊断）。
///
/// 走 isolate：这条 SQL 是全表聚合（`COUNT(DISTINCT trade_date)` 要扫全表，
/// 360 万行实测 130ms 起），而调用方是 [StockApp.initState]，留在主 isolate
/// 会把首帧一起堵住。与 [runBacktest] 同理——纯计算、不需要 onProgress。
Future<HistoryCoverage> loadHistoryCoverage(String dbPath) => Isolate.run(() {
      final repo = BarRepository(dbPath);
      try {
        return repo.historyCoverage();
      } finally {
        repo.close();
      }
    });

/// 历史覆盖情况读取端口（外壳字段用）；测试注入假实现，生产用 [loadHistoryCoverage]。
typedef LoadCoverageFn = Future<HistoryCoverage> Function(String dbPath);
