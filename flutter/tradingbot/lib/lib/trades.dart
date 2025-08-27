import 'package:flutter/material.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:tradingbot/lib/app_events.dart';

class TradesPage extends StatefulWidget {
  const TradesPage({super.key});
  @override
  State<TradesPage> createState() => _TradesPageState();
}

class _TradesPageState extends State<TradesPage> {
  List<Map<String, dynamic>> _open = const [];
  List<Map<String, dynamic>> _hist = const [];
  final f = NumberFormat.decimalPattern();
  StreamSubscription<Map<String, dynamic>>? _orderBusSub;

  Timer? _poll;

  final Set<String> _hiddenLogKeys = <String>{};

  String _logKey(Map r) =>
      '${r['ts']}-${r['orderId']}-${r['event']}-${r['symbol']}';

  bool _isTerminal(String? s) {
    final st = (s ?? '').toUpperCase();
    return st == 'FILLED' ||
        st == 'CANCELLED' ||
        st == 'INACTIVE' ||
        st.startsWith('APICANCEL');
  }

  void _ensurePoll() {
    final hasActive = _open.any((o) => !_isTerminal(o['status']?.toString()));
    if (hasActive && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    } else if (!hasActive && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Live refresh when any order status changes (from global SSE bus).
    _orderBusSub = OrderEvents.instance.stream.listen((m) {
      // Patch in place so UI updates instantly; still call _ensurePoll().
      final oid = (m['orderId'] as num?)?.toInt();
      if (oid != null) {
        final i =
            _open.indexWhere((o) => (o['orderId'] as num?)?.toInt() == oid);
        if (i >= 0) {
          final merged = {..._open[i], ...m};
          setState(() {
            _open = [
              ..._open.take(i),
              merged,
              ..._open.skip(i + 1),
            ];
          });
        }
      }
      _ensurePoll();
      // Also kick a best-effort resync; it’s cheap and ensures we converge.
      _load();
    }, onError: (_) {});
  }

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

  Future<void> _load() async {
    try {
      final o = await Api.ibkrOpenOrders();
      final h = await Api.ibkrOrdersHistory(limit: 300);
      setState(() => _open = o
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList());
      setState(() => _hist = h
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList()
          .reversed
          .where((r) => !_hiddenLogKeys.contains(_logKey(r)))
          .toList());
      _ensurePoll();
    } catch (_) {}
  }

  Future<void> _cancel(int id) async {
    try {
      await Api.ibkrCancelOrder(id);
    } catch (_) {}
    // SSE will deliver status → table refresh via _orderBusSub.
    // Also do a safety refresh in case SSE is delayed.
    _load();
  }

  @override
  void dispose() {
    try {
      _orderBusSub?.cancel();
    } catch (_) {}
    try {
      _poll?.cancel();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Text('Open Orders',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
              ]),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('OrderId')),
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Action')),
                    DataColumn(label: Text('Qty')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('Limit')),
                    DataColumn(label: Text('TIF')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Filled')),
                    DataColumn(label: Text('Remaining')),
                    DataColumn(label: Text('Cancel')),
                  ],
                  rows: _open
                      .map((m) => DataRow(cells: [
                            DataCell(Text('${m['orderId'] ?? ''}')),
                            DataCell(Text('${m['symbol'] ?? ''}')),
                            DataCell(Text('${m['action'] ?? ''}')),
                            DataCell(Text(f.format((m['qty'] as num?) ?? 0))),
                            DataCell(Text('${m['type'] ?? ''}')),
                            DataCell(
                                Text(m['lmt'] == null ? '—' : '${m['lmt']}')),
                            DataCell(Text('${m['tif'] ?? ''}')),
                            DataCell(_statusCell(m['status'])),
                            DataCell(Text('${m['filled'] ?? 0}')),
                            DataCell(Text('${m['remaining'] ?? 0}')),
                            DataCell(IconButton(
                                icon: const Icon(Icons.cancel),
                                onPressed: () =>
                                    _cancel((m['orderId'] as num).toInt()))),
                          ]))
                      .toList(),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Text('Orders Log',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Clear all (local)',
                    icon: const Icon(Icons.delete_sweep),
                    onPressed: () {
                      setState(() {
                        for (final r in _hist) {
                          _hiddenLogKeys.add(_logKey(r));
                        }
                        _hist = const [];
                      });
                    },
                  ),
                  IconButton(
                    tooltip: 'Reset log (show all)',
                    icon: const Icon(Icons.restore),
                    onPressed: () {
                      setState(() {
                        _hiddenLogKeys.clear();
                      });
                      _load();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF111A2E),
                  border: Border.all(color: const Color(0xFF22314E)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: _hist.map((r) {
                    final ts = DateTime.fromMillisecondsSinceEpoch(
                        ((r['ts'] ?? 0) as int) * 1000,
                        isUtc: false);
                    return ListTile(
                      dense: true,
                      title: Text(
                          '${r['event']?.toString().toUpperCase()} ${r['symbol'] ?? ''} ${r['side'] ?? ''} ${r['qty'] ?? ''} ${r['type'] ?? ''}'),
                      subtitle: Text(
                          '$ts  ${r['ok'] == true ? "OK" : ""}  orderId=${r['orderId'] ?? ""} conId=${r['conId'] ?? ""}'),
                      trailing: IconButton(
                        tooltip: 'Clear this entry (local)',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          setState(() {
                            _hiddenLogKeys.add(_logKey(r));
                            _hist = _hist
                                .where((x) => _logKey(x) != _logKey(r))
                                .toList();
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
