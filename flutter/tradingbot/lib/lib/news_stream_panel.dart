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
    _sub = api.stream().listen((n) {
      setState(() {
        items.insert(0, n);
        if (items.length > 300) items.removeLast();
        lastHeadlineAt = DateTime.now();
      });
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
