import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'api.dart';

/// ------------------------------
/// Demo data models
/// ------------------------------
class AccountModel {
  final String id;
  final String name;
  final String provider; // e.g. Binance spot
  final bool active;
  final double total; // total equity
  final double available;
  final double dayChangePct; // 24h change
  final List<double> spark; // intraday sparkline points
  final Color color; // used in charts

  AccountModel({
    required this.id,
    required this.name,
    required this.provider,
    required this.active,
    required this.total,
    required this.available,
    required this.dayChangePct,
    required this.spark,
    required this.color,
  });
}

enum Timeframe { d1, d3, w1, m1, m3, y1 }

extension on Timeframe {
  String get label => {
        Timeframe.d1: '1d',
        Timeframe.d3: '3d',
        Timeframe.w1: '1w',
        Timeframe.m1: '1m',
        Timeframe.m3: '3m',
        Timeframe.y1: '1y',
      }[this]!;
}

/// ------------------------------
/// AccountsPage
/// ------------------------------
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<AccountModel> accounts = [];
  late Map<Timeframe, List<FlSpot>> portfolioSeries;
  Timeframe selectedTf = Timeframe.d1;
  String search = '';
  String sort = 'Total';
  bool asGrid = true;

  @override
  void initState() {
    super.initState();
    portfolioSeries = _demoPortfolioSeries(); // keep dashboard chart for now
    _loadIbkrAccounts(); // IBKR only
  }

  Future<void> _loadIbkrAccounts() async {
    try {
      final obj = await Api.ibkrAccounts(); // Map<String, dynamic>
      if (obj.isEmpty) return;

      // Accept either {"DU123": {...}} OR {"accounts":[{...},{...}]}
      Iterable<Map<String, dynamic>> tagMaps;
      if (obj['accounts'] is List) {
        tagMaps = (obj['accounts'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map));
      } else {
        tagMaps = obj.values.map((e) => Map<String, dynamic>.from(e as Map));
      }

      double net = 0, cash = 0;
      for (final tags in tagMaps) {
        net += (_toNum(tags['NetLiquidation']) ?? 0).toDouble();
        cash += (_toNum(tags['TotalCashValue'] ?? tags['CashBalance']) ?? 0)
            .toDouble();
      }
      if (net <= 0 && cash <= 0) return;

      final base = net;
      final spark =
          List<double>.generate(24, (i) => base * (0.995 + i * 0.0002));

      setState(() {
        accounts = [
          AccountModel(
            id: 'ibkr_sum',
            name: 'IBKR',
            provider: 'Interactive Brokers',
            active: true,
            total: net,
            available: cash,
            dayChangePct: 0,
            spark: spark,
            color: const Color(0xFFFF6B57),
          ),
        ];
      });
    } catch (e) {
      //  optionally log e
    }
  }

  num? _toNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    return num.tryParse(v.toString().replaceAll(',', ''));
  }

  Map<Timeframe, List<FlSpot>> _demoPortfolioSeries() {
    final rnd = Random(7);
    List<FlSpot> make(int n, double start, double varRange) {
      double x = 0;
      double y = start;
      final List<FlSpot> pts = [];
      for (int i = 0; i < n; i++) {
        y += (rnd.nextDouble() * varRange - varRange / 2);
        pts.add(FlSpot(x, y));
        x += 1;
      }
      return pts;
    }

    return {
      Timeframe.d1: make(24, 46500, 500),
      Timeframe.d3: make(36, 45500, 700),
      Timeframe.w1: make(30, 44000, 1000),
      Timeframe.m1: make(30, 42000, 1500),
      Timeframe.m3: make(30, 40000, 2000),
      Timeframe.y1: make(30, 35000, 2500),
    };
  }

  // --- UI helpers ---
  double get totalEquity => accounts.fold<double>(0, (p, a) => p + a.total);

  List<AccountModel> get filtered {
    final s = search.trim().toLowerCase();
    var list = accounts
        .where((a) =>
            s.isEmpty ||
            a.name.toLowerCase().contains(s) ||
            a.provider.toLowerCase().contains(s))
        .toList();
    list.sort((a, b) {
      switch (sort) {
        case 'Name':
          return a.name.compareTo(b.name);
        case 'Change':
          return b.dayChangePct.compareTo(a.dayChangePct);
        default:
          return b.total.compareTo(a.total);
      }
    });
    return list;
  }

  void _createDummyAccount() {
    setState(() {
      final i = accounts.length + 1;
      final rnd = Random(i * 13);
      accounts = List.of(accounts)
        ..add(AccountModel(
          id: 'acc_$i',
          name: 'New Account $i',
          provider: 'Demo Broker',
          active: rnd.nextBool(),
          total: 1500 + rnd.nextInt(5000).toDouble(),
          available: 200 + rnd.nextInt(1200).toDouble(),
          dayChangePct: rnd.nextDouble() * 6 - 3,
          spark: List<double>.generate(
              24, (j) => (2000 + rnd.nextInt(800)).toDouble()),
          color: Color((0xFF000000 | (rnd.nextInt(0xFFFFFF))) | 0xFF000000),
        ));
    });
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    final wide = MediaQuery.of(context).size.width >= 1100;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Top row: total allocation + portfolio chart
        Flex(
          direction: wide ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: wide ? 320 : double.infinity,
              child: _AllocationPieCard(
                accounts: accounts,
                total: totalEquity,
              ),
            ),
            const SizedBox(width: 16, height: 16),
            Expanded(
              child: _PortfolioChartCard(
                spots: portfolioSeries[selectedTf]!,
                selected: selectedTf,
                onSelect: (tf) => setState(() => selectedTf = tf),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // Header toolbar
        _Toolbar(
          asGrid: asGrid,
          onToggleLayout: (v) => setState(() => asGrid = v),
          onCreate: _createDummyAccount,
          onSortChanged: (v) => setState(() => sort = v),
          sort: sort,
          onSearch: (txt) => setState(() => search = txt),
        ),
        const SizedBox(height: 12),

        // Accounts list/grid
        asGrid
            ? _AccountsGrid(items: filtered)
            : _AccountsList(items: filtered),
      ],
    );
  }
}

