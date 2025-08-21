import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:tradingbot/lib/charts.dart';

class AssetLookupSheet extends StatefulWidget {
  final String initialQuery;
  final ValueChanged<Map<String, dynamic>> onSelect;
  const AssetLookupSheet(
      {super.key, this.initialQuery = '', required this.onSelect});
  @override
  State<AssetLookupSheet> createState() => _AssetLookupSheetState();
}

class _AssetLookupSheetState extends State<AssetLookupSheet> {
  final _ctl = TextEditingController();
  Timer? _deb;
  List<Map<String, dynamic>> _rows = const [];
  // key: conId as string when available, else symbol
  final Map<String, List<double>> _sparks = {};
  // tiny semaphore to avoid IBKR historical pacing
  static int _inflight = 0;
  static const int _maxInflight = 3;

  @override
  void initState() {
    super.initState();
    _ctl.text = widget.initialQuery;
    _searchNow();
    _ctl.addListener(_debounced);
  }

  @override
  void dispose() {
    _deb?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _debounced() {
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 350), _searchNow);
  }

  Future<void> _searchNow() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) {
      setState(() => _rows = []);
      return;
    }
    try {
      final list = await Api.ibkrSearch(q);
      final cast = list
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() => _rows = cast.take(30).toList());
      // best-effort sparks
      for (final r in cast.take(12)) {
        // keep the cap (good!)
        final sym = (r['symbol'] ?? '').toString();
        final cid = (r['conId'] as num?)?.toInt();
        final sec = (r['secType'] ?? '').toString();
        final key = cid != null ? cid.toString() : sym;
        if (sym.isEmpty || _sparks.containsKey(key)) continue;
        _loadSpark(symbol: sym, conId: cid, secType: sec);
      }
    } catch (_) {}
  }

  Future<void> _loadSpark({String? symbol, int? conId, String? secType}) async {
    try {
      // pick 'what' + useRTH based on secType (FX/indices => MIDPOINT)
      final st = (secType ?? '').toUpperCase();
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH'); // RTH meaningless for FX

      // light throttle (<=3 concurrent)
      while (_inflight >= _maxInflight) {
        await Future.delayed(const Duration(milliseconds: 180));
      }
      _inflight++;
      final h = await Api.ibkrHistory(
        symbol: symbol,
        conId: conId,
        duration: '1 D',
        barSize: '5 mins',
        what: what,
        useRTH: useRth,
      );
      final bars = (h['bars'] as List?) ?? const [];
      final vals = bars.map((b) => (b['c'] as num).toDouble()).toList();
      if (vals.isNotEmpty) {
        final mn = vals.reduce((a, b) => a < b ? a : b),
            mx = vals.reduce((a, b) => a > b ? a : b);
        final norm = mx - mn < 1e-9
            ? List.filled(vals.length, 0.5)
            : vals.map((v) => (v - mn) / (mx - mn)).toList();
        final key = conId != null ? conId.toString() : (symbol ?? '');
        if (key.isNotEmpty) {
          setState(() => _sparks[key] = norm);
        }
      }
    } catch (_) {
    } finally {
      _inflight = (_inflight - 1).clamp(0, _maxInflight);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, ctrl) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(children: [
              const Text('Search Assets',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _ctl,
              decoration: const InputDecoration(
                  hintText: 'e.g. AAPL, MSFT, ES, EURUSD'),
              onSubmitted: (_) => _searchNow(),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                controller: ctrl,
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Name')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('Exch')),
                    DataColumn(label: Text('CCY')),
                    DataColumn(label: Text('Spark')),
                    DataColumn(label: Text('Trade')),
                  ],
                  rows: _rows.map((r) {
                    final sym = (r['symbol'] ?? '').toString();
                    final cid = (r['conId'] as num?);
                    final key = cid != null ? cid.toString() : sym;
                    final spark = _sparks[key] ?? const [];
                    return DataRow(cells: [
                      DataCell(Text(sym)),
                      DataCell(SizedBox(
                          width: 240,
                          child: Text(
                              ((r['name'] ?? r['description'] ?? '') as String),
                              overflow: TextOverflow.ellipsis))),
                      DataCell(Text((r['secType'] ?? '') as String)),
                      DataCell(
                        Text(((r['exchange'] ?? r['primaryExchange'] ?? '')
                            as String)),
                      ),
                      DataCell(Text((r['currency'] ?? '') as String)),
                      DataCell(SizedBox(
                          width: 120, height: 36, child: sparkLine(spark))),
                      DataCell(FilledButton(
                        onPressed: () => widget.onSelect(r),
                        child: const Text('Open'),
                      )),
                    ]);
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
