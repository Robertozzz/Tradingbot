import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:tradingbot/lib/charts.dart';
import 'asset_lookup.dart';
import 'tradingview_widget.dart';

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
        _loadSpark(
            symbol: s, conId: conId, secType: (m['secType'] ?? '').toString());

        if (conId != null && !_pnl.containsKey(conId)) _loadPnlSingle(conId);
      }
    } catch (_) {}
  }

  // add a small throttle like in lookup if you have lots of positions
  static int _sparkInflight = 0;
  static const int _sparkMax = 3;
  Future<void> _loadSpark({String? symbol, int? conId, String? secType}) async {
    try {
      final st = (secType ?? '').toUpperCase();
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH');
      while (_sparkInflight >= _sparkMax) {
        await Future.delayed(const Duration(milliseconds: 180));
      }
      _sparkInflight++;
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
        final mn = vals.reduce((a, b) => a < b ? a : b);
        final mx = vals.reduce((a, b) => a > b ? a : b);
        final norm = mx - mn < 1e-9
            ? List.filled(vals.length, 0.5)
            : vals.map((v) => (v - mn) / (mx - mn)).toList();
        if (symbol != null) setState(() => _sparks[symbol] = norm.toList());
      }
    } catch (_) {
    } finally {
      _sparkInflight = (_sparkInflight - 1).clamp(0, _sparkMax);
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
      final st = (pos['secType'] ?? '').toString().toUpperCase();
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH');
      quote = await Api.ibkrQuote(conId: conId, symbol: symbol);
      hist = await Api.ibkrHistory(
          conId: conId,
          symbol: symbol,
          duration: '5 D',
          barSize: '30 mins',
          what: what,
          useRTH: useRth);
    } catch (_) {}

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
              quote: quote,
              hist: hist,
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
  StreamSubscription<SSEModel>? _orderSseSub;

  // --- Account / Buying Power state ---
  Map<String, dynamic>? _acctSummary; // raw /ibkr/accounts (first account)
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

  double? get _mid =>
      (_bid != null && _ask != null) ? (_bid! + _ask!) / 2.0 : null;
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
    if (_quoteLive != null) {
      _bid = (_quoteLive!['bid'] as num?)?.toDouble();
      _ask = (_quoteLive!['ask'] as num?)?.toDouble();
      _last = (_quoteLive!['last'] as num?)?.toDouble() ??
          (_quoteLive!['close'] as num?)?.toDouble();
    }
    // try to discover a nice display name (positions don't have names)
    _loadPrettyName();
    _refreshLive();
    _loadAccount(); // <-- fetch account summary / buying power
    // start light quote poller for L1
    _quoteTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final int? conId = ((widget.pos['conId'] as num?) ??
                (_quoteLive?['conId'] as num?) ??
                (_histLive?['contract']?['conId'] as num?))
            ?.toInt();
        final q = await Api.ibkrQuote(conId: conId, symbol: widget.symbol);
        if (!mounted) return;
        setState(() {
          _quoteLive = q;
          _bid = (q['bid'] as num?)?.toDouble();
          _ask = (q['ask'] as num?)?.toDouble();
          _last = (q['last'] as num?)?.toDouble() ??
              (q['close'] as num?)?.toDouble();
        });
      } catch (_) {}
    });
    // No listener needed here; dialog listens to VN for sizing.
    // BUT the PANEL also must rebuild so the Switch, height, and TV swap update.
    _advListener = () {
      if (mounted) setState(() {});
    };
    widget.advancedVN.addListener(_advListener!);

    _orderSseSub = SSEClient.subscribeToSSE(
      url: '${Api.baseUrl}/ibkr/orders/stream',
      method: SSERequestType.GET,
      header: const {'Accept': 'text/event-stream'},
    ).listen((evt) {
      if (!mounted) return;

      // We only care about "trade" events from the server
      final evName = (evt.event ?? '').toLowerCase();
      if (evName != 'trade') return;

      final data = evt.data;
      if (data == null || data.isEmpty) return;

      Map<String, dynamic> m;
      try {
        m = Map<String, dynamic>.from(jsonDecode(data) as Map);
      } catch (_) {
        return;
      }

      // Determine if the update is for the instrument displayed in this panel
      final int? panelCid = ((widget.pos['conId'] as num?) ??
              (_quoteLive?['conId'] as num?) ??
              (_histLive?['contract']?['conId'] as num?))
          ?.toInt();
      final int? msgCid = (m['conId'] as num?)?.toInt();
      final bool sameInstrument = panelCid != null
          ? (msgCid == panelCid)
          : ((m['symbol']?.toString() ?? '').toUpperCase() ==
              widget.symbol.toUpperCase());
      if (!sameInstrument) return;

      // Merge/insert into the Open Orders table
      setState(() {
        final oid = (m['orderId'] as num?)?.toInt();
        if (oid == null) return;
        final idx =
            _orders.indexWhere((o) => (o['orderId'] as num?)?.toInt() == oid);
        if (idx >= 0) {
          _orders = [
            ..._orders.sublist(0, idx),
            {..._orders[idx], ...m},
            ..._orders.sublist(idx + 1),
          ];
        } else {
          _orders = [..._orders, m];
        }
      });

      // Surface status transitions to the user (optional but helpful)
      final st = (m['status'] ?? '').toString();
      if (st.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order ${m['orderId']}: $st')),
        );
      }
    }, onError: (_) {
      // ignore transient SSE/network errors
    });
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
          if (mounted)
            setState(() => _assetName = (m['name'] ?? '').toString());
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
      _orderSseSub?.cancel();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _reloadQuoteHist() async {
    final int? conId = ((_quoteLive?['conId'] as num?) ??
            (_histLive?['contract']?['conId'] as num?) ??
            (widget.quote?['conId'] as num?) ??
            (widget.hist?['contract']?['conId'] as num?) ??
            (widget.pos['conId'] as num?))
        ?.toInt();
    try {
      final q = await Api.ibkrQuote(conId: conId, symbol: widget.symbol);
      final st = (widget.pos['secType'] ?? '').toString().toUpperCase();
      final what =
          (st == 'FX' || st == 'CASH' || st == 'IND') ? 'MIDPOINT' : 'TRADES';
      final useRth = !(st == 'FX' || st == 'CASH');
      final h = await Api.ibkrHistory(
        conId: conId,
        symbol: widget.symbol,
        duration: '5 D',
        barSize: '30 mins',
        what: what,
        useRTH: useRth,
      );
      if (!mounted) return;
      setState(() {
        _quoteLive = q;
        _histLive = h;
      });
    } catch (_) {}
  }

  Future<void> _refreshLive() async {
    if (!mounted) return;
    setState(() => _busy = true);
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
    } finally {
      if (mounted) setState(() => _busy = false);
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

  @override
  Widget build(BuildContext context) {
    final q = _quoteLive ?? widget.quote;
    final h = _histLive ?? widget.hist;
    final bars = (h?['bars'] as List?) ?? const [];
    // build line safely (no O(n^2) indexOf + guard empty)
    final List<FlSpot> spots = () {
      double i = 0;
      final out = <FlSpot>[];
      for (final b in bars) {
        final c = (b is Map ? b['c'] as num? : null)?.toDouble();
        if (c != null) out.add(FlSpot(i++, c));
      }
      return out;
    }();
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
                  : LineChart(
                      LineChartData(
                        gridData:
                            FlGridData(show: true, drawVerticalLine: false),
                        borderData: FlBorderData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                              spots: spots,
                              isCurved: true,
                              barWidth: 2,
                              dotData: const FlDotData(show: false)),
                        ],
                      ),
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
                          DataColumn(label: Text('Modify')),
                          DataColumn(label: Text('Cancel')),
                        ],
                        rows: _orders
                            .map((o) => DataRow(cells: [
                                  DataCell(Text('${o['orderId'] ?? ''}')),
                                  DataCell(Text('${o['action'] ?? ''}')),
                                  DataCell(Text('${o['qty'] ?? ''}')),
                                  DataCell(Text('${o['type'] ?? ''}')),
                                  DataCell(Text(
                                      o['lmt'] == null ? '—' : '${o['lmt']}')),
                                  DataCell(Text('${o['tif'] ?? ''}')),
                                  DataCell(Text('${o['status'] ?? ''}')),
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
                  onChanged: (v) => setState(() => _cashOnlyBP = v),
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
                  _tiny('Bid', () => setState(() => lmt = _bid)),
                  const SizedBox(width: 4),
                  _tiny('Mid', () => setState(() => lmt = _mid)),
                  const SizedBox(width: 4),
                  _tiny('Ask', () => setState(() => lmt = _ask)),
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
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1A31),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF22314E)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _chip('Account ID',
                    trailing: Text((_acctSummary!['accountId'] ??
                            _acctSummary!['AccountId'] ??
                            _acctSummary!['acctId'] ??
                            '')
                        .toString())),
                _chip('Currency',
                    trailing: Text((_acctSummary!['Currency'] ??
                            _acctSummary!['currency'] ??
                            'USD')
                        .toString())),
                _chip('NetLiq',
                    trailing: Text(NumberFormat.currency(symbol: '\$').format(
                        _numOrNull(_acctSummary!['NetLiquidation']) ?? 0))),
                _chip('Excess Liquidity',
                    trailing: Text(NumberFormat.currency(symbol: '\$').format(
                        _numOrNull(_acctSummary!['ExcessLiquidity']) ?? 0))),
                _chip('Gross Position',
                    trailing: Text(NumberFormat.currency(symbol: '\$').format(
                        _numOrNull(_acctSummary!['GrossPositionValue']) ?? 0))),
                _chip('BP (Cash)',
                    trailing: Text(NumberFormat.currency(symbol: '\$')
                        .format(_bpCashUsd ?? 0))),
                _chip('BP (Margin)',
                    trailing: Text(NumberFormat.currency(symbol: '\$')
                        .format(_bpMarginUsd ?? 0))),
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
        _refreshLive();
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
