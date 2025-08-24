import 'dart:async';
import 'package:flutter/material.dart';
import 'news_api.dart';

class NewsStreamPanel extends StatefulWidget {
  const NewsStreamPanel({
    super.key,
    this.baseUrl = '',
    this.symbols = const ['AAPL', 'GOOGL', 'MSFT'],
    this.providers = const ['BZ', 'DJNL', 'BRFG', 'FLY'],
  });

  final String baseUrl;
  final List<String> symbols;
  final List<String> providers;

  @override
  State<NewsStreamPanel> createState() => _NewsStreamPanelState();
}

class _NewsStreamPanelState extends State<NewsStreamPanel> {
  late final IbNewsApi api;
  StreamSubscription<IbNewsItem>? _sub;
  final items = <IbNewsItem>[];

  // UI state
  Map<String, String> availableProviders = {};
  final Set<String> selectedProviders = {};
  final List<String> watchSymbols = [];
  final TextEditingController symCtl = TextEditingController();
  bool streaming = false;
  String status = 'idle';
  DateTime? lastHeadlineAt;

  // ---------- Auto-trade settings ----------
  bool autoTradeEnabled = false;
  bool watchlistOnly = true; // only act if symbol is in watchSymbols
  double orderSizeUsd = 5000; // notional sizing
  double maxSpreadPct = 0.004; // 0.4%
  String tif = 'IOC'; // IOC or DAY/GTC
  String entryType = 'LMT'; // MKT or LMT

  // Catalyst detection (ported from py)
  final List<(String, RegExp)> _catalysts = [
    (
      'earnings_beat_guide_up',
      RegExp(
          r'(beats|above)\s+(EPS|earnings|revenue).*(raises|boosts)\s+guidance',
          caseSensitive: false)
    ),
    (
      'earnings_miss_guide_down',
      RegExp(r'(misses|below).*(cuts|lowers)\s+guidance', caseSensitive: false)
    ),
    (
      'fda_approval',
      RegExp(r'(FDA|EMA).*(approval|clears|authorized)', caseSensitive: false)
    ),
    (
      'fda_negative',
      RegExp(r'(CRL|complete response|reject|fail(ed)?)', caseSensitive: false)
    ),
    (
      'mna_agreed',
      RegExp(r'(to be acquired|acquires|merger agreement|definitive agreement)',
          caseSensitive: false)
    ),
    (
      'offering',
      RegExp(r'(follow-on|secondary|ATM|equity offering|priced offering)',
          caseSensitive: false)
    ),
    ('buyback', RegExp(r'(buyback|repurchase)\s+\$?\d', caseSensitive: false)),
  ];

  // Playbook: bias / stop (px) / take-profits (px deltas from entry)
  final Map<String, Map<String, Object>> _playbook = {
    'earnings_beat_guide_up': {
      'bias': 'long',
      'stop_px': 1.0,
      'tps': [1.0, 1.5]
    },
    'earnings_miss_guide_down': {
      'bias': 'short',
      'stop_px': 1.0,
      'tps': [1.0, 1.8]
    },
    'fda_approval': {
      'bias': 'long',
      'stop_px': 1.2,
      'tps': [1.2, 2.0]
    },
    'fda_negative': {
      'bias': 'short',
      'stop_px': 1.2,
      'tps': [1.0, 2.0]
    },
    'mna_agreed': {
      'bias': 'long',
      'stop_px': 0.3,
      'tps': [0.3]
    },
    'offering': {
      'bias': 'short',
      'stop_px': 1.0,
      'tps': [1.0]
    },
    'buyback': {
      'bias': 'long',
      'stop_px': 0.8,
      'tps': [0.8, 1.2]
    },
  };

  String? _detectCatalyst(String headline) {
    final h = headline.trim();
    for (final (key, rx) in _catalysts) {
      if (rx.hasMatch(h)) return key;
    }
    // tiny fuzzy-ish fallback
    if (h.toLowerCase().contains('guidance') &&
        h.toLowerCase().contains('raised')) {
      return 'earnings_beat_guide_up';
    }
    return null;
  }

  // Try to infer a symbol for provider-wide headlines by scanning the watchlist tokens in the headline.
  String? _inferSymbolFromHeadline(String headline) {
    // simple token check; you can replace with a name->ticker map later
    for (final s in watchSymbols) {
      // enforce word boundary-ish match
      final rx = RegExp(r'(^|[^A-Z])' + RegExp.escape(s) + r'([^A-Z]|$)');
      if (rx.hasMatch(headline)) return s;
    }
    return null;
  }

  Future<bool> _passRisk(String symbol) async {
    // One-shot quote to compute spread gate
    try {
      final q = await api.quote(symbol);
      final bid = (q['bid'] as num?)?.toDouble() ?? 0;
      final ask = (q['ask'] as num?)?.toDouble() ?? 0;
      if (bid <= 0 || ask <= 0) return false;
      final mid = (bid + ask) / 2.0;
      if (mid <= 0) return false;
      final spread = (ask - bid) / mid;
      return spread <= maxSpreadPct;
    } catch (_) {
      return false;
    }
  }

