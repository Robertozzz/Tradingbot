import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:tradingbot/lib/charts.dart';
import 'package:flutter/services.dart' show rootBundle; // load package assets
// We depend on the ticker *data* from the `tickersearch` package.
// No types are imported from it; we read its packaged JSON at runtime.

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
  bool _fromLocal = false; // indicates rows came from local index
  bool _verifyFailed = false; // verification fell back (IBKR offline?)
  List<Map<String, dynamic>>? _localIndex; // lazy-loaded from package assets
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

  // Load once: try known paths from the `tickersearch` / `ticker_search` packages.
  // We normalize fields into {symbol, name, exchange, currency}.
  Future<void> _ensureLocalIndexLoaded() async {
    if (_localIndex != null) return;
    final candidates = <String>[
      // common package asset paths (try a few, accept the first that works)
      'packages/tickersearch/assets/tickers.json',
      'packages/tickersearch/assets/tickers.min.json',
      // fallback if someone still has ticker_search installed
      'packages/ticker_search/assets/tickers.json',
      'packages/ticker_search/assets/tickers.min.json',
    ];
    for (final path in candidates) {
      try {
        final s = await rootBundle.loadString(path);
        final data = json.decode(s);
        if (data is List) {
          _localIndex = data
              .map<Map<String, dynamic>>((e) {
                final m = (e as Map).map((k, v) => MapEntry(k.toString(), v));
                // try a few common keys across datasets
                final sym =
                    (m['symbol'] ?? m['ticker'] ?? m['code'] ?? '').toString();
                final name =
                    (m['name'] ?? m['company'] ?? m['title'] ?? '').toString();
                final exch = (m['exchange'] ?? m['exch'] ?? '').toString();
                final ccy = (m['currency'] ?? m['ccy'] ?? 'USD').toString();
                return {
                  'symbol': sym,
                  'name': name,
                  'exchange': exch,
                  'currency': ccy,
                  'secType': 'STK',
                };
              })
              .where((m) => (m['symbol'] as String).isNotEmpty)
              .toList();
          return;
        }
      } catch (_) {
        // try next candidate
      }
    }
    _localIndex = <Map<String, dynamic>>[]; // no dataset found, stay graceful
  }

  List<Map<String, dynamic>> _searchLocal(String q, {int limit = 40}) {
    final idx = _localIndex ?? const <Map<String, dynamic>>[];
    if (idx.isEmpty) return const [];
    final tl = q.toLowerCase();
    int score(Map<String, dynamic> m) {
      final sym = (m['symbol'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      var s = 0;
      if (sym.toUpperCase() == q.toUpperCase()) s -= 1000; // exact ticker
      if (sym.toUpperCase().startsWith(q.toUpperCase()))
        s -= 300; // prefix match
      if (name.toLowerCase().contains(tl)) s -= 100; // name contains
      return s;
    }

    final hits = idx.where((m) {
      final sym = (m['symbol'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      return sym.toUpperCase().contains(q.toUpperCase()) ||
          name.toLowerCase().contains(tl);
    }).toList();
    hits.sort((a, b) => score(a).compareTo(score(b)));
    if (hits.length > limit) return hits.sublist(0, limit);
    return hits;
  }

  Future<void> _searchNow() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) {
      setState(() {
        _rows = [];
        _loading = false;
        _maybeIbkrOffline = false;
        _fromLocal = false;
        _verifyFailed = false;
      });
      return;
    }
    try {
      setState(() => _loading = true);
      // 1) LOCAL, instant search via tickersearch data (fast UX)
      await _ensureLocalIndexLoaded();
      final localRows = _searchLocal(q, limit: 60);

      // 2) Ask IBKR to verify these symbols in bulk; keep only tradables.
      List<Map<String, dynamic>> verified = const [];
      bool verifyFailed = false;
      if (localRows.isNotEmpty) {
        try {
          final uniqSyms = {
            for (final r in localRows) (r['symbol'] ?? '').toString()
          }.toList();
          final v = await Api.ibkrVerifySymbols(uniqSyms);
          final ok = <String, Map<String, dynamic>>{};
          for (final m in v) {
            final sym = (m['symbol'] ?? '').toString();
            if (sym.isEmpty) continue;
            ok[sym] = m;
          }
          // merge: copy IBKR contract fields onto local rows
          final merged = <Map<String, dynamic>>[];
          for (final r in localRows) {
            final sym = (r['symbol'] ?? '').toString();
            final v = ok[sym];
            if (v == null) continue; // not tradable on IBKR -> drop
            merged.add({
              ...r,
              ...v, // adds conId/exchange/currency/secType/localSymbol
            });
          }
          verified = merged;
        } catch (_) {
          verifyFailed = true;
        }
      }

      // 3) Also query the server /ibkr/search for query text (name & ticker),
      //    to catch cases local index misses or to enrich odd assets.
      final serverOut = <Map<String, dynamic>>[];
      try {
        final srv = await Api.ibkrSearch(q);
        for (final e in srv) {
          serverOut.add(Map<String, dynamic>.from(e as Map));
        }
      } catch (_) {/* ok, IBKR might be down */}

      // 4) Merge + de-dupe (prefer verified locals, then server results).
      final byConId = <int, Map<String, dynamic>>{};
      final byKey = <String, Map<String, dynamic>>{};
      void absorb(Map<String, dynamic> m, {bool prefer = false}) {
        final cid = (m['conId'] as num?)?.toInt();
        if (cid != null && cid > 0) {
          if (prefer || !byConId.containsKey(cid)) byConId[cid] = m;
          return;
        }
        final key =
            '${(m['symbol'] ?? '').toString()}::${(m['exchange'] ?? m['primaryExchange'] ?? '').toString()}';
        if (prefer || !byKey.containsKey(key)) byKey[key] = m;
      }

      for (final m in verified) {
        absorb(m, prefer: true); // verified first
      }
      for (final m in serverOut) {
        absorb(m, prefer: false); // then server
      }
      final merged = [
        ...byConId.values,
        ...byKey.values,
      ];

      // soft-rank: exact ticker match, then name contains query
      final qLower = q.toLowerCase();
      merged.sort((a, b) {
        int score(Map<String, dynamic> m) {
          final sym = (m['symbol'] ?? '').toString();
          final name = (m['name'] ?? m['description'] ?? '').toString();
          int s = 0;
          if (sym.toUpperCase() == q.toUpperCase()) s -= 1000;
          if (name.toLowerCase().contains(qLower)) s -= 100;
          // prefer entries that have a conId (verified)
          if ((m['conId'] as num?) != null) s -= 20;
          return s;
        }

        return score(a).compareTo(score(b));
      });

      setState(() {
        _rows = merged.take(30).toList();
        _loading = false;
        _maybeIbkrOffline = _rows.isEmpty;
        _fromLocal = true;
        _verifyFailed = verifyFailed;
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
            if (_verifyFailed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: const [
                    Icon(Icons.info_outline, size: 16, color: Colors.amber),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Showing local results (fast) — IBKR verification unavailable right now.',
                        style: TextStyle(color: Colors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            if (!_verifyFailed && _fromLocal)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: const [
                    Icon(Icons.bolt, size: 16, color: Colors.lightBlueAccent),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Results verified with IBKR (tradable).',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            if (_maybeIbkrOffline && !_fromLocal && !_verifyFailed)
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
