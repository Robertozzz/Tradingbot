import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/api.dart';
import 'package:tradingbot/charts.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic>? summary;
  Map<String, dynamic>? pnl;
  Timer? timer;
  String range = '1D';
  final fMoney = NumberFormat.compactCurrency(symbol: '\$');

  @override
  void initState() {
    super.initState();
    _load();
    _loadPnl();
    timer = Timer.periodic(const Duration(seconds: 15), (_) {
      _load();
      _loadPnl();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.summary();
      setState(() => summary = d);
    } catch (_) {}
  }

  Future<void> _loadPnl() async {
    try {
      final d = await Api.ibkrPnlSummary();
      setState(() => pnl = d);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final total = (s?['total_usd'] as num?)?.toDouble() ?? 0;
    final changePct = (s?['change_window_pct'] as num?)?.toDouble() ?? 0;
    final points = s?['spark_points'] ?? [];
    int take = 24; // 1D default
    if (range == '1W') take = 24 * 7;
    if (range == '1M') take = 24 * 30;
    final spots = spotsFromPoints(points, takeLast: take);
    final alloc = slicesFromAllocation(s?['top_allocation']);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Text('Dashboard', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 12),
              Chip(
                label: Text(s == null ? 'Loading…' : 'Live'),
                backgroundColor: const Color(0x1A4CC38A),
                side: const BorderSide(color: Color(0xFF1F4436)),
                labelStyle: const TextStyle(color: Color(0xFF78E3B7)),
              ),
              const Spacer(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '1D', label: Text('1D')),
                  ButtonSegment(value: '1W', label: Text('1W')),
                  ButtonSegment(value: '1M', label: Text('1M')),
                ],
                selected: {range},
                onSelectionChanged: (v) => setState(() => range = v.first),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _load,
                child: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _kpi('Total portfolio', fMoney.format(total)),
              _kpi('Portfolio change (24h)',
                  '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%'),
              _kpi('Realized PnL (today)',
                  fMoney.format((pnl?['realized'] as num? ?? 0).toDouble())),
              _kpi('Unrealized PnL',
                  fMoney.format((pnl?['unrealized'] as num? ?? 0).toDouble())),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cardHeader('Wealth',
                          trailing: Text(DateFormat.yMd()
                              .add_Hm()
                              .format(DateTime.now()))),
                      const SizedBox(height: 8),
                      lineChart(spots, height: 260),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cardHeader('Allocation',
                          trailing: const Chip(label: Text('Top assets'))),
                      const SizedBox(height: 8),
                      donutChart(alloc, size: 260),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kpi(String label, String value) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E1526),
        border: Border.all(color: const Color(0xFF22314E)),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        border: Border.all(color: const Color(0xFF22314E)),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _cardHeader(String title, {Widget? trailing}) {
    return Row(
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }
}