  int _sizeByUsd(double usd, double px) {
    if (px <= 0) return 0;
    final n = (usd / px).floor();
    return n < 1 ? 1 : n;
  }

  Future<void> _routeTrade(String symbol, String catalyst) async {
    final pb = _playbook[catalyst];
    if (pb == null) return;
    if (!await _passRisk(symbol)) {
      // silently drop (or show a snack)
      return;
    }
    // pull a fresh price to anchor limits/TP/SL
    final q = await api.quote(symbol);
    final bid = (q['bid'] as num?)?.toDouble() ?? 0;
    final ask = (q['ask'] as num?)?.toDouble() ?? 0;
    final last = (q['last'] as num?)?.toDouble() ?? 0;
    final sideBias = (pb['bias'] as String);
    final isLong = sideBias == 'long';
    final entryPx = (entryType == 'MKT')
        ? (isLong ? ask : bid)
        : (isLong ? (ask > 0 ? ask : last) : (bid > 0 ? bid : last));
    if (entryPx <= 0) return;
    final qty = _sizeByUsd(orderSizeUsd, entryPx).toDouble();
    if (qty <= 0) return;

    final stopPxDelta = (pb['stop_px'] as num).toDouble();
    final tpDeltas =
        (pb['tps'] as List).cast<num>().map((e) => e.toDouble()).toList();
    final stopAbs = isLong ? (entryPx - stopPxDelta) : (entryPx + stopPxDelta);
    // simplest: use first TP as bracket TP (you can expand to ladder later)
    final tpAbs =
        isLong ? (entryPx + tpDeltas.first) : (entryPx - tpDeltas.first);

    await api.placeBracket(
      symbol: symbol,
      side: isLong ? 'BUY' : 'SELL',
      qty: qty,
      entryType: entryType, // 'MKT' or 'LMT'
      limitPrice: entryType == 'LMT' ? entryPx : null,
      takeProfit: tpAbs,
      stopLoss: stopAbs,
      tif: tif, // 'IOC' / 'DAY' / 'GTC'
    );
  }

  @override
  void initState() {
    super.initState();
    api = IbNewsApi(base: widget.baseUrl);
    watchSymbols.addAll(widget.symbols);
    selectedProviders.addAll(widget.providers);
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    try {
      final prov = await api.providers();
      setState(() => availableProviders = prov);
    } catch (_) {
      setState(() => availableProviders = {});
    }
  }

  Future<void> _subscribe() async {
    // Allow provider-only subscriptions (symbols may be empty)
    if (watchSymbols.isEmpty && selectedProviders.isEmpty) return;
    setState(() => status = 'subscribing…');
    final ok = await api.subscribe(
      watchSymbols,
      providers: selectedProviders.isEmpty ? null : selectedProviders.toList(),
    );
    setState(() => status = ok ? 'subscribed' : 'subscribe failed');
  }

  Future<void> _unsubscribeAll() async {
    if (watchSymbols.isEmpty && selectedProviders.isEmpty) return;
    setState(() => status = 'unsubscribing…');
    bool ok = true;
    if (watchSymbols.isNotEmpty) {
      ok = ok && await api.unsubscribe(watchSymbols);
    }
    if (selectedProviders.isNotEmpty) {
      ok = ok && await api.unsubscribeProviders(selectedProviders.toList());
    }
    setState(() => status = ok ? 'unsubscribed' : 'unsubscribe failed');
  }

