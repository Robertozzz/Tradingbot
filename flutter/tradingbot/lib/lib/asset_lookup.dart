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
  bool _loading = false;
  bool _maybeIbkrOffline = false; // shows a friendly hint when no name results

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
      setState(() {
        _rows = [];
        _loading = false;
        _maybeIbkrOffline = false;
      });
      return;
    }
    try {
      setState(() => _loading = true);
      // Build a handful of query variants to improve name search.
      // (The backend is robust, but this helps when connectivity is flaky.)
      final seenVariant = <String>{};
      final variants = <String>[];
      void addVar(String v) {
        if (v.isEmpty) return;
        if (seenVariant.add(v)) variants.add(v);
      }

      addVar(q);
      addVar(q.toUpperCase());
      addVar(q.toLowerCase());
      // compact (strip spaces/punct)
      final compact = q.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
      if (compact.isNotEmpty && compact != q) addVar(compact);
      // tokens (words length >= 3)
      for (final t in q.split(RegExp(r'[^A-Za-z0-9]+'))) {
        if (t.length >= 3) addVar(t);
      }

      // Query a few variants (cap to be gentle with the gateway).
      final out = <Map<String, dynamic>>[];
      for (final v in variants.take(6)) {
        try {
          final list = await Api.ibkrSearch(v);
          for (final e in list) {
            out.add(Map<String, dynamic>.from(e as Map));
          }
        } catch (_) {
          // ignore per-variant errors; we'll still show any other results
        }
      }

      // De-dupe: prefer unique conId; fall back to (symbol, exchange).
      final seenCon = <int>{};
      final seenKey = <String>{};
      final dedup = <Map<String, dynamic>>[];
      for (final m in out) {
        final cid = (m['conId'] as num?)?.toInt();
        if (cid != null) {
          if (seenCon.add(cid)) dedup.add(m);
          continue;
        }
        final key =
            '${(m['symbol'] ?? '').toString()}::${(m['exchange'] ?? m['primaryExchange'] ?? '').toString()}';
        if (seenKey.add(key)) dedup.add(m);
      }

      // Soft-rank: exact ticker match first, then "name contains q".
      final qLower = q.toLowerCase();
      dedup.sort((a, b) {
        int score(Map<String, dynamic> m) {
          final sym = (m['symbol'] ?? '').toString();
          final name = (m['name'] ?? m['description'] ?? '').toString();
          int s = 0;
          if (sym.toUpperCase() == q.toUpperCase()) s -= 1000;
          if (name.toLowerCase().contains(qLower)) s -= 100;
          return s;
        }

        return score(a).compareTo(score(b));
      });

      setState(() {
        _rows = dedup.take(30).toList();
        _loading = false;
        _maybeIbkrOffline = _rows.isEmpty; // likely disconnected -> show hint
      });
      // best-effort sparks
      for (final r in _rows.take(12)) {
        // keep the cap (good!)
        final sym = (r['symbol'] ?? '').toString();
        final cid = (r['conId'] as num?)?.toInt();
        final sec = (r['secType'] ?? '').toString();
        final key = cid != null ? cid.toString() : sym;
        if (sym.isEmpty || _sparks.containsKey(key)) continue;
        _loadSpark(symbol: sym, conId: cid, secType: sec);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        // Don't toggle the offline hint on exceptions; just show snackbar.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lookup failed: $e')),
        );
      }
    }
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
                  hintText:
                      'Search by ticker or name (e.g. AAPL, Microsoft, EURUSD)'),
              onSubmitted: (_) => _searchNow(),
            ),
            if (_maybeIbkrOffline)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: const [
                    Icon(Icons.info_outline, size: 16, color: Colors.amber),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'No matches. If you searched by company name, ensure IBKR is connected. '
                        'Ticker lookups (e.g., TSLA) work even when offline.',
                        style: TextStyle(color: Colors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty && _ctl.text.trim().isNotEmpty
                      ? Center(
                          child: Text('No results for "${_ctl.text.trim()}"'))
                      : SingleChildScrollView(
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
                                        (r['name'] ?? r['description'] ?? '')
                                            .toString(),
                                        overflow: TextOverflow.ellipsis))),
                                DataCell(Text((r['secType'] ?? '').toString())),
                                DataCell(
                                  Text((r['exchange'] ??
                                          r['primaryExchange'] ??
                                          '')
                                      .toString()),
                                ),
                                DataCell(
                                    Text((r['currency'] ?? '').toString())),
                                DataCell(SizedBox(
                                    width: 120,
                                    height: 36,
                                    child: sparkLine(spark))),
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
