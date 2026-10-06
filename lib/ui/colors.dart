/// 应用配色（方案C 工作台）。主题与各页面共用，改色只改这里。
library;

import 'package:flutter/material.dart';

/// 主题强调色（可切换）；红涨绿跌是行情惯例，不随主题变。
enum AccentColor {
  red,
  charcoal,
  blue,
  green;

  String get label => switch (this) {
        AccentColor.red => '红',
        AccentColor.charcoal => '深',
        AccentColor.blue => '蓝',
        AccentColor.green => '绿',
      };

  Color get color => switch (this) {
        AccentColor.red => const Color(0xFFD7263D),
        AccentColor.charcoal => const Color(0xFF2E3A47),
        AccentColor.blue => const Color(0xFF2563EB),
        AccentColor.green => const Color(0xFF0E8F62),
      };

  static AccentColor fromName(String? name) => AccentColor.values
      .firstWhere((e) => e.name == name, orElse: () => AccentColor.red);
}

/// 让页面内组件（开关/按钮/徽章）读取当前强调色，切换时随外壳重建。
class AccentScope extends InheritedWidget {
  const AccentScope({super.key, required this.color, required super.child});

  final Color color;

  static Color of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccentScope>()?.color ??
      AppColors.red; // 无作用域时回退默认红（直接 pump 页面的测试/预览场景）

  @override
  bool updateShouldNotify(AccentScope oldWidget) => oldWidget.color != color;
}

/// 规则列表统计行的涨跌语义色：绿色主题下绿涨红跌，其余主题红涨绿跌。
///
/// 只用于统计行；结果表 / K 线是另一套（固定红涨绿跌），别顺手混用。
({Color up, Color down}) upDownColorsOf(BuildContext context) =>
    AccentScope.of(context) == AccentColor.green.color
        ? (up: AppColors.down, down: AppColors.red)
        : (up: AppColors.red, down: AppColors.down);

/// 日K均线周期与色板（蜡烛图与详情页图例共用，改色/增周期只改这里；
/// 两个列表按下标一一对应）。
const maPeriods = [5, 10, 20, 30, 60];
const maColors = [
  Color(0xFFF59E0B), // MA5 琥珀
  Color(0xFF3B82F6), // MA10 蓝
  Color(0xFF8B5CF6), // MA20 紫
  Color(0xFF06B6D4), // MA30 青
  Color(0xFF334155), // MA60 石板深灰
];

class AppColors {
  AppColors._();

  static const bg = Color(0xFFE9EBEF);
  static const border = Color(0xFFDCDFE5);
  static const red = Color(0xFFD7263D); // 默认强调色（red 主题）
  static const down = Color(0xFF0A8F62); // 下跌
  static const text = Color(0xFF20262F);
  static const dim = Color(0xFF8D95A3);
  static const headerBg = Color(0xFFF7F8FA);
  static const zebra = Color(0xFFFBFCFD);
  static const switchOff = Color(0xFFCDD3DC); // 未选中开关轨道（浅色）
  static const seed = Color(0xFF46566B); // 主题种子：中性石板灰，避免整体泛粉
}
