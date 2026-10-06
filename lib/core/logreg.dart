/// 逻辑回归：把多个指标压成一个「10 日后上涨概率」。
///
/// ## 为什么在 Dart 里训，不用 Python/sklearn
///
/// 这套模型要**每月随回测报告重训一次**。训练放在 Dart 里，重训就是
/// `dart run tool/train_score.dart`，不要求用户机器上有 Python 环境或
/// sklearn——否则"每月漂移检测"会因为环境缺失而悄悄停摆。
///
/// 代价是自己写求解器。用 **IRLS（牛顿-拉弗森）+ 特征标准化 + L2**：
/// 逻辑回归的目标函数光滑、二阶信息便宜（特征只有几十维，解一个
/// d×d 线性系统每轮 O(d³)≈几万次运算），所以牛顿法十来轮就到机器精度。
/// 早先用全批量梯度下降，4000 轮后对数损失仍比 sklearn 高 2%、
/// 系数整体小 20%——不是符号错，是没收敛。换成牛顿法后与 sklearn
/// 在同一目标上逐位一致（测试用 sklearn 做 oracle 交叉验证）。
///
/// 求解过程无随机项，**同数据同参数两次训练逐位一致**（测试锁住），
/// 月度重跑可复现。sklearn 只做 python oracle，不进生产链路。
///
/// ## 与评分方案 A 的关系
///
/// 方案 A 只用「命中规则的加权历史胜率」，是离散的 0/1 信息。
/// 这里改用连续特征（RSI 到底多低、量比多大、乖离多少），有区分度。
/// 两者输出口径一致（0~100 分），可原地替换；**但替换前必须先在
/// holdout 年份上证明 AUC 更高**，否则不值得为它多养一套模型。
///
/// ## 反过来说：它随时可能被否证
///
/// 这个项目的策略超额三年从 +41pp 衰减到 +8.7pp。如果 holdout 上 AUC≈0.5，
/// 说明连续特征没有增量信息，**那就该继续用方案 A**——见
/// `docs/project-structure.md`。本文件不预设结论。
library;

import 'dart:convert';
import 'dart:math' as math;

/// ROC AUC。同分记半个；只有一类标签时无法定义，返回 null。
///
/// O(n_pos × n_neg)。调用方应控制规模（或先抽样子集），否则大样本下
/// 这个乘积会炸。训练工具里对评估集做了上限。
double? auc(List<double> scores, List<int> labels) {
  if (scores.length != labels.length) {
    throw ArgumentError('scores 与 labels 长度不一致');
  }
  final pos = <double>[];
  final neg = <double>[];
  for (var i = 0; i < labels.length; i++) {
    (labels[i] == 1 ? pos : neg).add(scores[i]);
  }
  if (pos.isEmpty || neg.isEmpty) return null;
  var acc = 0.0;
  for (final p in pos) {
    for (final n in neg) {
      if (p > n) {
        acc += 1;
      } else if (p == n) {
        acc += 0.5;
      }
    }
  }
  return acc / (pos.length * neg.length);
}

/// 逻辑回归模型。
///
/// [weights] / [bias] 是标准化后特征上的系数；[mean] / [std] 把原始特征
/// 映射到零均值单位方差。推理时用训练时存下来的 [mean] / [std]，
/// **不能用评估集的统计量**——那会把测试集信息漏进模型。
class LogRegModel {
  const LogRegModel({
    required this.weights,
    required this.bias,
    required this.mean,
    required this.std,
  });

