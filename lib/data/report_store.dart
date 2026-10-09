/// 回测报告的落盘缓存：JSON 放在数据库同目录，随库走（桌面 ~/.stock、移动端沙盒）。
/// 纯 IO，不放 core（core 零 IO 依赖）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:stock/core/backtest.dart';

/// 报告文件路径：与数据库同目录，`<数据库主名>-backtest-report.json`。
String reportPathFor(String dbPath) {
  final f = File(dbPath);
  final name = f.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  return '${f.parent.path}/$stem-backtest-report.json';
}

/// 月度台账路径：与报告同目录、固定文件名。
/// App（runBacktest）与 CLI（tool/report_all.dart --archive）共用同一份。
String historyPathFor(String reportPath) =>
    '${File(reportPath).parent.path}/backtest-history.json';

/// 读台账；不存在或损坏返回 null——台账是辅助数据，坏了不该拖垮回测页。
BacktestHistory? loadBacktestHistory(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return BacktestHistory.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  } on Object {
    return null;
  }
}

/// 写台账：先写临时文件再 rename 原子替换。
///
/// App（后台 isolate）与 CLI `--archive` 都会「读 → 合并 → 写」同一个文件，
/// 直接覆盖时写到一半崩溃/断电会留下截断 JSON，读回被当成"没有台账"，
/// 连红整列静默变 —（用户不会收到任何提示），已经写进去的期数也一起没了。
/// 临时文件名带 pid，避免两个写者互相踩。
void saveBacktestHistory(String path, BacktestHistory history) {
  final tmp = File('$path.$pid.tmp');
  tmp.writeAsStringSync(jsonEncode(history.toJson()), flush: true);
  try {
    tmp.renameSync(path);
  } on FileSystemException {
    // Windows 平台下若目标文件已存在，renameSync 会抛 FileSystemException。
    // 先删再换，避免 Windows 端写盘失败导致台账丢失。
    if (Platform.isWindows && File(path).existsSync()) {
      File(path).deleteSync();
      tmp.renameSync(path);
    } else {
      rethrow;
    }
  }
}

class ReportStore {
  ReportStore(this.path);

  final String path;

  /// 读缓存；没有文件、或文件损坏都返回 null（报表不该影响选股）。
  ///
  /// 「损坏」包含两种：合法 JSON 但结构不对（字段缺失/类型错，多发生在 App 升级
  /// 改了报告格式之后），以及根本不是 JSON 对象。后者抛的是 TypeError 而非 Exception，
  /// 所以显式接住——缓存读取绝不能让选股页崩掉。
  BacktestReport? load() {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map<String, dynamic>) return null;
      return BacktestReport.fromJson(raw);
    } on Exception catch (_) {
      return null;
    } on TypeError catch (_) {
      return null; // 报告 schema 漂移，按损坏处理
    }
  }

  /// 原子写（tmp + rename）：回测页/选股页在写入中途读报告时不会读到半份 JSON。
  /// Windows 下目标已存在时 rename 会抛，先删再换（同 [saveBacktestHistory]）。
  void save(BacktestReport report) {
    final tmp = File('$path.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(report.toJson()), flush: true);
    try {
      tmp.renameSync(path);
    } on FileSystemException {
      if (Platform.isWindows && File(path).existsSync()) {
        File(path).deleteSync();
        tmp.renameSync(path);
      } else {
        rethrow;
      }
    }
  }

  void clear() {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
}
