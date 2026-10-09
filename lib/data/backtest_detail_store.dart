/// 回测明细缓存（P3 增量回测的派生缓存，非用户数据——删了就自动全量重建）。
///
/// 缓存的是 `mergeShardDetails`/`mergeAndAggregate` 产出的合并态 [ShardDetail]：
/// overall Tape 快照（按年分桶的明细值 + 标量统计 + 月计数）+ recent 按日逐值
/// 明细 + 每股扫描长度。文件布局 = `[u32 头长度][JSON 头][补齐对齐][float64 块]`：
/// 头里记录每块的双精度数个数（结构即索引），块按 sig → base → rsig → rbase
/// 的确定性遍历序依次落盘，读取按同一 JSON 插入序回放。
///
/// 失效检测（app_logic 编排）：
/// - 指纹（规则集 + 持有期 + 口径常量）不匹配 → 全量；
/// - `COUNT(rowid <= 头里 maxRowid)` ≠ 头里 rowCount → 有旧行被 REPLACE/删除
///   （INSERT OR REPLACE 会让旧行拿到新 rowid），→ 全量；
/// - 缓存里的股票集不是当前股票集的子集 → 有股票被删 → 全量。
/// 未覆盖的场景：绕过应用直接 UPDATE 旧行（rowid 不变）——本应用与同步链路
/// 只用 INSERT OR REPLACE，不发生。
///
/// 值块按平台字节序（全部目标平台为小端）写读，读写同机完成。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stock/core/backtest.dart';

const _version = 1;

/// 加载出来的缓存条目：明细 + 写入时的行水位（失效检测用）。
class BacktestDetailCache {
  final ShardDetail detail;
  final String fingerprint;
  final int maxRowid;
  final int rowCount;

  const BacktestDetailCache({
    required this.detail,
    required this.fingerprint,
    required this.maxRowid,
    required this.rowCount,
  });
}

/// `<db 目录>/<db 主名>-backtest-detail.bin`，与 CLI/桌面/移动的库文件同目录。
String backtestDetailPathFor(String dbPath) {
  final sep = Platform.pathSeparator;
  final idx = dbPath.lastIndexOf(sep);
  final dir = idx < 0 ? '.' : dbPath.substring(0, idx);
  final name = idx < 0 ? dbPath : dbPath.substring(idx + 1);
  final stem = name.endsWith('.db') ? name.substring(0, name.length - 3) : name;
  return '$dir$sep$stem-backtest-detail.bin';
}

/// 任何问题（缺失/损坏/版本/指纹不匹配）一律返回 null，由调用方退全量。
BacktestDetailCache? loadBacktestDetail(String path,
    {required String fingerprint}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    final bd = ByteData.sublistView(bytes);
    final headerLen = bd.getUint32(0, Endian.little);
    final header = jsonDecode(utf8.decode(bytes.sublist(4, 4 + headerLen)))
        as Map<String, dynamic>;
    if (header['v'] != _version) return null;
    final fp = header['fp'] as String? ?? '';
    if (fp != fingerprint) return null;

    var offset = 4 + headerLen;
    offset += (8 - offset % 8) % 8; // 与写入端相同的对齐补齐
    final base = bytes.offsetInBytes;

    Float64List readBlock(int n) {
      if (n == 0) return Float64List(0);
      final v = Float64List.view(bytes.buffer, base + offset, n);
      offset += n * 8;
      return v;
    }

    TapeSnapshot tapeFrom(Map<String, dynamic> node) {
      final m = <String, int>{
        for (final e in (node['m'] as Map<String, dynamic>).entries)
          e.key: e.value as int,
      };
      final byYear = <int, List<double>>{
        for (final e in (node['y'] as Map<String, dynamic>).entries)
          int.parse(e.key): readBlock(e.value as int),
      };
      final best = node['b'] as num?;
      final worst = node['w2'] as num?;
      return TapeSnapshot(
        byYear: byYear,
        byMonth: m,
        count: node['c'] as int,
        sum: (node['s'] as num).toDouble(),
        gain: (node['g'] as num).toDouble(),
        loss: (node['l'] as num).toDouble(),
        wins: node['w'] as int,
        best: best?.toDouble(),
        worst: worst?.toDouble(),
      );
    }

    final sigTapes = <String, Map<int, TapeSnapshot>>{
      for (final r in (header['sig'] as Map<String, dynamic>).entries)
        r.key: {
          for (final e in (r.value as Map<String, dynamic>).entries)
            int.parse(e.key): tapeFrom(e.value as Map<String, dynamic>),
        },
    };
    final baseTapes = <int, TapeSnapshot>{
      for (final e in (header['base'] as Map<String, dynamic>).entries)
        int.parse(e.key): tapeFrom(e.value as Map<String, dynamic>),
    };

    Map<String, Map<int, Map<int, List<double>>>>? readSigDays() {
      final raw = header['rsig'] as Map<String, dynamic>?;
      if (raw == null) return null;
      return {
        for (final r in raw.entries)
          r.key: {
            for (final e in (r.value as Map<String, dynamic>).entries)
              int.parse(e.key): {
                for (final d in (e.value as Map<String, dynamic>).entries)
                  int.parse(d.key): readBlock(d.value as int),
              },
          },
      };
    }

    Map<int, Map<int, List<double>>>? readBaseDays() {
      final raw = header['rbase'] as Map<String, dynamic>?;
      if (raw == null) return null;
      return {
        for (final e in raw.entries)
          int.parse(e.key): {
            for (final d in (e.value as Map<String, dynamic>).entries)
              int.parse(d.key): readBlock(d.value as int),
          },
      };
    }

    return BacktestDetailCache(
      detail: ShardDetail(
        stockCount: header['sc'] as int,
        sigTapes: sigTapes,
        baseTapes: baseTapes,
        recentSigDays: readSigDays(),
        recentBaseDays: readBaseDays(),
        msContrib: null, // 市场状态依赖每股末根，缓存无意义，增量时全量重算
        stockLens: {
          for (final e in (header['lens'] as Map<String, dynamic>).entries)
            e.key: e.value as int,
        },
      ),
      fingerprint: fp,
      maxRowid: header['maxRowid'] as int,
      rowCount: header['rowCount'] as int,
    );
  } catch (_) {
    return null; // 损坏/被截断/格式不符：派生缓存，直接退全量
  }
}