  /// IRLS 训练。[ys] 取值 0/1。[l2] 为 L2 系数，作用在**和形式**目标上：
  ///
  /// ```
  /// J(β) = Σ loglossᵢ + (l2/2)·||β||²
  /// ```
  ///
  /// 用和而不是均值，是为了让 IRLS 的梯度（Xᵀ(y−p) − l2·β）与 Hessian
  /// （XᵀWX + l2·I）**缩放一致**。早先梯度/Hessian 都是和形式、L2 却按
  /// 均值形式只加 l2·β/n，牛顿步因此系统性偏小，收敛不到真最优
  /// （400 样本上系数低 10%、对数损失高 0.6%）——症状是"能跑但不对"，
  /// 只有拿 sklearn 对同一目标逐位比才能发现。
  ///
  /// 换算：和形式 l2 = n × 均值形式 λ；sklearn 的 C = 1/l2。
  ///
  /// 收敛判据是系数增量小于 [tol]。完全可分且 l2=0 时最优解在无穷远，
  /// 此时按 [maxIter] 收敛不到 tol 为止——这既是数学事实也是可接受的
  /// 退化（系数很大但方向仍对，排序不受影响）。
  factory LogRegModel.train(
    List<List<double>> xs,
    List<int> ys, {
    int maxIter = 60,
    double l2 = 0,
    double tol = 1e-10,
  }) {
    if (xs.isEmpty || ys.isEmpty) {
      throw ArgumentError('训练集不能为空');
    }
    if (xs.length != ys.length) {
      throw ArgumentError('xs 与 ys 长度不一致');
    }
    final n = xs.length;
    final d = xs[0].length;
    if (d == 0) throw ArgumentError('特征不能为空');
    for (final x in xs) {
      if (x.length != d) {
        throw ArgumentError('特征维度不一致：期望 $d，实际 ${x.length}');
      }
    }
    for (final y in ys) {
      if (y != 0 && y != 1) throw ArgumentError('标签只能是 0/1，实际 $y');
    }

    final mean = List<double>.filled(d, 0);
    final std = List<double>.filled(d, 0);
    for (final x in xs) {
      for (var j = 0; j < d; j++) {
        mean[j] += x[j];
      }
    }
    for (var j = 0; j < d; j++) {
      mean[j] /= n;
    }
    for (final x in xs) {
      for (var j = 0; j < d; j++) {
        final dv = x[j] - mean[j];
        std[j] += dv * dv;
      }
    }
    for (var j = 0; j < d; j++) {
      std[j] = math.sqrt(std[j] / n);
      // 常数列：标准化后恒为 0，等价于没有这个特征。std 置 1 而不是除零，
      // 否则整列变 NaN 会把模型污染掉。
      if (std[j] < 1e-12) std[j] = 1;
    }
    final z = [
      for (final x in xs) [for (var j = 0; j < d; j++) (x[j] - mean[j]) / std[j]]
    ];
    final yd = [for (final y in ys) y.toDouble()];

    // 增广矩阵列数 = d + 1（最后一列是截距，不参与 L2 正则）
    final k = d + 1;
    final beta = List<double>.filled(k, 0);
    final xtwx = List<List<double>>.generate(k, (_) => List<double>.filled(k, 0));
    for (var i = 0; i < k; i++) {
      xtwx[i] = List<double>.filled(k, 0);
    }
    final grad = List<double>.filled(k, 0);
    final p = List<double>.filled(n, 0);

    for (var iter = 0; iter < maxIter; iter++) {
      // p_i = sigmoid(z_i·w + b)
      for (var i = 0; i < n; i++) {
        var s = beta[d]; // 截距
        final zi = z[i];
        for (var j = 0; j < d; j++) {
          s += beta[j] * zi[j];
        }
        p[i] = 1 / (1 + math.exp(-s));
      }
      // H = XᵀWX + λI（截距列不正则），g = Xᵀ(y − p) − λw
      for (var a = 0; a < k; a++) {
        grad[a] = 0;
        for (var b2 = 0; b2 < k; b2++) {
          xtwx[a][b2] = 0;
        }
      }
      for (var i = 0; i < n; i++) {
        final zi = z[i];
        final wgt = (p[i] * (1 - p[i])).clamp(1e-12, double.infinity);
        final resid = yd[i] - p[i];
        // 增广后的第 k-1 列 = 1（截距）
        for (var a = 0; a < d; a++) {
          grad[a] += zi[a] * resid;
        }
        grad[d] += resid;
        final row = List<double>.filled(k, 0);
        for (var a = 0; a < d; a++) {
          row[a] = zi[a];
        }
        row[d] = 1;
        for (var a = 0; a < k; a++) {
          final ra = row[a] * wgt;
          if (ra == 0) continue;
          for (var b2 = a; b2 < k; b2++) {
            xtwx[a][b2] += ra * row[b2];
          }
        }
      }
      for (var a = 0; a < k; a++) {
        for (var b2 = a; b2 < k; b2++) {
          final v = xtwx[a][b2];
          xtwx[b2][a] = v;
          xtwx[a][b2] = v;
        }
      }
      for (var j = 0; j < d; j++) {
        grad[j] -= l2 * beta[j];
        xtwx[j][j] += l2;
      }
      // 解 H·Δ = g，β += Δ
      final delta = _solveSymmetric(xtwx, grad);
      if (delta == null) break;
      var maxStep = 0.0;
      for (var a = 0; a < k; a++) {
        beta[a] += delta[a];
        final ad = delta[a].abs();
        if (ad > maxStep) maxStep = ad;
      }
      if (maxStep < tol) break;
    }

    return LogRegModel(
      weights: [for (var j = 0; j < d; j++) beta[j]],
      bias: beta[d],
      mean: mean,
      std: std,
    );
  }

