import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

Widget lineChart(List<FlSpot> spots, {double height = 220}) {
  return SizedBox(
    height: height,
    child: LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            spots: spots,
            barWidth: 2,
            color: const Color(0xFF60A5FA),
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    ),
  );
}

Widget sparkLine(List<double> values, {double height = 36}) {
  final spots = List<FlSpot>.generate(values.length,
      (i) => FlSpot(i.toDouble(), values[i]));
  return SizedBox(height: height, width: 120, child: lineChart(spots, height: height));
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
  Color(0xFF60A5FA), Color(0xFF4CC38A), Color(0xFFF59E0B), Color(0xFFEF4444),
  Color(0xFFA78BFA), Color(0xFF22D3EE), Color(0xFFF472B6), Color(0xFF34D399),
];

// helpers to map data
List<FlSpot> spotsFromPoints(dynamic points, {int takeLast = 0}) {
  // points expected as [[ts, value], ...] or [[index, value], ...]
  final p = (points as List?) ?? [];
  final picked = takeLast > 0 && p.length > takeLast ? p.sublist(p.length - takeLast) : p;
  return List<FlSpot>.generate(picked.length, (i) {
    final v = picked[i];
    final y = (v[1] as num).toDouble();
    return FlSpot(i.toDouble(), y);
  });
}

List<Slice> slicesFromAllocation(dynamic topAlloc) {
  final a = (topAlloc as List?) ?? [];
  return a.map((e) => Slice('${e['symbol']}', (e['value_usd'] as num?)?.toDouble() ?? 0)).toList();
}