/// 原子写（tmp + rename；Windows rename 目标已存在时先删，同台账写法）。
void saveBacktestDetail(
  String path,
  ShardDetail detail, {
  required String fingerprint,
  required int maxRowid,
  required int rowCount,
}) {
  final blocks = BytesBuilder(copy: false);

  void writeBlock(List<double> values) {
    if (values.isEmpty) return;
    final f = Float64List.fromList(values);
    blocks.add(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));
  }

  Map<String, Object?> tapeNode(TapeSnapshot t) {
    final y = <String, int>{};
    for (final e in t.byYear.entries) {
      y['${e.key}'] = e.value.length;
      writeBlock(e.value);
    }
    return {
      'c': t.count,
      's': t.sum,
      'g': t.gain,
      'l': t.loss,
      'w': t.wins,
      'b': t.best,
      'w2': t.worst,
      'm': {
        for (final e in t.byMonth.entries) e.key: e.value,
      },
      'y': y,
    };
  }

  final header = <String, Object?>{
    'v': _version,
    'fp': fingerprint,
    'maxRowid': maxRowid,
    'rowCount': rowCount,
    'sc': detail.stockCount,
    'lens': detail.stockLens,
    'sig': {
      for (final r in detail.sigTapes.entries)
        r.key: {
          for (final e in r.value.entries) '${e.key}': tapeNode(e.value),
        },
    },
    'base': {
      for (final e in detail.baseTapes.entries) '${e.key}': tapeNode(e.value),
    },
    if (detail.recentSigDays != null)
      'rsig': {
        for (final r in detail.recentSigDays!.entries)
          r.key: {
            for (final e in r.value.entries)
              '${e.key}': {
                for (final d in e.value.entries) '${d.key}': d.value.length,
              },
          },
      },
    if (detail.recentBaseDays != null)
      'rbase': {
        for (final e in detail.recentBaseDays!.entries)
          '${e.key}': {
            for (final d in e.value.entries) '${d.key}': d.value.length,
          },
      },
  };
  // 块写在头之后：sig → base（tapeNode 构造头时已写）→ rsig → rbase，
  // 与读取端遍历序一致
  if (detail.recentSigDays != null) {
    for (final byH in detail.recentSigDays!.values) {
      for (final byDay in byH.values) {
        for (final v in byDay.values) {
          writeBlock(v);
        }
      }
    }
  }
  if (detail.recentBaseDays != null) {
    for (final byDay in detail.recentBaseDays!.values) {
      for (final v in byDay.values) {
        writeBlock(v);
      }
    }
  }

  final headerBytes = utf8.encode(jsonEncode(header));
  var offset = 4 + headerBytes.length;
  final pad = (8 - offset % 8) % 8;

  final out = BytesBuilder(copy: false);
  final lenBytes = ByteData(4)..setUint32(0, headerBytes.length, Endian.little);
  out.add(lenBytes.buffer.asUint8List());
  out.add(headerBytes);
  if (pad > 0) out.add(Uint8List(pad)); // 块起始 8 字节对齐（float64 视图要求）
  out.add(blocks.takeBytes());
  final total = out.takeBytes();

  final tmp = File('$path.$pid.tmp');
  tmp.writeAsBytesSync(total, flush: true);
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