  final List<double> weights;
  final double bias;
  final List<double> mean;
  final List<double> std;

  int get featureCount => weights.length;

  /// 预测 P(正类)。原始特征入口，内部用训练时的 [mean] / [std] 标准化。
  double predictProba(List<double> raw) {
    if (raw.length != weights.length) {
      throw ArgumentError('特征维度不符：期望 ${weights.length}，实际 ${raw.length}');
    }
    var s = bias;
    for (var j = 0; j < weights.length; j++) {
      s += weights[j] * (raw[j] - mean[j]) / std[j];
    }
    return 1 / (1 + math.exp(-s));
  }

  List<double> predictAll(List<List<double>> xs) =>
      [for (final x in xs) predictProba(x)];

  /// 平均对数损失。评估校准用；越小越好。
  double logLoss(List<List<double>> xs, List<int> ys) {
    if (xs.isEmpty) return 0;
    var acc = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final p = predictProba(xs[i]).clamp(1e-12, 1 - 1e-12);
      acc += ys[i] == 1 ? -math.log(p) : -math.log(1 - p);
    }
    return acc / xs.length;
  }

  /// 预测的胜率（0~100）。与 `StockScore.score` 同口径，便于两种方案对比。
  double score(List<double> raw) => predictProba(raw) * 100;

  Map<String, dynamic> toJson() => {
        'weights': weights,
        'bias': bias,
        'mean': mean,
        'std': std,
      };

  factory LogRegModel.fromJson(Map<String, dynamic> json) => LogRegModel(
        weights: [for (final v in json['weights'] as List) (v as num).toDouble()],
        bias: (json['bias'] as num).toDouble(),
        mean: [for (final v in json['mean'] as List) (v as num).toDouble()],
        std: [for (final v in json['std'] as List) (v as num).toDouble()],
      );

  static LogRegModel? fromJsonString(String s) {
    try {
      return LogRegModel.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// 解线性系统 A·x = b A·x = b（带部分选主元的 Cholesky 无法处理奇异，
/// 所以用高斯-約旦 + 主元；规模只有特征数级别，性能无所谓）。
/// A 奇异时返回 null（调用方决定怎么退化）。
List<double>? _solveSymmetric(List<List<double>> a, List<double> b) {
  final k = b.length;
  final m = [for (var i = 0; i < k; i++) List<double>.from(a[i])];
  final v = List<double>.from(b);
  for (var col = 0; col < k; col++) {
    var piv = col;
    var best = m[col][col].abs();
    for (var r = col + 1; r < k; r++) {
      final cand = m[r][col].abs();
      if (cand > best) {
        best = cand;
        piv = r;
      }
    }
    if (best < 1e-14) return null; // 奇异或接近奇异
    if (piv != col) {
      final t = m[piv];
      m[piv] = m[col];
      m[col] = t;
      final tv = v[piv];
      v[piv] = v[col];
      v[col] = tv;
    }
    final d = m[col][col];
    for (var r = col + 1; r < k; r++) {
      final f = m[r][col] / d;
      if (f == 0) continue;
      for (var c = col; c < k; c++) {
        m[r][c] -= f * m[col][c];
      }
      v[r] -= f * v[col];
    }
  }
  final x = List<double>.filled(k, 0);
  for (var r = k - 1; r >= 0; r--) {
    var s2 = v[r];
    for (var c = r + 1; c < k; c++) {
      s2 -= m[r][c] * x[c];
    }
    x[r] = s2 / m[r][r];
  }
  return x;
}
