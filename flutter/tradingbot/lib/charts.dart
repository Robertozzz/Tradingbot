import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Generic line chart with a few knobs so callers don't inline chart code.
Widget lineChart(
  List<FlSpot> spots, {
  double height = 220,
  bool showGrid = false,
  bool drawVerticalGrid = false,
  bool showTitles = false,
  double? minY,
  double? maxY,
  double barWidth = 2,
  Color color = const Color(0xFF60A5FA),
}) {
  return SizedBox(
    height: height,
    child: LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData:
            FlGridData(show: showGrid, drawVerticalLine: drawVerticalGrid),
        titlesData:
            showTitles ? const FlTitlesData() : const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            spots: spots,
            barWidth: barWidth,
            color: color,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    ),
  );
}

/// Compact sparkline. If [leftLabel] is provided, show only 0/1 axis labels
/// using the callback (useful when values are normalized).
Widget sparkLine(
  List<double> values, {
  double height = 36,
  String Function(double v)? leftLabel,
  String Function(double x)? bottomLabel,
}) {
  final spots = List<FlSpot>.generate(
      values.length, (i) => FlSpot(i.toDouble(), values[i]));
  return SizedBox(
    height: height,
    width: 120,
    child: LineChart(
      LineChartData(
        minY: 0,
        maxY: 1,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: leftLabel == null
            ? (bottomLabel == null
                ? const FlTitlesData(show: false)
                : FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 20,
                        interval: 1,
                        getTitlesWidget: (v, _) {
                          final txt = bottomLabel(v);
                          if (txt.isEmpty) return const SizedBox.shrink();
                          return Text(txt,
                              style: const TextStyle(
                                  fontSize: 9, color: Colors.white60));
                        },
                      ),
                    ),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ))
            : FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: bottomLabel != null,
                    reservedSize: 20,
                    interval: 1,
                    getTitlesWidget: (v, _) {
                      if (bottomLabel == null) return const SizedBox.shrink();
                      final txt = bottomLabel(v);
                      if (txt.isEmpty) return const SizedBox.shrink();
                      return Text(txt,
                          style: const TextStyle(
                              fontSize: 9, color: Colors.white60));
                    },
                  ),
                ),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    interval: 1,
                    getTitlesWidget: (v, _) {
                      final txt = leftLabel(v);
                      if (txt.isEmpty) return const SizedBox.shrink();
                      return Text(txt,
                          style: const TextStyle(
                              fontSize: 9, color: Colors.white60));
                    },
                  ),
                ),
              ),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            spots: spots,
            barWidth: 1.0,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            color: const Color(0xFF60A5FA),
          ),
        ],
      ),
    ),
  );
}

Widget donutChart(List<Slice> slices, {double size = 220}) {
  final total = slices.fold<double>(0, (s, e) => s + e.value);
  final sections = <PieChartSectionData>[
    for (int i = 0; i < slices.length; i++)
      PieChartSectionData(
        color: _palette[i % _palette.length],
        value: slices[i].value,
        title: '',
        radius: size * 0.28,
      )
  ];
  return SizedBox(
    height: size,
    width: size,
    child: PieChart(PieChartData(
      sections: total == 0 ? [] : sections,
      sectionsSpace: 0,
      centerSpaceRadius: size * 0.22,
      startDegreeOffset: -90,
      borderData: FlBorderData(show: false),
    )),
  );
}

class Slice {
  final String label;
  final double value;
  Slice(this.label, this.value);
}

const _palette = [
  Color(0xFF60A5FA),
  Color(0xFF4CC38A),
  Color(0xFFF59E0B),
  Color(0xFFEF4444),
  Color(0xFFA78BFA),
  Color(0xFF22D3EE),
  Color(0xFFF472B6),
  Color(0xFF34D399),
];

// helpers to map data
List<FlSpot> spotsFromPoints(dynamic points, {int takeLast = 0}) {
  // points expected as [[ts, value], ...] or [[index, value], ...]
  final p = (points as List?) ?? [];
  final picked =
      takeLast > 0 && p.length > takeLast ? p.sublist(p.length - takeLast) : p;
  return List<FlSpot>.generate(picked.length, (i) {
    final v = picked[i];
    final y = (v[1] as num).toDouble();
    return FlSpot(i.toDouble(), y);
  });
}

List<Slice> slicesFromAllocation(dynamic topAlloc) {
  final a = (topAlloc as List?) ?? [];
  return a
      .map((e) =>
          Slice('${e['symbol']}', (e['value_usd'] as num?)?.toDouble() ?? 0))
      .toList();
}
