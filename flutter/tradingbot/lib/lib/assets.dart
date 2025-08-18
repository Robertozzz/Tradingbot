import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:tradingbot/lib/charts.dart';

import 'asset_lookup.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  Timer? timer;
  final fMoney = NumberFormat.currency(symbol: '\$');
  List<Map<String, dynamic>> _ibkrPos = const [];
  final Map<String, List<double>> _sparks = {}; // symbol -> 0..1 norm spark
  final Map<int, Map<String, num>> _pnl =
      {}; // conId -> {unrealized, realized, daily}
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();

    _loadIbkr();
    timer = Timer.periodic(const Duration(seconds: 20), (_) {
      _loadIbkr();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _loadIbkr() async {
    try {
      final rows = await Api.ibkrPositions();
      final list = rows
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _ibkrPos = list;
      });
      // fetch tiny history for sparks (best-effort)
      for (final m in list) {
        final s = (m['symbol'] ?? '').toString();
        final conId = (m['conId'] as num?)?.toInt();
        if (s.isEmpty || _sparks.containsKey(s)) continue;
        _loadSpark(symbol: s, conId: conId);
        if (conId != null && !_pnl.containsKey(conId)) _loadPnlSingle(conId);
      }
    } catch (_) {}
  }

  Future<void> _loadSpark({String? symbol, int? conId}) async {
    try {
      final h = await Api.ibkrHistory(
        symbol: symbol,
        conId: conId,
        duration: '1 D',
        barSize: '5 mins',
        what: 'TRADES',
        useRTH: true,
      );
      final bars = (h['bars'] as List?) ?? const [];
      final vals = bars.map((b) => (b['c'] as num).toDouble()).toList();
      if (vals.isNotEmpty) {
        final mn = vals.reduce((a, b) => a < b ? a : b);
        final mx = vals.reduce((a, b) => a > b ? a : b);
        final norm = mx - mn < 1e-9
            ? List.filled(vals.length, 0.5)
            : vals.map((v) => (v - mn) / (mx - mn)).toList();
        if (symbol != null) setState(() => _sparks[symbol] = norm.toList());
      }
    } catch (_) {}
  }

  Future<void> _loadPnlSingle(int conId) async {
    try {
      final d = await Api.ibkrPnlSingle(conId);
      setState(() => _pnl[conId] = {
            'unrealized': (d['unrealized'] as num?) ?? 0,
            'realized': (d['realized'] as num?) ?? 0,
            'daily': (d['daily'] as num?) ?? 0,
          });
    } catch (_) {}
  }

  void _openLookup(String q) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1526),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (_) => AssetLookupSheet(
          initialQuery: q,
          onSelect: (sel) {
            // open trade panel prefilled
            _showAssetPanel(sel['symbol']?.toString() ?? '', sel);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111A2E),
          border: Border.all(color: const Color(0xFF22314E)),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtl,
                    decoration: const InputDecoration(
                        hintText: 'Search & trade (AAPL, ES, EURUSD…)'),
                    onSubmitted: (q) => _openLookup(q),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: () => _openLookup(_searchCtl.text.trim()),
                    child: const Text('Trade / Add')),
              ],
            ),
            const SizedBox(height: 12),
            if (_ibkrPos.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('IBKR Positions',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Account')),
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('Price')),
                    DataColumn(label: Text('Qty')),
                    DataColumn(label: Text('Avg Cost')),
                    DataColumn(label: Text('Unrl P&L')),
                    DataColumn(label: Text('Rlzd P&L')),
                    DataColumn(label: Text('CCY')),
                    DataColumn(label: Text('Exchange')),
                    DataColumn(label: Text('Spark'))
                  ],
                  rows: _ibkrPos.map((m) {
                    final qty = (m['position'] as num?) ?? 0;
                    final avg = (m['avgCost'] as num?) ?? 0;
                    final sym = (m['symbol']?.toString() ?? '');
                    final conId = (m['conId'] as num?)?.toInt();
                    final spark = _sparks[sym] ?? const [];
                    final pn = conId != null ? _pnl[conId] : null;

                    return DataRow(cells: [
                      DataCell(Text(m['account']?.toString() ?? '')),
                      DataCell(InkWell(
                        onTap: () => _showAssetPanel(sym, m),
                        child: Row(children: [
                          Text(sym),
                          const SizedBox(width: 6),
                          const Icon(Icons.open_in_new, size: 14),
                        ]),
                      )),
                      DataCell(Text(m['secType']?.toString() ?? '')),
                      DataCell(FutureBuilder<Map<String, dynamic>>(
                        future: Api.ibkrQuote(conId: conId, symbol: sym),
                        builder: (_, snap) {
                          final px = (snap.data?['last'] ?? snap.data?['close'])
                              as num?;
                          return Text(px == null ? '—' : fMoney.format(px));
                        },
                      )),
                      DataCell(Text(qty.toString())),
                      DataCell(Text(fMoney.format(avg))),
                      DataCell(Text(
                          pn == null
                              ? '—'
                              : fMoney
                                  .format((pn['unrealized'] ?? 0).toDouble()),
                          style: TextStyle(
                              color: ((pn?['unrealized'] ?? 0) >= 0)
                                  ? const Color(0xFF4CC38A)
                                  : const Color(0xFFEF4444)))),
                      DataCell(Text(
                          pn == null
                              ? '—'
                              : fMoney.format((pn['realized'] ?? 0).toDouble()),
                          style: TextStyle(
                              color: ((pn?['realized'] ?? 0) >= 0)
                                  ? const Color(0xFF4CC38A)
                                  : const Color(0xFFEF4444)))),
                      DataCell(Text(m['currency']?.toString() ?? '')),
                      DataCell(Text(m['exchange']?.toString() ?? '')),
                      DataCell(SizedBox(
                          width: 120, height: 36, child: sparkLine(spark))),
                    ]);
                  }).toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showAssetPanel(String symbol, Map<String, dynamic> pos) async {
    Map<String, dynamic>? quote;
    Map<String, dynamic>? hist;
    try {
      final conId = (pos['conId'] as num?)?.toInt();
      quote = await Api.ibkrQuote(conId: conId, symbol: symbol);
      hist = await Api.ibkrHistory(
          conId: conId, symbol: symbol, duration: '5 D', barSize: '30 mins');
    } catch (_) {}

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1526),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (_) =>
          _AssetPanel(symbol: symbol, pos: pos, quote: quote, hist: hist),
    );
  }
}

