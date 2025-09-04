import 'dart:async';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/api.dart';
import 'package:tradingbot/charts.dart';
import 'package:tradingbot/asset_lookup.dart';
import 'package:tradingbot/tradingview_widget.dart';
import 'package:tradingbot/app_events.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  final fMoney = NumberFormat.currency(symbol: '\$');
  // lighter: final fMoney = NumberFormat.compactCurrency(symbol: '\$');
  List<Map<String, dynamic>> _ibkrPos = const [];
  final Map<String, List<double>> _sparks = {}; // symbol -> 0..1 norm spark
  final Map<int, Map<String, num>> _pnl =
      {}; // conId -> {unrealized, realized, daily}
  // cache of pretty names keyed by conId (fallback to symbol key)
  static final Map<String, String> _names = {};
  static final Map<int, num> _lastPxByCid = {};
  static final Map<String, num> _lastPxBySym = {};
  final _searchCtl = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _orderBusSub;
  VoidCallback? _snapListen;
  Timer? _posPoll; // periodic positions refresher

  @override
  void initState() {
    super.initState();
    // Ensure the global event bus is running (bootstrap + SSE).
    OrderEvents.instance.ensureStarted();
    // Fetch pretty names stored on the backend and merge them into the
    // app-lifetime cache so the positions table can render them immediately.
    (() async {
      try {
        final server = await Api.ibkrNames(); // GET /ibkr/names
        server.forEach((k, v) {
          final name = (v ?? '').toString().trim();
          if (name.isEmpty) return;
          // Accept either numeric conId keys or "SYM:XYZ"/"CID:123" style.
          final isNumKey = (k is num) || (int.tryParse(k) != null);
          final key = isNumKey
              ? 'CID:${int.parse(k.toString())}'
              : (k.toString().startsWith('CID:') ||
                      k.toString().startsWith('SYM:')
                  ? k.toString()
                  : 'SYM:${k.toString()}');
          _AssetPanelState._prettyNameCache[key] = name;
        });
        if (mounted) setState(() {}); // repaint any open tables
      } catch (_) {
        // offline or endpoint missing -> no-op (local cache still works)
      }
    })();
    // 1) seed immediately from bootstrap or prior cache
    (() async {
      try {
        final boot = await Api.bootstrap(); // offline-friendly
        final list = (boot['positions'] as List?) ?? const [];
        if (list.isNotEmpty && mounted) {
          setState(() {
            _ibkrPos = list
                .map<Map<String, dynamic>>(
                    (e) => Map<String, dynamic>.from(e as Map))
                .toList();
          });
        } else if (Api.lastPositions != null && mounted) {
          setState(() => _ibkrPos = Api.lastPositions!
              .map<Map<String, dynamic>>(
                  (e) => Map<String, dynamic>.from(e as Map))
              .toList());
        }
      } catch (_) {}
      // then do a live refresh
      _refreshPositions(forceLive: true);
    })();
    // Seed from the current snapshot immediately (instant paint),
    // then keep it in sync via listener.
    _applySnapshot(OrderEvents.instance.snapshotVN.value);
    _snapListen = () {
      _applySnapshot(OrderEvents.instance.snapshotVN.value);
    };
    OrderEvents.instance.snapshotVN.addListener(_snapListen!);
    // When orders stream in (e.g., fills), we *optionally* do targeted refreshes
    // like P&L per-conId. We no longer re-pull the entire positions table here.
    _orderBusSub = OrderEvents.instance.stream.listen((event) {
      final conId = (event['conId'] as num?)?.toInt();
      if (conId != null && !_pnl.containsKey(conId)) {
        _loadPnlSingle(conId);
      }
    }, onError: (_) {});

    // Keep positions fresh even if SSE snapshot doesn't include them
    _posPoll = Timer.periodic(const Duration(seconds: 20), (_) {
      _refreshPositions(); // normal (memoized) fetch; API has 5s memo anyway
    });
  }

  @override
  void dispose() {
    try {
      _orderBusSub?.cancel();
    } catch (_) {}
    if (_snapListen != null) {
      OrderEvents.instance.snapshotVN.removeListener(_snapListen!);
    }
    try {
      _posPoll?.cancel();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _refreshPositions({bool forceLive = false}) async {
    try {
      // On first call we want a guaranteed live hit to paint the table.
      final rows = forceLive
          ? await Api.ibkrPositions() // live fetch (still 5s memo in Api)
          : await Api
              .ibkrPositionsCached(); // fast path with background refresh
      final list = rows
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _ibkrPos = list;
      });
    } catch (_) {}
  }

  void _applySnapshot(Map<String, dynamic> snap) {
    if (!mounted) return;
    // Prefer 'positions' if present in snapshot; otherwise keep current list.
    final pos =
        (snap['positions'] ?? snap['portfolio'] ?? snap['holdings']) as List? ??
            const [];
    final sparks = (snap['sparks'] as Map?) ?? const {};
    final list = pos
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    setState(() {
      if (pos.isNotEmpty) _ibkrPos = list;
      // Merge spark arrays from snapshot (normalized 0..1)
      for (final entry in sparks.entries) {
        final k = entry.key.toString();
        final v = (entry.value as List?)
                ?.map((x) => (x as num).toDouble())
                .toList() ??
            const <double>[];
        _sparks[k] = v;
      }

      // OPTIONAL: if your bootstrap/snapshot carries pretty names, merge them.
      final snapNames = (snap['names'] as Map?) ?? const {};
      for (final entry in snapNames.entries) {
        final rawKey = entry.key;
        final name = (entry.value ?? '').toString();
        if (name.isEmpty) continue;
        if (rawKey is num ||
            (rawKey is String && int.tryParse(rawKey) != null)) {
          _names['CID:${int.parse(rawKey.toString())}'] = name;
        } else {
          _names['SYM:${rawKey.toString()}'] = name;
        }
      }
    });

    // If a symbol lacks a spark in snapshot, backfill one lazily from /ibkr/history.
    for (final m in list) {
      final s = (m['symbol'] ?? '').toString();
      if (s.isEmpty) continue;
      final conId = (m['conId'] as num?)?.toInt();
      final secType = (m['secType'] ?? '').toString();
      final hasSpark = (_sparks[s]?.isNotEmpty ?? false);
      if (!hasSpark) {
        _loadSpark(symbol: s, conId: conId, secType: secType);
      }
    }

    // Enrich names lazily
    for (final m in list) {
      final s = (m['symbol'] ?? '').toString();
      final conId = (m['conId'] as num?)?.toInt();
      if (s.isEmpty) continue;
      if (!_names.containsKey(conId != null ? 'CID:$conId' : 'SYM:$s')) {
        _ensurePrettyName(symbol: s, conId: conId);
      }
      if (conId != null && !_pnl.containsKey(conId)) {
        _loadPnlSingle(conId);
      }
    }
  }

  // add a small throttle like in lookup if you have lots of positions
  static int _sparkInflight = 0;
  static const int _sparkMax = 3;
  // Keep raw ranges so spark axes can show meaningful labels.
  final Map<String, List<double>> _sparkRanges = {}; // symbol -> [min,max]
  // Parallel timestamps for bottom time labels.
  final Map<String, List<DateTime>> _sparkTimes = {}; // symbol -> bars time[]

  // Spark timeframe (applies to Positions table mini charts)
  String _sparkTf = '1D';
  static const Map<String, Map<String, String>> _sparkTfParams = {
    '1D': {'duration': '1 D', 'barSize': '5 mins'},
    '3D': {'duration': '3 D', 'barSize': '15 mins'},
    '1W': {'duration': '1 W', 'barSize': '30 mins'},
    '1M': {'duration': '1 M', 'barSize': '1 day'},
    '3M': {'duration': '3 M', 'barSize': '1 day'},
    '1Y': {'duration': '1 Y', 'barSize': '1 week'},
  };

  DateTime? _parseBarTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) {
      // Heuristic: seconds vs ms
      final ms = raw > 2000000000 ? raw : raw * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (raw is num) {
      final v = raw.toInt();
      final ms = v > 2000000000 ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (raw is String) {
      // Try ISO first; if it lacks timezone, assume UTC.
      final dt = DateTime.tryParse(raw);
      return dt?.toLocal();
    }
    return null;
  }

  Future<void> _loadSpark({String? symbol, int? conId, String? secType}) async {
    try {
      final st = (secType ?? '').toUpperCase();
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH');
      final tf = _sparkTfParams[_sparkTf]!;
      final tfDuration = tf['duration']!;
      final tfBarSize = tf['barSize']!;
      while (_sparkInflight >= _sparkMax) {
        await Future.delayed(const Duration(milliseconds: 180));
      }
      _sparkInflight++;
      final h = await Api.ibkrHistory(
        symbol: symbol,
        conId: conId,
        duration: tfDuration,
        barSize: tfBarSize,
        what: what,
        useRTH: useRth,
      );
      final bars = (h['bars'] as List?) ?? const [];
      final vals = <double>[];
      final times = <DateTime>[];
      for (final b in bars) {
        if (b is Map) {
          final c = (b['c'] as num?)?.toDouble();
          if (c != null) {
            vals.add(c);
            final t = _parseBarTime(b['t'] ?? b['time'] ?? b['ts']);
            if (t != null) times.add(t);
          }
        }
      }
      if (vals.isNotEmpty) {
        final mn = vals.reduce((a, b) => a < b ? a : b);
        final mx = vals.reduce((a, b) => a > b ? a : b);
        final norm = mx - mn < 1e-9
            ? List.filled(vals.length, 0.5)
            : vals.map((v) => (v - mn) / (mx - mn)).toList();
        if (symbol != null) {
          setState(() {
            _sparks[symbol] = norm.toList();
            _sparkRanges[symbol] = [mn, mx];
            _sparkTimes[symbol] =
                times.length == vals.length ? times : const [];
          });
        }
      }
    } catch (_) {
    } finally {
      // Decrement safely without type churn.
      _sparkInflight = math.max(0, _sparkInflight - 1);
    }
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

  // --- Pretty name enrichment for positions table --------------------------
  static int _nameInflight = 0;
  static const int _nameMax = 3;
  Future<void> _ensurePrettyName({required String symbol, int? conId}) async {
    final key = (conId != null ? 'CID:$conId' : 'SYM:$symbol');
    if (symbol.isEmpty || _names.containsKey(key)) return;
    try {
      while (_nameInflight >= _nameMax) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
      _nameInflight++;
      final list = await Api.ibkrSearch(symbol);
      String? name;
      if (conId != null) {
        for (final e in list) {
          final m = Map<String, dynamic>.from(e as Map);
          final cid = (m['conId'] as num?)?.toInt();
          if (cid != null && cid == conId) {
            name = (m['name'] ?? m['description'] ?? '').toString();
            break;
          }
        }
      }
      name ??= (() {
        if (list.isEmpty) return null;
        final m = Map<String, dynamic>.from(list.first as Map);
        return (m['name'] ?? m['description'] ?? '').toString();
      })();
      if (name != null && name.trim().isNotEmpty && mounted) {
        setState(() => _names[key] = name!.trim());
      }
    } catch (_) {
      // ignore; leave blank
    } finally {
      _nameInflight = math.max(0, _nameInflight - 1);
    }
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
              Row(
                children: [
                  const Text('IBKR Positions',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '1D', label: Text('1d')),
                      ButtonSegment(value: '3D', label: Text('3d')),
                      ButtonSegment(value: '1W', label: Text('1w')),
                      ButtonSegment(value: '1M', label: Text('1m')),
                      ButtonSegment(value: '3M', label: Text('3m')),
                      ButtonSegment(value: '1Y', label: Text('1y')),
                    ],
                    selected: {_sparkTf},
                    onSelectionChanged: (s) {
                      setState(() {
                        _sparkTf = s.first;
                        // visually indicate refresh; avoid stale-looking sparks
                        _sparks.clear();
                        _sparkRanges.clear();
                        _sparkTimes.clear();
                      });
                      // Re-load sparks for visible positions under new TF.
                      for (final m in _ibkrPos) {
                        final s = (m['symbol'] ?? '').toString();
                        if (s.isEmpty) continue;
                        _loadSpark(
                          symbol: s,
                          conId: (m['conId'] as num?)?.toInt(),
                          secType: (m['secType'] ?? '').toString(),
                        );
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Account')),
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Name')),
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
                    final nameKey = conId != null ? 'CID:$conId' : 'SYM:$sym';
                    final pretty = _names[nameKey] ??
                        _AssetPanelState._prettyNameCache[nameKey] ??
                        '';

                    return DataRow(cells: [
                      DataCell(Text(m['account']?.toString() ?? '')),
                      DataCell(InkWell(
                        onTap: () => _showAssetPanel(
                          sym,
                          {
                            ...m,
                            if (pretty.isNotEmpty) 'prettyName': pretty,
                          },
                        ),
                        child: Row(children: [
                          Text(sym),
                          const SizedBox(width: 6),
                          const Icon(Icons.open_in_new, size: 14),
                        ]),
                      )),
                      DataCell(SizedBox(
                        width: 260,
                        child: Text(
                          pretty.isEmpty ? '—' : pretty,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                      DataCell(Text(m['secType']?.toString() ?? '')),
                      DataCell(FutureBuilder<Map<String, dynamic>>(
                        future: Api.ibkrQuote(
                          conId: conId,
                          symbol: sym,
                          secType: (m['secType'] ?? '').toString(),
                          exchange:
                              ((m['primaryExchange'] ?? m['exchange']) ?? '')
                                  .toString(),
                          currency: (m['currency'] ?? '').toString(),
                        ),
                        builder: (_, snap) {
                          final q = snap.data;
                          final pxNet = (q?['last'] ?? q?['close']) as num?;
                          // prefer cached value if this poll hasn’t returned yet
                          final cached = conId != null
                              ? _lastPxByCid[conId]
                              : _lastPxBySym[sym];
                          final px = pxNet ?? cached;
                          if (pxNet != null) {
                            if (conId != null) _lastPxByCid[conId] = pxNet;
                            _lastPxBySym[sym] = pxNet;
                          }
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
                      DataCell(Text(
                        (m['primaryExchange'] ?? m['exchange'] ?? '')
                            .toString(),
                      )),
                      DataCell(Builder(builder: (_) {
                        final range = _sparkRanges[sym];
                        final hasRange = range != null && range.length == 2;
                        final yMinLabel =
                            hasRange ? fMoney.format(range[0]) : '0';
                        final yMaxLabel =
                            hasRange ? fMoney.format(range[1]) : '1';
                        return SizedBox(
                          width: 120,
                          height: 36,
                          child: sparkLine(
                            spark,
                            height: 36,
                            leftLabel: (v) {
                              // values are 0..1 normalized → show only endpoints
                              if ((v - 0.0).abs() < 1e-6) return yMinLabel;
                              if ((v - 1.0).abs() < 1e-6) return yMaxLabel;
                              return '';
                            },
                            bottomLabel: (x) {
                              final ts = _sparkTimes[sym] ?? const [];
                              if (ts.isEmpty) return '';
                              // Show a few evenly spaced labels: start, mid, end.
                              if ((x - x.roundToDouble()).abs() > 0.001) {
                                return '';
                              }
                              final i = x.round();
                              final n = ts.length;
                              if (i < 0 || i >= n) return '';
                              if (i == 0 || i == n - 1 || i == n ~/ 2) {
                                return DateFormat('HH:mm').format(ts[i]);
                              }
                              return '';
                            },
                          ),
                        );
                      })),
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

  void _showAssetPanel(String symbol, Map<String, dynamic> pos) {
    if (!mounted) return;
    // STATIC modal dialog (no draggable sheet)
    // Share a ValueNotifier so the dialog can resize when "Advanced" toggles.
    final advVN = ValueNotifier<bool>(false);
    showGeneralDialog(
      context: context,
      barrierDismissible: true, // tap outside to close
      barrierLabel: 'Close',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) {
        return Center(
          child: _AssetPanelDialog(
            advancedVN: advVN,
            child: _AssetPanel(
              symbol: symbol,
              pos: pos,
              quote: null,
              hist: null,
              advancedVN: advVN,
            ),
          ),
        );
      },
      transitionBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
              scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
              child: child),
        );
      },
    );
  }
}

class _AssetPanel extends StatefulWidget {
  final String symbol;
  final Map<String, dynamic> pos;
  final Map<String, dynamic>? quote;
  final Map<String, dynamic>? hist;
  final ValueNotifier<bool> advancedVN;
  // advancedVN drives both dialog size and panel contents (TV vs line chart)
  const _AssetPanel(
      {required this.symbol,
      required this.pos,
      this.quote,
      this.hist,
      required this.advancedVN});
  @override
  State<_AssetPanel> createState() => _AssetPanelState();
}

class _AssetPanelState extends State<_AssetPanel> {
  String side = 'BUY';
  String type = 'MKT';
  String tif = 'DAY'; // DAY | GTC | IOC
  double qty = 1;
  double? lmt;
  // Live L1
  double? _bid, _ask, _last;
  Timer? _quoteTimer;
  String? _assetName; // pretty name for header

  // Sizing: by quantity OR by USD notional (auto size)
  String _sizing = 'QTY'; // 'QTY' | 'USD'
  double _usd = 1000;

  // Bracket / OCO
  bool _useBracket = false;
  bool _tpSlAsPct = false; // false => absolute $, true => %
  double? _tpAbs, _slAbs;
  double _tpPct = 1.0, _slPct = 0.8;
  //bool advanced =
  //   false; // NEW: replaces "TradingView" switch & controls size/TV

  // NEW: live data
  List<Map<String, dynamic>> _orders = const [];
  Map<String, num>? _pnl;
  Map<String, dynamic>? _quoteLive; // local quote copy
  Map<String, dynamic>? _histLive; // local history copy
  bool _busy = false;
  // Lock parent scroll when hovering over TradingView so wheel/drag go to TV.
  bool _lockParentScroll = false;
  bool get advanced => widget.advancedVN.value;
  VoidCallback? _advListener;
  StreamSubscription<Map<String, dynamic>>? _orderBusSub;
  Timer? _ordersPoll;
  DateTime? _parseBarTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) {
      final ms = raw > 2000000000 ? raw : raw * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (raw is num) {
      final v = raw.toInt();
      final ms = v > 2000000000 ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    }
    if (raw is String) {
      final dt = DateTime.tryParse(raw);
      return dt?.toLocal();
    }
    return null;
  }

  // --- Chart timeframe for the trade panel ---
  String _tf = '1D';
  static const Map<String, Map<String, String>> _tfParams = {
    '1D': {'duration': '1 D', 'barSize': '5 mins'},
    '5D': {'duration': '5 D', 'barSize': '30 mins'},
    '1M': {'duration': '1 M', 'barSize': '1 day'},
    '3M': {'duration': '3 M', 'barSize': '1 day'},
    '1Y': {'duration': '1 Y', 'barSize': '1 week'},
  };

// === Global (in-memory, app-lifetime) caches ===
  static final Map<int, Map<String, dynamic>> _lastQuoteByCid = {};
  static final Map<String, Map<String, dynamic>> _lastQuoteBySym = {};
  static final Map<String, String> _prettyNameCache =
      {}; // key: 'CID:123' or 'SYM:AAPL'

// Robust number extractor (handles num or string "123.45")
  double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      return double.tryParse(v.replaceAll(RegExp(r'[^\d\.\-]'), ''));
    }
    return null;
  }

  void _applyQuote(Map<String, dynamic>? q) {
    if (q == null) return;
    setState(() {
      _bid = _num(q['bid'] ?? q['bidPrice'] ?? q['BID']);
      _ask = _num(q['ask'] ?? q['askPrice'] ?? q['ASK']);
      _last = _num(q['last'] ?? q['lastPrice'] ?? q['close'] ?? q['MARK']);
    });
  }

  void _rememberQuote(int? conId, String sym, Map<String, dynamic> q) {
    if (conId != null) {
      _lastQuoteByCid[conId] = q;
    } else {
      _lastQuoteBySym[sym] = q;
    }
  }

  void _rememberPrettyName(String name) {
    if (name.trim().isEmpty) return;
    final cid = (widget.pos['conId'] as num?)?.toInt();
    final key = cid != null ? 'CID:$cid' : 'SYM:${widget.symbol}';
    final val = name.trim();
    _prettyNameCache[key] = val; // immediate UX
    // Fire-and-forget server save so names sync across devices.
    () async {
      try {
        await Api.ibkrSetNames({key: val}); // POST /ibkr/names
      } catch (_) {/* ignore */}
    }();
  }

  bool _isTerminal(String? s) {
    final st = (s ?? '').toUpperCase();
    return st == 'FILLED' ||
        st == 'CANCELLED' ||
        st == 'INACTIVE' ||
        st.startsWith('APICANCEL');
  }

  void _ensureOrdersPoll() {
    final hasActive = _orders.any((o) => !_isTerminal(o['status']?.toString()));
    if (hasActive && _ordersPoll == null) {
      _ordersPoll = Timer.periodic(
          const Duration(seconds: 3), (_) => _refreshLive(silent: true));
    } else if (!hasActive && _ordersPoll != null) {
      _ordersPoll!.cancel();
      _ordersPoll = null;
    }
  }

  // --- Account / Buying Power state ---
  Map<String, dynamic>? _acctSummary; // raw /ibkr/accounts (first account)
  DateTime? _acctUpdatedAt;
  bool _acctExpanded = false; // collapse advanced KPIs when space is tight
  // Split: cash-only vs margin buying power (USD)
  double? _bpCashUsd; // AvailableFunds / FullAvailableFunds
  double? _bpMarginUsd; // BuyingPower (fall back to cash if missing)
  bool _cashOnlyBP = true; // UI toggle: default to cash-only

  // Parse "12345.67" or "12345.67 USD" → 12345.67
  double? _numOrNull(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    final n = double.tryParse(s.replaceAll(RegExp(r'[^0-9\.\-]'), ''));
    return (n != null && n.isFinite) ? n : null;
  }

  Future<void> _loadAccount() async {
    try {
      final m = await Api.ibkrAccounts();
      if (m.isNotEmpty) {
        final first = m.values.first as Map<String, dynamic>;
        // Cash-only proxy
        final cash = _numOrNull(first['AvailableFunds']) ??
            _numOrNull(first['FullAvailableFunds']);
        // Margin BP (IBKR-style)
        final marg = _numOrNull(first['BuyingPower']) ?? cash;
        setState(() {
          _acctSummary = first;
          _bpCashUsd = cash;
          _bpMarginUsd = marg;
          _acctUpdatedAt = DateTime.now();
        });
      }
    } catch (_) {/* ignore */}
  }

  // For now assume STK 1x notional; refine for FUT/FX later if needed.
  int _maxQtyFor(double px) {
    final bp = _activeBp();
    if (bp == null || bp <= 0 || px <= 0) return 0;
    final q = (bp / px).floor();
    return q.clamp(0, 1 << 30);
  }

  double? _activeBp() => _cashOnlyBP ? _bpCashUsd : _bpMarginUsd;
  double? _maxUsd() => _activeBp();

  double? get _mid {
    if (_bid != null && _ask != null) return (_bid! + _ask!) / 2.0;
    // fall back to last when NBBO is unavailable
    return _last;
  }

  double? _entryPx(String action) {
    // prefer touch (ask for BUY, bid for SELL), fall back to last
    if (action == 'BUY') return _ask ?? _last ?? _mid;
    return _bid ?? _last ?? _mid;
  }

  int _sizedQty(String action) {
    if (_sizing == 'QTY') return qty.isFinite ? qty.round() : 0;
    final px = _entryPx(action);
    if (px == null || px <= 0) return 0;
    final q = (_usd / px);
    // STK often integer; if you want fractional, remove round()
    return q.isFinite ? q.round().clamp(1, 1 << 31) : 0;
  }

  @override
  void initState() {
    super.initState();
    // seed with passed-in data so panel renders instantly
    _quoteLive = widget.quote;
    _histLive = widget.hist;
    // <-- also seed L1 so pills/notional work before the first poll tick
    if (_quoteLive != null) _applyQuote(_quoteLive);

    // 1) Seed pretty name from any cache/snapshot first
    final cid = (widget.pos['conId'] as num?)?.toInt();
    final nameKey = cid != null ? 'CID:$cid' : 'SYM:${widget.symbol}';
    final snapNames =
        (OrderEvents.instance.snapshotVN.value['names'] as Map?) ?? const {};
    final snapName = snapNames[cid?.toString()] ?? snapNames[widget.symbol];
    final cachedName = _prettyNameCache[nameKey];
    final seeded = (widget.pos['prettyName'] as String?);
    if (seeded != null && seeded.isNotEmpty) {
      _assetName = seeded;
    } else if (cachedName != null && cachedName.isNotEmpty) {
      _assetName = cachedName;
    } else if (snapName is String && snapName.isNotEmpty) {
      _assetName = snapName;
      _rememberPrettyName(snapName);
    } else {
      _loadPrettyName(); // falls back to search once, then caches
    }

    // 2) Seed quotes from cache so Bid/Mid/Ask show immediately
    final cachedQ =
        cid != null ? _lastQuoteByCid[cid] : _lastQuoteBySym[widget.symbol];
    if (cachedQ != null) _applyQuote(cachedQ);
    _refreshLive(silent: true);
    // If history wasn’t provided, fetch it right away so the chart appears quickly.
    if (_histLive == null) {
      _reloadQuoteHist();
    }
    _loadAccount(); // <-- fetch account summary / buying power
    // start light quote poller for L1
    _quoteTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final int? conId = ((widget.pos['conId'] as num?) ??
                (_quoteLive?['conId'] as num?) ??
                (_histLive?['contract']?['conId'] as num?))
            ?.toInt();
        final q = await Api.ibkrQuote(
          conId: conId,
          symbol: widget.symbol,
          secType: _bestSecType(),
          exchange: _bestExchange() ?? '',
          currency: _bestCurrency() ?? '',
        );
        if (!mounted) return;
        setState(() => _quoteLive = q);
        _applyQuote(q);
        _rememberQuote(conId, widget.symbol, q);
      } catch (_) {}
    });
    // No listener needed here; dialog listens to VN for sizing.
    // BUT the PANEL also must rebuild so the Switch, height, and TV swap update.
    _advListener = () {
      if (mounted) setState(() {});
    };
    widget.advancedVN.addListener(_advListener!);

    // Listen to the global order bus and merge updates for this instrument.
    _orderBusSub = OrderEvents.instance.stream.listen((m) {
      if (!mounted) return;
      final int? mCid = (m['conId'] as num?)?.toInt();
      final int? panelCid = ((widget.pos['conId'] as num?) ??
              (_quoteLive?['conId'] as num?) ??
              (_histLive?['contract']?['conId'] as num?))
          ?.toInt();
      final sameInstrument = panelCid != null
          ? (mCid == panelCid)
          : ((m['symbol']?.toString() ?? '').toUpperCase() ==
              widget.symbol.toUpperCase());
      if (!sameInstrument) return;
      setState(() {
        final oid = (m['orderId'] as num?)?.toInt();
        final i = _orders.indexWhere(
            (o) => (o['orderId'] as num?)?.toInt() == oid && oid != null);
        if (i >= 0) {
          _orders[i] = {..._orders[i], ...m};
        } else {
          _orders = [..._orders, m];
        }
      });
      _ensureOrdersPoll();
      final st = (m['status'] ?? m['parentStatus'] ?? '').toString();
      if (st.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Order ${m['orderId']}: $st')));
      }
    }, onError: (_) {});
  }

  Future<void> _loadPrettyName() async {
    try {
      // Prefer matching by conId if available, else by symbol
      final int? conId = ((widget.pos['conId'] as num?) ??
              (_quoteLive?['conId'] as num?) ??
              (_histLive?['contract']?['conId'] as num?))
          ?.toInt();
      final list = await Api.ibkrSearch(widget.symbol);
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        final cid = (m['conId'] as num?)?.toInt();
        if (conId != null && cid != null && cid == conId) {
          if (mounted) {
            setState(() => _assetName = (m['name'] ?? '').toString());
          }
          return;
        }
      }
      if (list.isNotEmpty && mounted) {
        final m = Map<String, dynamic>.from(list.first as Map);
        setState(() => _assetName = (m['name'] ?? '').toString());
      }
    } catch (_) {/* ignore */}
  }

  @override
  void dispose() {
    if (_advListener != null) widget.advancedVN.removeListener(_advListener!);
    _quoteTimer?.cancel();
    try {
      _orderBusSub?.cancel();
    } catch (_) {}
    try {
      _ordersPoll?.cancel();
    } catch (_) {}
    super.dispose();
  }

  // --- Helpers to derive the best secType/exchange/currency for API calls ---
  String _bestSecType() {
    final v = (widget.pos['secType'] ??
            widget.quote?['secType'] ??
            widget.hist?['contract']?['secType'] ??
            '')
        .toString();
    return v.isEmpty ? '' : v.toUpperCase();
  }

  String? _bestExchange() {
    final v = (widget.pos['primaryExchange'] ??
            widget.pos['exchange'] ??
            widget.quote?['primaryExchange'] ??
            widget.quote?['exchange'] ??
            widget.hist?['contract']?['primaryExchange'] ??
            widget.hist?['contract']?['exchange'])
        ?.toString();
    return (v == null || v.isEmpty) ? null : v;
  }

  String? _bestCurrency() {
    final v = (widget.pos['currency'] ??
            widget.quote?['currency'] ??
            widget.hist?['contract']?['currency'])
        ?.toString();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _reloadQuoteHist() async {
    final int? conId = ((_quoteLive?['conId'] as num?) ??
            (_histLive?['contract']?['conId'] as num?) ??
            (widget.quote?['conId'] as num?) ??
            (widget.hist?['contract']?['conId'] as num?) ??
            (widget.pos['conId'] as num?))
        ?.toInt();
    try {
      final st = _bestSecType();
      final exch = _bestExchange();
      final ccy = _bestCurrency();
      final q = await Api.ibkrQuote(
        conId: conId,
        symbol: widget.symbol,
        secType: st,
        exchange: exch ?? '',
        currency: ccy ?? '',
      );
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH');
      final p = _tfParams[_tf]!;
      final h = await Api.ibkrHistory(
        conId: conId,
        symbol: widget.symbol,
        duration: p['duration']!,
        barSize: p['barSize']!,
        what: what,
        useRTH: useRth,
        secType: st,
        exchange: exch ?? '',
        currency: ccy ?? '',
      );
      if (!mounted) return;
      setState(() {
        _quoteLive = q;
        _histLive = h;
      });
      _applyQuote(q);
      _rememberQuote(conId, widget.symbol, q);
    } catch (_) {}
  }

  Future<void> _refreshLive({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _busy = true);
    try {
      // Force the whole chain to int?
      final int? conId = ((widget.pos['conId'] as num?) ??
              (widget.quote?['contract']?['conId'] as num?) ??
              (widget.hist?['contract']?['conId'] as num?))
          ?.toInt();

      // Open orders (filter by conId if possible, else by symbol)
      List<Map<String, dynamic>> filtered = const [];
      try {
        final oo = await Api.ibkrOpenOrders();
        filtered = oo
            .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map))
            .where((o) {
          final oc = (o['conId'] as num?)?.toInt();
          if (conId != null && oc != null) return oc == conId;
          return (o['symbol']?.toString() ?? '').toUpperCase() ==
              widget.symbol.toUpperCase();
        }).toList();
      } catch (_) {
        // IBKR offline or endpoint error → show none instead of crashing
        filtered = const [];
      }

      Map<String, num>? pnl;
      if (conId != null) {
        try {
          final p = await Api.ibkrPnlSingle(conId); // may throw when IBKR down
          pnl = {
            'unrealized': (p['unrealized'] as num?) ?? 0,
            'realized': (p['realized'] as num?) ?? 0,
            'daily': (p['daily'] as num?) ?? 0,
          };
        } catch (_) {
          pnl = null; // hide P&L chips if unavailable
        }
      }

      if (!mounted) return;
      setState(() {
        _orders = filtered;
        _pnl = pnl;
      });
      _ensureOrdersPoll();
    } finally {
      if (mounted && !silent) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _pill(String label, double? v, {bool money = false, Color? tone}) {
    final txt = (v == null || !v.isFinite)
        ? '—'
        : (money
            ? NumberFormat.currency(symbol: '\$').format(v)
            : NumberFormat('0.#####').format(v));
    return Chip(
      label: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label '),
        Text(txt, style: TextStyle(fontWeight: FontWeight.w700, color: tone)),
      ]),
    );
  }

  Widget _usdField({required ValueChanged<double> onChanged}) => SizedBox(
        width: 130,
        child: TextField(
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: 'USD'),
          onChanged: (t) => onChanged(double.tryParse(t) ?? _usd),
        ),
      );
  Widget _tiny(String label, VoidCallback onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            minimumSize: const Size(0, 0)),
        child: Text(label),
      );

  Widget _statusCell(dynamic v) {
    final s = (v ?? '').toString();
    final up = s.toUpperCase();
    final isPending = up.startsWith('PENDING');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isPending)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (isPending) const SizedBox(width: 6),
        Text(s),
      ],
    );
  }

  // ---------- Account Summary helpers ----------
  final NumberFormat _moneyFmt = NumberFormat.currency(symbol: '\$');
  String _usdFmt(num? v) => _moneyFmt.format((v ?? 0).toDouble());
  double? _acctNum(String key) => _numOrNull(_acctSummary?[key]);
  Color _bpColor(double r) {
    // thresholds: >=75% of NetLiq good, 40–75% ok, else warn
    if (r >= 0.75) return const Color(0xFF4CC38A); // green
    if (r >= 0.40) return const Color(0xFFFFC53D); // amber
    return const Color(0xFFEF4444); // red
  }

  Widget _metricTile(
    String label,
    String value, {
    String? help,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 220),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        border: Border.all(color: const Color(0xFF22314E)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70)),
              if (help != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                    message: help,
                    child: const Icon(Icons.info_outline,
                        size: 14, color: Colors.white54)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _bpTile({
    required String label,
    required double? amount,
    required bool active,
    double? maxAgainst, // usually NetLiq
  }) {
    final ratio = (amount != null && maxAgainst != null && maxAgainst > 0)
        ? (amount / maxAgainst).clamp(0.0, 1.0)
        : null;
    final Color barColor =
        ratio == null ? const Color(0xFF334366) : _bpColor(ratio);
    return Container(
      constraints: const BoxConstraints(minWidth: 260),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1A31),
        border: Border.all(color: const Color(0xFF22314E)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child:
                    Text(label, style: const TextStyle(color: Colors.white70)),
              ),
              if (active)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F4436),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('ACTIVE',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(_usdFmt(amount),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (ratio != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
                backgroundColor: const Color(0xFF1B2A4A),
              ),
            ),
            const SizedBox(height: 4),
            Text('vs NetLiq',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ] else
            const Text('—',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          const Text('Used for order sizing (toggle above)',
              style: TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _quoteLive ?? widget.quote;
    final h = _histLive ?? widget.hist;
    final bars = (h?['bars'] as List?) ?? const [];
    // build line safely + parallel times
    final List<FlSpot> spots = () {
      double i = 0;
      final out = <FlSpot>[];
      for (final b in bars) {
        final c = (b is Map ? b['c'] as num? : null)?.toDouble();
        if (c != null) out.add(FlSpot(i++, c));
      }
      return out;
    }();
    final times = <DateTime>[];
    for (final b in bars) {
      if (b is Map) {
        final t = _parseBarTime(b['t'] ?? b['time'] ?? b['ts']);
        if (t != null) times.add(t);
      }
    }
    final double? minYv = spots.isEmpty
        ? null
        : spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final double? maxYv = spots.isEmpty
        ? null
        : spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final avg = (widget.pos['avgCost'] as num?)?.toDouble();
    final heldQty = (widget.pos['position'] as num?)?.toDouble() ?? 0;
    final last = (q?['last'] ?? q?['close']) as num?;
    // Two-column responsive layout: on wide screens use Row with two Expanded
    // columns; on narrow screens fall back to a single scrollable column.
    final leftTop = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _assetName == null || _assetName!.isEmpty
                  ? widget.symbol
                  : '${widget.symbol} — $_assetName',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const Spacer(),
            const Text('Advanced'),
            const SizedBox(width: 8),
            Switch(
              value: advanced,
              onChanged: (v) => widget.advancedVN.value = v,
            ),
            IconButton(
              tooltip: 'Refresh data',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                setState(() => _busy = true);
                await Future.wait([_reloadQuoteHist(), _refreshLive()]);
                if (mounted) setState(() => _busy = false);
              },
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('CLOSE'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _pill('Bid', _bid),
          _pill('Mid', _mid),
          _pill('Ask', _ask),
          _pill('Last', _last),
          const SizedBox(width: 12),
          Builder(builder: (_) {
            final px = _entryPx(side);
            final qn = _sizedQty(side);
            final notional = (px != null && qn > 0) ? px * qn : null;
            return _pill('Est. Notional', notional,
                money: true, tone: Colors.amber);
          }),
        ]),
        if (last != null || heldQty != 0 || _pnl != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text(
              last == null
                  ? '—'
                  : NumberFormat.currency(symbol: '\$').format(last),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
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
        ],

        const SizedBox(height: 8),
        // ---- panel timeframe selector ----
        Row(
          children: [
            const Text('Timeframe'),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '1D', label: Text('1d')),
                ButtonSegment(value: '5D', label: Text('5d')),
                ButtonSegment(value: '1M', label: Text('1m')),
                ButtonSegment(value: '3M', label: Text('3m')),
                ButtonSegment(value: '1Y', label: Text('1y')),
              ],
              selected: {_tf},
              onSelectionChanged: (s) {
                setState(() => _tf = s.first);
                _reloadQuoteHist();
              },
            ),
            const Spacer(),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: advanced ? _expandedChartHeight(context) : 260,
          decoration: BoxDecoration(
            color: const Color(0xFF111A2E),
            border: Border.all(color: const Color(0xFF22314E)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: advanced
              ? MouseRegion(
                  onEnter: (_) {
                    if (!_lockParentScroll) {
                      setState(() => _lockParentScroll = true);
                    }
                  },
                  onExit: (_) {
                    if (_lockParentScroll) {
                      setState(() => _lockParentScroll = false);
                    }
                  },
                  child: Center(
                    child: TradingViewWidget(
                      symbol: _tvSymbol(widget.symbol, widget.pos),
                    ),
                  ),
                )
              : (spots.length < 2
                  ? const Center(child: Text('No chart data'))
                  : lineChart(
                      spots,
                      height: 260,
                      showGrid: true,
                      drawVerticalGrid: false,
                      minY: minYv,
                      maxY: maxYv,
                      leftLabel: (v) {
                        if (minYv == null || maxYv == null) return '';
                        const eps = 1e-6;
                        if ((v - minYv).abs() < eps) {
                          return NumberFormat.currency(symbol: '\$')
                              .format(minYv);
                        }
                        if ((v - maxYv).abs() < eps) {
                          return NumberFormat.currency(symbol: '\$')
                              .format(maxYv);
                        }
                        return '';
                      },
                      bottomLabel: (x) {
                        if (times.isEmpty) return '';
                        if ((x - x.roundToDouble()).abs() > 0.001) return '';
                        final i = x.round();
                        final n = times.length;
                        if (i < 0 || i >= n) return '';
                        if (i == 0 || i == n - 1 || i == n ~/ 2) {
                          final span = times.last.difference(times.first);
                          final fmt = span.inDays >= 1
                              ? DateFormat('MMM d')
                              : DateFormat('HH:mm');
                          return fmt.format(times[i]);
                        }
                        return '';
                      },
                    )),
        ),
        const SizedBox(height: 12),
        // --- Open Orders (moved under the graph) ---
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
                    onPressed: _refreshLive, icon: const Icon(Icons.refresh)),
              ]),
              const SizedBox(height: 6),
              _orders.isEmpty
                  ? const Text('None')
                  : SizedBox(
                      width: double.infinity,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columnSpacing: 12,
                          horizontalMargin: 12,
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
                            DataColumn(label: Text('Modify')),
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
                                    DataCell(_statusCell(o['status'])),
                                    DataCell(Text('${o['filled'] ?? 0}')),
                                    DataCell(Text('${o['remaining'] ?? 0}')),
                                    DataCell(_modifyButton(o)),
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
                    ),
            ],
          ),
        ),
      ],
    );

    final rightControls = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          _chip('Sizing',
              trailing: _seg(
                  ['QTY', 'USD'], _sizing, (v) => setState(() => _sizing = v))),
          if (_sizing == 'QTY')
            _chip('Qty', trailing: _qtyField())
          else
            _chip('Notional',
                trailing:
                    _usdField(onChanged: (v) => setState(() => _usd = v))),
          _chip('BP Mode',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Cash only'),
                const SizedBox(width: 6),
                Switch(
                  value: _cashOnlyBP,
                  onChanged: (v) => setState(() {
                    _cashOnlyBP = v;
                    // Make the toggle visibly affect sizing immediately:
                    final bp = _activeBp();
                    if (_sizing == 'USD' && bp != null) {
                      // Clamp USD notional to the selected BP
                      if (_usd > bp) _usd = bp;
                    } else if (_sizing == 'QTY') {
                      final px = _entryPx(side);
                      if (px != null && px > 0) {
                        qty = qty.clamp(1, _maxQtyFor(px).toDouble());
                      }
                    }
                  }),
                ),
              ])),
          _chip('Type',
              trailing: _seg(['MKT', 'LMT'], type, (v) {
                setState(() {
                  type = v;
                  // when switching to LMT, auto-populate limit from touch
                  if (type == 'LMT' && (lmt == null || lmt!.isNaN)) {
                    final px = _entryPx(side);
                    if (px != null && px.isFinite) lmt = px;
                  }
                });
              })),
          if (type == 'LMT')
            _chip('Limit',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _lmtField(),
                  const SizedBox(width: 6),
                  _tiny('Bid', () => setState(() => lmt = _bid ?? _last)),
                  const SizedBox(width: 4),
                  _tiny('Mid', () => setState(() => lmt = _mid ?? _last)),
                  const SizedBox(width: 4),
                  _tiny('Ask', () => setState(() => lmt = _ask ?? _last)),
                  const SizedBox(width: 4),
                  _tiny('Last', () => setState(() => lmt = _last)),
                ])),
          _chip('TIF',
              trailing: _seg(
                  ['DAY', 'GTC', 'IOC'], tif, (v) => setState(() => tif = v))),
          if (_activeBp() != null && (_entryPx(side) ?? 0) > 0)
            _chip('Max Size', trailing: Builder(builder: (_) {
              final px = _entryPx(side)!;
              final qMax = _maxQtyFor(px);
              final usdMax = _maxUsd()!;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                Chip(label: Text('~$qMax @ \$${px.toStringAsFixed(2)}')),
                const SizedBox(width: 6),
                Chip(
                    label: Text('${_cashOnlyBP ? "Cash" : "Margin"} BP '
                        '${NumberFormat.currency(symbol: '\$').format(usdMax)}')),
                const SizedBox(width: 8),
                _tiny('25%', () {
                  setState(() {
                    if (_sizing == 'USD') {
                      _usd = usdMax * 0.25;
                    } else {
                      qty = (qMax * 0.25)
                          .floorToDouble()
                          .clamp(1, qMax.toDouble());
                    }
                  });
                }),
                const SizedBox(width: 4),
                _tiny('50%', () {
                  setState(() {
                    if (_sizing == 'USD') {
                      _usd = usdMax * 0.50;
                    } else {
                      qty = (qMax * 0.50)
                          .floorToDouble()
                          .clamp(1, qMax.toDouble());
                    }
                  });
                }),
                const SizedBox(width: 4),
                _tiny('100%', () {
                  setState(() {
                    if (_sizing == 'USD') {
                      _usd = usdMax;
                    } else {
                      qty = qMax.toDouble();
                    }
                  });
                }),
              ]);
            })),
        ]),
        const SizedBox(height: 12),
        if (_acctSummary != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1A31),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF22314E)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Account Summary',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (_acctUpdatedAt != null)
                      Text(
                        'Updated ${DateFormat('HH:mm:ss').format(_acctUpdatedAt!)}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: _acctExpanded ? 'Hide details' : 'Show details',
                      icon: Icon(_acctExpanded
                          ? Icons.expand_less
                          : Icons.expand_more),
                      onPressed: () =>
                          setState(() => _acctExpanded = !_acctExpanded),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      (_acctSummary!['accountId'] ??
                              _acctSummary!['AccountId'] ??
                              _acctSummary!['acctId'] ??
                              '')
                          .toString(),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(width: 12),
                    Chip(
                      label: Text(
                        (_acctSummary!['Currency'] ??
                                _acctSummary!['currency'] ??
                                'USD')
                            .toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _metricTile(
                      'Net Liquidation',
                      _usdFmt(_acctNum('NetLiquidation')),
                      help: 'Total equity including unrealized P&L.',
                    ),
                    // Show only the selected BP mode to reduce clutter
                    _cashOnlyBP
                        ? _bpTile(
                            label: 'Buying Power — Cash',
                            amount: _bpCashUsd,
                            active: true,
                            maxAgainst: _acctNum('NetLiquidation'),
                          )
                        : _bpTile(
                            label: 'Buying Power — Margin',
                            amount: _bpMarginUsd,
                            active: true,
                            maxAgainst: _acctNum('NetLiquidation'),
                          ),
                    if (_acctExpanded)
                      _metricTile(
                        'Excess Liquidity',
                        _usdFmt(_acctNum('ExcessLiquidity')),
                        help: 'Funds available before risk limits kick in.',
                      ),
                    if (_acctExpanded)
                      _metricTile(
                        'Gross Position Value',
                        _usdFmt(_acctNum('GrossPositionValue')),
                        help: 'Absolute market value of open positions.',
                      ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        // Bracket + Actions
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1A31),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF22314E)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Switch(
                  value: _useBracket,
                  onChanged: (v) => setState(() => _useBracket = v),
                ),
                const SizedBox(width: 6),
                const Text('Attach Bracket (OCO)',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('\$')),
                    ButtonSegment(value: true, label: Text('%')),
                  ],
                  selected: {_tpSlAsPct},
                  onSelectionChanged: (s) =>
                      setState(() => _tpSlAsPct = s.first),
                ),
              ]),
              if (_useBracket)
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _chip(_tpSlAsPct ? 'Take Profit %' : 'Take Profit \$',
                      trailing: SizedBox(
                        width: 120,
                        child: TextField(
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              isDense: true, hintText: 'e.g. 1.0'),
                          onChanged: (t) {
                            final v = double.tryParse(t);
                            setState(() {
                              if (_tpSlAsPct) {
                                _tpPct = v ?? _tpPct;
                              } else {
                                _tpAbs = v;
                              }
                            });
                          },
                        ),
                      )),
                  _chip(_tpSlAsPct ? 'Stop Loss %' : 'Stop Loss \$',
                      trailing: SizedBox(
                        width: 120,
                        child: TextField(
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              isDense: true, hintText: 'e.g. 0.8'),
                          onChanged: (t) {
                            final v = double.tryParse(t);
                            setState(() {
                              if (_tpSlAsPct) {
                                _slPct = v ?? _slPct;
                              } else {
                                _slAbs = v;
                              }
                            });
                          },
                        ),
                      )),
                ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 40, 197, 40)),
                  onPressed: _busy ? null : () => _place('BUY'),
                  child: const Text('Buy'))),
          const SizedBox(width: 10),
          Expanded(
              child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 199, 28, 28)),
                  onPressed: _busy ? null : () => _place('SELL'),
                  child: const Text('Sell'))),
        ]),
        const SizedBox(height: 16),
      ],
    );

    // Responsive arrangement
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (_, c) {
        final wide = c.maxWidth >= 900; // breakpoint
        final left = SingleChildScrollView(
          physics: advanced
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          child: leftTop,
        );
        final right = SingleChildScrollView(
          child: rightControls,
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: left),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: right),
            ],
          );
        } else {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              left,
              const SizedBox(height: 16),
              right,
            ],
          );
        }
      }),
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

  Widget _modifyButton(Map<String, dynamic> o) {
    final isLmt = (o['type'] ?? '').toString().toUpperCase() == 'LMT';
    if (!isLmt) {
      return const Text('—');
    }
    return IconButton(
      icon: const Icon(Icons.edit),
      onPressed: () async {
        final ctlPx = TextEditingController(text: (o['lmt'] ?? '').toString());
        final ctlQty = TextEditingController(text: (o['qty'] ?? '').toString());
        String tifLocal = (o['tif'] ?? 'DAY').toString();
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Modify Order'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: ctlPx,
                    decoration: const InputDecoration(labelText: 'Limit')),
                const SizedBox(height: 8),
                TextField(
                    controller: ctlQty,
                    decoration: const InputDecoration(labelText: 'Qty')),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  value: tifLocal,
                  items: const [
                    DropdownMenuItem(value: 'DAY', child: Text('DAY')),
                    DropdownMenuItem(value: 'GTC', child: Text('GTC')),
                    DropdownMenuItem(value: 'IOC', child: Text('IOC')),
                  ],
                  onChanged: (v) => tifLocal = v ?? 'DAY',
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save')),
            ],
          ),
        );
        if (result != true) return;
        final id = (o['orderId'] as num?)?.toInt();
        if (id == null) return;
        final newPx = double.tryParse(ctlPx.text);
        final newQty = double.tryParse(ctlQty.text)?.toDouble();
        if (newPx == null || newQty == null) return;
        await Api.ibkrReplaceOrder({
          'orderId': id,
          'symbol': o['symbol'],
          'conId': o['conId'],
          'side': o['action'],
          'type': 'LMT',
          'qty': newQty,
          'limitPrice': newPx,
          'tif': tifLocal,
        });
        // After a replace, just refresh orders silently—SSE will push status updates.
        _refreshLive(silent: true);
      },
    );
  }

  Future<void> _place(String side) async {
    try {
      // Resolve conId from several places (pos, quote root, hist.contract)
      final conIdNum = (widget.pos['conId'] as num?) ??
          (widget.quote?['conId'] as num?) ??
          (widget.hist?['contract']?['conId'] as num?);
      final conId = conIdNum?.toInt();

      // Only send limitPrice for LMT; avoid sending null/NaN
      final double? limit = (type == 'LMT') ? lmt : null;
      if (type == 'LMT' && (limit == null || limit.isNaN)) {
        throw Exception('Limit price required for LMT');
      }
      // compute final size
      final qFinal = _sizedQty(side);
      if (qFinal <= 0) {
        throw Exception('Qty must be > 0 (check USD sizing and price).');
      }

      // Optional clamp to Buying Power
      final pxCtx = (type == 'LMT') ? limit : _entryPx(side);
      final bpActive = _activeBp();
      if (pxCtx != null && bpActive != null) {
        final qMax = _maxQtyFor(pxCtx);
        if (_sizing == 'QTY' && qFinal > qMax) {
          throw Exception('Qty exceeds max by Buying Power (~$qMax).');
        }
        if (_sizing == 'USD' && _usd > bpActive) {
          throw Exception(
              'Notional exceeds ${_cashOnlyBP ? "Cash" : "Margin"} Buying Power '
              '(${NumberFormat.currency(symbol: '\$').format(bpActive)})');
        }
      }

      dynamic res;
      if (_useBracket) {
        // derive absolute TP/SL from pct if needed
        final px = (type == 'LMT') ? limit : _entryPx(side);
        if (px == null || px <= 0) {
          throw Exception('No price context for bracket.');
        }
        double? tp = _tpAbs;
        double? sl = _slAbs;
        if (_tpSlAsPct) {
          // Treat as absolute delta in % of price (1.0 means +1.0 *not* 1%)
          // If you want 1.0% style, change to (px * (1 + _tpPct/100))
          tp = side == 'BUY' ? px + _tpPct : px - _tpPct;
          sl = side == 'BUY' ? px - _slPct : px + _slPct;
        } else {
          if (tp == null || sl == null) {
            throw Exception('Provide TP and SL for bracket.');
          }
          // For SELL, ensure tp < px and sl > px by convention
          if (side == 'SELL') {
            // nothing to do; server expects absolute prices either way
          }
        }
        res = await Api.ibkrPlaceBracket(
          symbol: conId == null ? widget.symbol : null,
          conId: conId,
          side: side,
          qty: qFinal.toDouble(),
          entryType: type,
          limitPrice: limit,
          takeProfit: tp,
          stopLoss: sl,
          tif: tif,
        );
      } else {
        res = await Api.ibkrPlaceOrder(
          symbol: conId == null ? widget.symbol : null,
          conId: conId,
          // Hint backend for non-STK instruments when no conId:
          secType: _bestSecType(),
          exchange: _bestExchange() ?? '',
          currency: _bestCurrency() ?? '',
          side: side,
          type: type,
          qty: qFinal.toDouble(),
          limitPrice: limit,
          tif: tif,
        );
      }
      if (!mounted) return;
      // Prefer 'status' (simple orders) or 'parentStatus' (brackets)
      String? st;
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        st = (m['status'] ?? m['parentStatus'])?.toString();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(st == null ? 'Order sent' : 'Order $st')),
      );
      _refreshLive();
      _ensureOrdersPoll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Order failed: $e')));
    }
  }

  double _expandedChartHeight(BuildContext context) {
    // ~60% of screen, clamped to a sensible range
    final h = MediaQuery.of(context).size.height;

    final target = h * 0.6;
    return math.max(360, math.min(720, target));
  }

  // Map IBKR exchange/secType to a TradingView symbol prefix where we’re confident.
  // If we’re unsure, return the raw symbol (TradingView will resolve best it can).
  String _tvSymbol(String symbol, Map<String, dynamic> pos) {
    final exch = ((pos['primaryExchange'] ?? pos['exchange'])?.toString() ?? '')
        .toUpperCase();
    final st = (pos['secType']?.toString() ?? '').toUpperCase();

    // FX often uses broker prefixes; we’ll fall back to plain symbol.
    if (st == 'FX' || st == 'CASH') {
      final s = symbol.replaceAll('/', '');
      return s; // e.g., "EURUSD" (no hard-coded broker)
    }

    // US
    if (exch.contains('NASDAQ')) return 'NASDAQ:$symbol';
    if (exch.contains('NYSE')) return 'NYSE:$symbol';
    if (exch.contains('ARCA')) {
      return 'AMEX:$symbol'; // many ARCA names live under AMEX on TV
    }

    // UK
    if (exch.contains('LSE')) return 'LSE:$symbol';

    // Germany
    if (exch.contains('XETRA') || exch.contains('IBIS')) return 'XETR:$symbol';
    if (exch.contains('FWB') || exch.contains('FRANKFURT')) {
      return 'FWB:$symbol';
    }

    // Canada
    if (exch.contains('TSX')) return 'TSX:$symbol';

    // Switzerland (IBKR often uses EBS/SWX for SIX Swiss)
    if (exch.contains('EBS') || exch.contains('SWX') || exch.contains('SIX')) {
      return 'SIX:$symbol';
    }

    // Spain (BME)
    if (exch.contains('BME') || exch.contains('XMAD')) return 'BME:$symbol';

    // Italy (Borsa Italiana)
    if (exch.contains('BVME') || exch.contains('MIL')) return 'MIL:$symbol';

    // Euronext (Paris/Amsterdam/Brussels/Lisbon) — IBKR codes often: SBF (Paris),
    // AEB (Amsterdam), ENEXT/ENX, BVLP (Lisbon), ENEXT.BR/EBR (Brussels).
    if (exch.contains('SBF') ||
        exch.contains('AEB') ||
        exch.contains('ENEXT') ||
        exch.contains('ENX') ||
        exch.contains('BVLP') ||
        exch.contains('EBR') ||
        exch.contains('BRU')) {
      return 'EURONEXT:$symbol';
    }

    // Add more as needed (NSE, BSE, ASX, TSE, SEHK, etc.)
    // if (exch.contains('NSE')) return 'NSE:$symbol';
    // if (exch.contains('BSE')) return 'BSE:$symbol';
    // if (exch.contains('ASX')) return 'ASX:$symbol';
    // if (exch.contains('TSEJ') || exch.contains('TSE')) return 'TSE:$symbol';
    // if (exch.contains('SEHK') || exch.contains('HKEX')) return 'HKEX:$symbol';

    // Fallback: bare symbol
    return symbol;
  }
}

/// Wraps the asset panel in a static, animated dialog frame that
/// can grow to 90% of the screen when "Advanced" is ON.
class _AssetPanelDialog extends StatefulWidget {
  final Widget child;
  final ValueNotifier<bool> advancedVN;
  const _AssetPanelDialog({required this.child, required this.advancedVN});
  @override
  State<_AssetPanelDialog> createState() => _AssetPanelDialogState();
}

class _AssetPanelDialogState extends State<_AssetPanelDialog> {
  double _widthFactor = 0.8;
  double _heightFactor = 0.8;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.advancedVN,
      builder: (_, adv, child) {
        _widthFactor = adv ? 0.95 : 0.8;
        _heightFactor = adv ? 0.95 : 0.8;
        final size = MediaQuery.of(context).size;
        final targetW = size.width * _widthFactor;
        final targetH = size.height * _heightFactor;
        return Center(
          child: AnimatedContainer(
            width: targetW,
            height: targetH,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: const Color(0xFF0E1526),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF22314E)),
              boxShadow: const [
                BoxShadow(
                    blurRadius: 24, spreadRadius: 2, color: Colors.black26),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
