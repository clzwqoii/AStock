import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/logreg.dart';

void main() {
  group('auc 排名能力', () {
    test('完全分开 → 1.0', () {
      expect(auc([0.01, 0.02, 0.9, 0.95], const [0, 0, 1, 1]), 1.0);
    });

    test('完全反了 → 0.25', () {
      // oracle: 正样本分数反而低于负样本
      expect(auc([0.9, 0.8, 0.7, 0.6], const [0, 1, 0, 1]), closeTo(0.25, 1e-12));
    });

    test('一半超过一半平局 → 0.75', () {
      expect(auc([0.1, 0.4, 0.35, 0.8], const [0, 0, 1, 1]), closeTo(0.75, 1e-12));
    });

    test('同分算半个，不是整分', () {
      expect(auc([0.5, 0.5], const [1, 0]), closeTo(0.5, 1e-12));
    });

    test('只有一类标签时无法定义，返回 null', () {
      expect(auc([0.9, 0.1], const [1, 1]), isNull);
      expect(auc([0.9, 0.1], const [0, 0]), isNull);
    });
  });

  group('LogRegModel 训练', () {
    // 一维可分的玩具数据：x>0 全是正类
    List<List<double>> separable() => [
          for (var i = 0; i < 40; i++)
            if (i.isEven) [1.0 + i / 100] else [-1.0 - i / 100],
        ];
    List<int> separableY() => [for (var i = 0; i < 40; i++) i.isEven ? 1 : 0];

    test('可分数据上 AUC 达到 1', () {
      final m = LogRegModel.train(separable(), separableY(),
          maxIter: 400, l2: 0);
      expect(auc(m.predictAll(separable()), separableY()), 1.0);
    });

    test('训练损失单调不增（允许平台期）', () {
      var last = double.infinity;
      var bad = 0;
      for (final epochs in [10, 50, 200, 800]) {
        final m = LogRegModel.train(separable(), separableY(),
            maxIter: epochs, l2: 0);
        final loss = m.logLoss(separable(), separableY());
        if (loss > last + 1e-9) bad++;
        last = loss;
      }
      expect(bad, 0, reason: '训练轮数越多损失不该上升');
    });

    test('L2 正则把权重压小', () {
      final plain = LogRegModel.train(separable(), separableY(),
          maxIter: 400, l2: 0);
      final reg = LogRegModel.train(separable(), separableY(),
          maxIter: 400, l2: 5);
      expect(reg.weights[0].abs(), lessThan(plain.weights[0].abs()));
    });

    test('确定性：同数据同参数两次训练逐位一致（月度重跑可复现）', () {
      final a = LogRegModel.train(separable(), separableY(), maxIter: 100);
      final b = LogRegModel.train(separable(), separableY(), maxIter: 100);
      for (var i = 0; i < a.weights.length; i++) {
        expect(b.weights[i], a.weights[i]);
      }
      expect(b.bias, a.bias);
    });

    test('空特征/空样本抛 ArgumentError，不静默产出废模型', () {
      expect(() => LogRegModel.train(const [], const <int>[]),
          throwsA(isA<ArgumentError>()));
      expect(
          () => LogRegModel.train([
                [1.0]
              ], const []),
          throwsA(isA<ArgumentError>()));
    });

    test('特征维度不一致抛 ArgumentError', () {
      expect(
          () => LogRegModel.train([
                [1.0, 2.0],
                [1.0]
          ], const [0, 1]),
          throwsA(isA<ArgumentError>()));
    });

    test('JSON 往返逐位一致（推理与训练解耦）', () {
      final m =
          LogRegModel.train(separable(), separableY(), maxIter: 60);
      final back = LogRegModel.fromJson(m.toJson());
      expect(back.weights, m.weights);
      expect(back.bias, m.bias);
      expect(back.mean, m.mean);
      expect(back.std, m.std);
      expect(back.predictAll(separable()), m.predictAll(separable()));
    });

    test('不可分数据上预测结果严格落在 (0,1) 内', () {
      // 生产数据不可能完全可分（标签有噪声），带 L2 时概率必然在内部。
      final xs = <List<double>>[];
      final ys = <int>[];
      for (var i = 0; i < 120; i++) {
        final a = (i % 11) / 11.0;
        xs.add([a]);
        ys.add((a > 0.5) != (i % 4 == 0) ? 1 : 0); // 25% 翻标签 → 不可分
      }
      final m = LogRegModel.train(xs, ys, maxIter: 60, l2: 0.01);
      for (final p in m.predictAll(xs)) {
        expect(p, greaterThan(0));
        expect(p, lessThan(1));
      }
    });

    test('完全可分且无正则时概率会饱和到 0/1，但排序仍正确', () {
      // 数学事实而非缺陷：可分数据的最优解在无穷远。生产上遇不到
      // （标签有噪声且默认带 L2），契约要写清楚——饱和不影响排序，
      // 只影响"概率"的解释，所以文档强调没验证前别把它当概率。
      final m = LogRegModel.train(separable(), separableY(), maxIter: 400);
      final ps = m.predictAll(separable());
      expect(ps.every((p) => p < 1e-12 || p > 1 - 1e-12), isTrue,
          reason: '可分数据下权重冲到 36，概率被推到两端（_exp 在 ±40 截断，'
              '所以是"趋近"而非精确等于 0/1）');
      expect(auc(ps, separableY()), 1.0);
    });

    test('常数特征（std=0）不炸，被当成无信息剔除', () {
      final xs = [
        [5.0, 1.0],
        [5.0, -1.0],
        [5.0, 2.0],
        [5.0, -2.0],
      ];
      final m = LogRegModel.train(xs, const [0, 1, 1, 0], maxIter: 50);
      expect(m.predictProba([5.0, 0.5]), greaterThan(0));
      expect(m.predictProba([5.0, 0.5]), lessThan(1));
      // 常数那列标准化会除零，必须被置 0 而不是 NaN
      expect(m.weights[0].isNaN, isFalse);
    });
  });

  group('与 sklearn 的 oracle 对拍（防求解器静默失准）', () {
    // 下面这组期望值不是手算的，是拿 sklearn 1.8.0 对**同一个目标**
    // （和形式 Σlogloss + (l2/2)||w||²，即 C = 1/l2 = 0.25）解出来的：
    //   SK W >>> 1.013677,0.394945,-0.375186
    //   SK B >>> 0.104948
    //   SK LOSS >>> 0.55632712
    //   SK AUC >>> 0.795423
    // 曾经因为两处 bug 对不上：手写 _exp 截断级数在 f→1 时偏 20%；
    // 以及梯度/Hessian 用和形式而 L2 按均值形式。两者都表现为
    // "能跑但收敛不到真最优"，只有逐位对拍才暴露。
    test('不可分数据上系数与 sklearn 一致到 6 位', () {
      final xs = <List<double>>[];
      final ys = <int>[];
      for (var i = 0; i < 400; i++) {
        final a = (i % 17) / 17.0;
        final b = (i % 5) / 5.0;
        final c = (i % 3) / 3.0;
        xs.add([a, b, c]);
        ys.add((2 * a + b - c > 0.8) != (i % 5 == 3) ? 1 : 0);
      }
      final m = LogRegModel.train(xs, ys, maxIter: 60, l2: 4.0);
      expect(m.weights[0], closeTo(1.013677, 1e-5));
      expect(m.weights[1], closeTo(0.394945, 1e-5));
      expect(m.weights[2], closeTo(-0.375186, 1e-5));
      expect(m.bias, closeTo(0.104948, 1e-5));
      expect(m.logLoss(xs, ys), closeTo(0.55632712, 1e-6));
      expect(auc(m.predictAll(xs), ys), closeTo(0.795423, 1e-5));
    });
  });
}