class _AssetPanel extends StatefulWidget {
  final String symbol;
  final Map<String, dynamic> pos;
  final Map<String, dynamic>? quote;
  final Map<String, dynamic>? hist;
  const _AssetPanel(
      {required this.symbol, required this.pos, this.quote, this.hist});
  @override
  State<_AssetPanel> createState() => _AssetPanelState();
}

class _AssetPanelState extends State<_AssetPanel> {
  String side = 'BUY';
  String type = 'MKT';
  String tif = 'DAY';
  double qty = 1;
  double? lmt;
  bool useTv = false; // toggle TradingView vs fl_chart

  // NEW: live data
  List<Map<String, dynamic>> _orders = const [];
  Map<String, num>? _pnl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshLive();
  }

  Future<void> _refreshLive() async {
    setState(() => _busy = true);
    try {
      // Force the whole chain to int?
      final int? conId = ((widget.pos['conId'] as num?) ??
              (widget.quote?['contract']?['conId'] as num?) ??
              (widget.hist?['contract']?['conId'] as num?))
          ?.toInt();

      // Open orders (filter by conId if possible, else by symbol)
      final oo = await Api.ibkrOpenOrders();
      final filtered = oo
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .where((o) {
        final oc = (o['conId'] as num?)?.toInt();
        if (conId != null && oc != null) return oc == conId;
        return (o['symbol']?.toString() ?? '').toUpperCase() ==
            widget.symbol.toUpperCase();
      }).toList();

      Map<String, num>? pnl;
      if (conId != null) {
        final p = await Api.ibkrPnlSingle(conId); // now matches int
        pnl = {
          'unrealized': (p['unrealized'] as num?) ?? 0,
          'realized': (p['realized'] as num?) ?? 0,
          'daily': (p['daily'] as num?) ?? 0,
        };
      }

      setState(() {
        _orders = filtered;
        _pnl = pnl;
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bars = (widget.hist?['bars'] as List?) ?? const [];
    final spots = bars.map((b) {
      final i = bars.indexOf(b).toDouble();
      return FlSpot(i, (b['c'] as num).toDouble());
    }).toList();
    final avg = (widget.pos['avgCost'] as num?)?.toDouble();
    final heldQty = (widget.pos['position'] as num?)?.toDouble() ?? 0;
    final last = (widget.quote?['last'] ?? widget.quote?['close']) as num?;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(widget.symbol,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18)),
              const Spacer(),
              SwitchListTile(
                dense: true,
                value: useTv,
                onChanged: (v) => setState(() => useTv = v),
                title: const Text('TradingView'),
                contentPadding: EdgeInsets.zero,
              ),
            ]),
            const SizedBox(height: 8),
            // Price / Position / PnL chips
            if (last != null || heldQty != 0 || _pnl != null) ...[
              Row(children: [
                Text(
                  last == null
                      ? '—'
                      : NumberFormat.currency(symbol: '\$').format(last),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 18),
                ),
                const SizedBox(width: 12),
                if (heldQty != 0 && avg != null)
                  Text(
                    'Pos: ${heldQty.toStringAsFixed(4)} @ ${NumberFormat.currency(symbol: '\$').format(avg)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                const Spacer(),
                if (_pnl != null)
                  Wrap(spacing: 6, children: [
                    Chip(
                        label: Text(
                            'Unrl ${NumberFormat.currency(symbol: '\$').format((_pnl!['unrealized'] ?? 0).toDouble())}')),
                    Chip(
                        label: Text(
                            'Rlzd ${NumberFormat.currency(symbol: '\$').format((_pnl!['realized'] ?? 0).toDouble())}')),
                    Chip(
                        label: Text(
                            'Daily ${NumberFormat.currency(symbol: '\$').format((_pnl!['daily'] ?? 0).toDouble())}')),
                  ]),
              ]),
              const SizedBox(height: 8),
            ],
            Container(
              height: 260,
              decoration: BoxDecoration(
                color: const Color(0xFF111A2E),
                border: Border.all(color: const Color(0xFF22314E)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: useTv
                  ? const Center(
                      child:
                          Text('Embed TV here (see tradingview_widget.dart)'))
                  : LineChart(LineChartData(
                      gridData: FlGridData(show: true, drawVerticalLine: false),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      lineBarsData: [
                        LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            barWidth: 2,
                            dotData: const FlDotData(show: false)),
                      ],
                    )),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _chip('Qty', trailing: _qtyField()),
              _chip('Type',
                  trailing: _seg(
                      ['MKT', 'LMT'], type, (v) => setState(() => type = v))),
              if (type == 'LMT') _chip('Limit', trailing: _lmtField()),
              _chip('TIF',
                  trailing: _seg(
                      ['DAY', 'GTC'], tif, (v) => setState(() => tif = v))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1F4436)),
                      onPressed: _busy ? null : () => _place('BUY'),
                      child: const Text('Buy'))),
              const SizedBox(width: 10),
              Expanded(
                  child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF5A1F1F)),
                      onPressed: _busy ? null : () => _place('SELL'),
                      child: const Text('Sell'))),
            ]),
            const SizedBox(height: 16),
            // Open Orders (for this asset)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111A2E),
                border: Border.all(color: const Color(0xFF22314E)),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Text('Open Orders',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(
                        onPressed: _refreshLive,
                        icon: const Icon(Icons.refresh)),
                  ]),
                  const SizedBox(height: 6),
                  _orders.isEmpty
                      ? const Text('None')
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('OrderId')),
                              DataColumn(label: Text('Side')),
                              DataColumn(label: Text('Qty')),
                              DataColumn(label: Text('Type')),
                              DataColumn(label: Text('Limit')),
                              DataColumn(label: Text('TIF')),
                              DataColumn(label: Text('Status')),
                              DataColumn(label: Text('Filled')),
                              DataColumn(label: Text('Remain')),
                              DataColumn(label: Text('Cancel')),
                            ],
                            rows: _orders
                                .map((o) => DataRow(cells: [
                                      DataCell(Text('${o['orderId'] ?? ''}')),
                                      DataCell(Text('${o['action'] ?? ''}')),
                                      DataCell(Text('${o['qty'] ?? ''}')),
                                      DataCell(Text('${o['type'] ?? ''}')),
                                      DataCell(Text(o['lmt'] == null
                                          ? '—'
                                          : '${o['lmt']}')),
                                      DataCell(Text('${o['tif'] ?? ''}')),
                                      DataCell(Text('${o['status'] ?? ''}')),
                                      DataCell(Text('${o['filled'] ?? 0}')),
                                      DataCell(Text('${o['remaining'] ?? 0}')),
                                      DataCell(IconButton(
                                        icon: const Icon(Icons.cancel),
                                        onPressed: () {
                                          final id =
                                              (o['orderId'] as num?)?.toInt();
                                          if (id != null) {
                                            Api.ibkrCancelOrder(id)
                                                .then((_) => _refreshLive());
                                          }
                                        },
                                      )),
                                    ]))
                                .toList(),
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- small UI helper used above ---
  Widget _chip(String label, {required Widget trailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        border: Border.all(color: const Color(0xFF22314E)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  Widget _seg(List<String> items, String value, ValueChanged<String> on) {
    return SegmentedButton<String>(
      segments: [
        for (final s in items) ButtonSegment(value: s, label: Text(s))
      ],
      selected: {value},
      onSelectionChanged: (v) => on(v.first),
    );
  }

  Widget _qtyField() => SizedBox(
        width: 100,
        child: TextField(
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: 'Qty'),
          onChanged: (t) => setState(() => qty = double.tryParse(t) ?? qty),
        ),
      );
  Widget _lmtField() => SizedBox(
        width: 120,
        child: TextField(
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: 'Limit'),
          onChanged: (t) => setState(() => lmt = double.tryParse(t)),
        ),
      );

  Future<void> _place(String side) async {
    try {
      final conId = (widget.quote?['contract']?['conId'] as num?) ??
          (widget.hist?['contract']?['conId'] as num?);
      await Api.ibkrPlaceOrder(
        symbol: conId == null ? widget.symbol : null,
        conId: conId?.toInt(),
        side: side,
        type: type,
        qty: qty,
        limitPrice: lmt,
        tif: tif,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Order sent')));
      _refreshLive();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Order failed: $e')));
    }
  }
}