/// ------------------------------
/// Allocation Pie
/// ------------------------------
class _AllocationPieCard extends StatelessWidget {
  final List<AccountModel> accounts;
  final double total;
  const _AllocationPieCard({required this.accounts, required this.total});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = <PieChartSectionData>[];
    for (int i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      final value = a.total;
      if (value <= 0) continue;
      sections.add(
        PieChartSectionData(
          value: value,
          radius: 72,
          title: '',
          color: a.color,
          showTitle: false,
        ),
      );
    }

    return Card(
      elevation: 0,
      color: theme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Accounts allocation',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sections: sections,
                      centerSpaceRadius: 80,
                      sectionsSpace: 3,
                      borderData: FlBorderData(show: false),
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('\$${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      const Text('Total',
                          style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: accounts.map((a) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: a.color, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(a.name, style: const TextStyle(color: Colors.white70)),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// ------------------------------
/// Portfolio Line Chart
/// ------------------------------
class _PortfolioChartCard extends StatelessWidget {
  final List<FlSpot> spots;
  final Timeframe selected;
  final ValueChanged<Timeframe> onSelect;
  const _PortfolioChartCard({
    required this.spots,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    return Card(
      elevation: 0,
      color: theme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Portfolio Change',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Wrap(
                  spacing: 8,
                  children: Timeframe.values.map((tf) {
                    final selectedStyle = BoxDecoration(
                      color: tf == selected
                          ? color.withValues(alpha: 0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: tf == selected ? color : Colors.white24),
                    );
                    return InkWell(
                      onTap: () => onSelect(tf),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: selectedStyle,
                        child: Text(tf.label,
                            style: TextStyle(
                              color: tf == selected
                                  ? Colors.white
                                  : Colors.white70,
                              fontWeight: FontWeight.w600,
                            )),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minY: spots.map((e) => e.y).reduce(min) * 0.98,
                  maxY: spots.map((e) => e.y).reduce(max) * 1.02,
                  gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: 200),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                        sideTitles:
                            SideTitles(showTitles: true, reservedSize: 40)),
                    bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                            showTitles: true,
                            interval: (spots.length / 6).ceilToDouble())),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  lineTouchData: LineTouchData(handleBuiltInTouches: true),
                  lineBarsData: [
                    LineChartBarData(
                      isCurved: true,
                      spots: spots,
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                      color: color,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ------------------------------
/// Toolbar
/// ------------------------------
class _Toolbar extends StatelessWidget {
  final bool asGrid;
  final ValueChanged<bool> onToggleLayout;
  final VoidCallback onCreate;
  final String sort;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<String> onSearch;

  const _Toolbar({
    required this.asGrid,
    required this.onToggleLayout,
    required this.onCreate,
    required this.sort,
    required this.onSortChanged,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search...',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: theme.cardColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            ),
            onChanged: onSearch,
          ),
        ),
        const SizedBox(width: 12),
        DropdownButtonHideUnderline(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24),
            ),
            child: DropdownButton<String>(
              value: sort,
              items: const [
                DropdownMenuItem(value: 'Total', child: Text('Total')),
                DropdownMenuItem(value: 'Name', child: Text('Name')),
                DropdownMenuItem(value: 'Change', child: Text('Change (24h)')),
              ],
              onChanged: (v) {
                if (v != null) onSortChanged(v);
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: asGrid ? 'Grid view' : 'List view',
          child: InkWell(
            onTap: () => onToggleLayout(!asGrid),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Icon(
                  asGrid ? Icons.grid_view_rounded : Icons.view_list_rounded),
            ),
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Create'),
        ),
      ],
    );
  }
}

/// ------------------------------
/// Accounts: Grid & List
/// ------------------------------
class _AccountsGrid extends StatelessWidget {
  final List<AccountModel> items;
  const _AccountsGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cross = w ~/ 380; // rough card width
    return GridView.builder(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross.clamp(1, 4),
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1.65,
      ),
      itemBuilder: (_, i) => _AccountCard(a: items[i]),
    );
  }
}

class _AccountsList extends StatelessWidget {
  final List<AccountModel> items;
  const _AccountsList({required this.items});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: items.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _AccountCard(a: items[i]),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AccountModel a;
  const _AccountCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = a.dayChangePct >= 0;
    final deltaColor =
        positive ? const Color(0xFF4CC38A) : const Color(0xFFEF4444);
    final deltaIcon = positive ? Icons.trending_up : Icons.trending_down;

    return Card(
      elevation: 0,
      color: theme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _LogoDot(color: a.color),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(a.provider,
                        style: const TextStyle(color: Colors.white54)),
                  ],
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Status + small bars
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: a.active
                        ? Colors.green.withValues(alpha: 0.15)
                        : Colors.white12,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: a.active ? Colors.green : Colors.white24),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.circle,
                          size: 8,
                          color: a.active ? Colors.green : Colors.white54),
                      const SizedBox(width: 6),
                      Text(a.active ? 'Active' : 'Inactive'),
                    ],
                  ),
                ),
                const Spacer(),
                Icon(deltaIcon, size: 16, color: deltaColor),
                const SizedBox(width: 4),
                Text('${a.dayChangePct.abs().toStringAsFixed(2)}%',
                    style: TextStyle(color: deltaColor)),
              ],
            ),
            const SizedBox(height: 10),
            // Totals
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _kv('Total', '\$${a.total.toStringAsFixed(2)}'),
                _kv('Available', '\$${a.available.toStringAsFixed(2)}'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: LineChart(
                LineChartData(
                  minY: a.spark.reduce(min) * 0.98,
                  maxY: a.spark.reduce(max) * 1.02,
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  lineTouchData: const LineTouchData(enabled: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: List.generate(a.spark.length,
                          (i) => FlSpot(i.toDouble(), a.spark[i])),
                      isCurved: true,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      color: a.color,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      );
}

class _LogoDot extends StatelessWidget {
  final Color color;
  const _LogoDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0.5)],
        ),
      ),
      child: const Icon(Icons.token, size: 20, color: Colors.white),
    );
  }
}