  void _startStream() {
    if (streaming) return;
    setState(() {
      streaming = true;
      status = 'streaming';
      items.clear();
    });
    _sub = api.stream().listen((n) async {
      // push to UI list
      setState(() {
        items.insert(0, n);
        if (items.length > 300) items.removeLast();
        lastHeadlineAt = DateTime.now();
      });
      // ---------- FAST PATH: auto trade ----------
      if (!autoTradeEnabled) return;
      // provider allowlist is already the UI-selected set we sent to server;
      // still guard here if user toggled after subscribe:
      if (selectedProviders.isNotEmpty &&
          !selectedProviders.contains(n.provider)) {
        return;
      }
      // symbol resolution
      String? sym = n.symbol;
      if (sym == null || sym.isEmpty) {
        // try to infer from headline if provider-wide
        sym = _inferSymbolFromHeadline(n.headline);
        if (sym == null) return;
      }
      if (watchlistOnly && !watchSymbols.contains(sym)) return;
      final catalyst = _detectCatalyst(n.headline);
      if (catalyst == null) return;
      try {
        await _routeTrade(sym, catalyst);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Auto-trade fired: $sym • $catalyst')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Auto-trade error: $e')),
          );
        }
      }
    }, onError: (_) {
      setState(() {
        streaming = false;
        status = 'stream error';
      });
    }, cancelOnError: false);
  }

  void _stopStream() async {
    await _sub?.cancel();
    setState(() {
      streaming = false;
      status = 'stopped';
    });
  }

  Future<void> _quickBuy(String symbol) async {
    try {
      final q = await api.quote(symbol);
      final price = (q['ask'] ?? q['last'] ?? q['close']);
      if (price == null) throw Exception('no price');
      final ask = (price as num).toDouble();
      // toy levels; tune as you like:
      final tp = ask + 1.00;
      final sl = ask - 0.80;
      await api.placeBracket(
        symbol: symbol,
        side: 'BUY',
        qty: 10, // TODO: make user-configurable
        entryType: 'LMT',
        limitPrice: ask.toDouble(),
        takeProfit: tp.toDouble(),
        stopLoss: sl.toDouble(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bracket sent for $symbol @ ~$ask')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Quick Buy failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    symCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header / controls
          Row(
            children: [
              const Text('IBKR News',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Chip(
                label: Text(status),
                backgroundColor: scheme.surface.withValues(alpha: .5),
              ),
              const SizedBox(width: 12),
              if (lastHeadlineAt != null)
                Text('last: ${lastHeadlineAt!.toLocal()}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: _loadProviders,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh Providers'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ---------- Auto-trade toggles ----------
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: .06)),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                    value: autoTradeEnabled,
                    onChanged: (v) => setState(() => autoTradeEnabled = v),
                  ),
                  const Text('Auto-trade'),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(
                    value: watchlistOnly,
                    onChanged: (v) => setState(() => watchlistOnly = v),
                  ),
                  const Text('Watchlist only'),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Notional \$'),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 90,
                    child: TextFormField(
                      initialValue: orderSizeUsd.toStringAsFixed(0),
                      onChanged: (t) {
                        final v = double.tryParse(t);
                        if (v != null && v > 0) {
                          setState(() => orderSizeUsd = v);
                        }
                      },
                      decoration: const InputDecoration(isDense: true),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Max spread %'),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 70,
                    child: TextFormField(
                      initialValue: (maxSpreadPct * 100).toStringAsFixed(2),
                      onChanged: (t) {
                        final v = double.tryParse(t);
                        if (v != null && v >= 0) {
                          setState(() => maxSpreadPct = v / 100.0);
                        }
                      },
                      decoration: const InputDecoration(isDense: true),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                DropdownButton<String>(
                  value: entryType,
                  items: const [
                    DropdownMenuItem(value: 'LMT', child: Text('Entry: LMT')),
                    DropdownMenuItem(value: 'MKT', child: Text('Entry: MKT')),
                  ],
                  onChanged: (v) => setState(() => entryType = v ?? 'LMT'),
                ),
                DropdownButton<String>(
                  value: tif,
                  items: const [
                    DropdownMenuItem(value: 'IOC', child: Text('TIF: IOC')),
                    DropdownMenuItem(value: 'DAY', child: Text('TIF: DAY')),
                    DropdownMenuItem(value: 'GTC', child: Text('TIF: GTC')),
                  ],
                  onChanged: (v) => setState(() => tif = v ?? 'IOC'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Provider selector
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in availableProviders.entries)
                FilterChip(
                  label: Text('${entry.key} • ${entry.value}',
                      overflow: TextOverflow.ellipsis),
                  selected: selectedProviders.contains(entry.key),
                  onSelected: (v) {
                    setState(() {
                      if (v) {
                        selectedProviders.add(entry.key);
                      } else {
                        selectedProviders.remove(entry.key);
                      }
                    });
                  },
                ),
              if (availableProviders.isEmpty)
                const Text(
                    'No providers returned (check IBKR entitlements or API connection).',
                    style: TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 12),

          // Symbol watchlist editor
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: symCtl,
                  decoration: const InputDecoration(
                    hintText: 'Add symbol (e.g. NVDA)',
                    filled: true,
                  ),
                  onSubmitted: (t) {
                    final v = t.trim().toUpperCase();
                    if (v.isEmpty) return;
                    if (!watchSymbols.contains(v)) {
                      setState(() => watchSymbols.add(v));
                    }
                    symCtl.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _subscribe,
                child: const Text('Subscribe'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _unsubscribeAll,
                child: const Text('Unsubscribe'),
              ),
              const SizedBox(width: 8),
              if (!streaming)
                FilledButton.icon(
                  onPressed: _startStream,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Stream'),
                )
              else
                OutlinedButton.icon(
                  onPressed: _stopStream,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Watchlist chips
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final s in watchSymbols)
                InputChip(
                  label: Text(s),
                  onDeleted: () => setState(() => watchSymbols.remove(s)),
                ),
              if (watchSymbols.isEmpty)
                const Text('No symbols selected',
                    style: TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 8),

          // Headlines list
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: .4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: .06)),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    Divider(color: Colors.white.withValues(alpha: .08)),
                itemBuilder: (ctx, i) {
                  final n = items[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                        "[${n.provider}] ${n.symbol ?? '—'} — ${n.headline}",
                        style: const TextStyle(fontSize: 13.5, height: 1.25)),
                    subtitle: Text(n.time,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white70)),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: (n.symbol == null || n.symbol!.isEmpty)
                              ? null
                              : () => _quickBuy(n.symbol!),
                          child: Text('Quick Buy',
                              style: TextStyle(color: scheme.primary)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
