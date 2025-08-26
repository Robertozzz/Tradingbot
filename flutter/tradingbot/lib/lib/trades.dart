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

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh when any order status changes anywhere in the app.
    _orderBusSub = OrderEvents.instance.stream.listen((event) {
      final st = (event['status'] ?? event['parentStatus'] ?? '').toString();
      if (st.isNotEmpty) {
        _load();
      }
    }, onError: (_) {
      // ignore bus errors
    });
  }

  @override
  void dispose() {
    try {
      _orderBusSub?.cancel();
    } catch (_) {}
    super.dispose();
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
          .toList());
    } catch (_) {}
  }

  Future<void> _cancel(int id) async {
    try {
      await Api.ibkrCancelOrder(id);
    } catch (_) {}
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
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
                      DataCell(Text(m['lmt'] == null ? '—' : '${m['lmt']}')),
                      DataCell(Text('${m['tif'] ?? ''}')),
                      DataCell(Text('${m['status'] ?? ''}')),
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
        const Text('Orders Log', style: TextStyle(fontWeight: FontWeight.bold)),
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
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
