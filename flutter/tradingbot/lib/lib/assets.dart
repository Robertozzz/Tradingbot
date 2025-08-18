import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/lib/api.dart';
import 'package:tradingbot/lib/charts.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  Map<String, dynamic>? data;
  Timer? timer;
  final fMoney = NumberFormat.currency(symbol: '\$');
  List<Map<String, dynamic>> _ibkrPos = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadIbkr();
    timer = Timer.periodic(const Duration(seconds: 20), (_) {
      _load();
      _loadIbkr();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await Api.assets();
      setState(() => data = d);
    } catch (_) {}
  }

  Future<void> _loadIbkr() async {
    try {
      final rows = await Api.ibkrPositions();
      final list = rows
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _ibkrPos = list.isEmpty ? _demoIbkrPositions() : list;
      });
    } catch (_) {
      setState(() {
        _ibkrPos = _demoIbkrPositions();
      });
    }
  }

  List<Map<String, dynamic>> _demoIbkrPositions() => [
        {
          "account": "DU1234567",
          "symbol": "AAPL",
          "secType": "STK",
          "position": 50,
          "avgCost": 172.12,
          "currency": "USD",
          "exchange": "SMART"
        },
        {
          "account": "DU1234567",
          "symbol": "MSFT",
          "secType": "STK",
          "position": 20,
          "avgCost": 318.40,
          "currency": "USD",
          "exchange": "SMART"
        },
        {
          "account": "DU1234567",
          "symbol": "ESZ4",
          "secType": "FUT",
          "position": 1,
          "avgCost": 5210.0,
          "currency": "USD",
          "exchange": "GLOBEX"
        },
      ];

  @override
  Widget build(BuildContext context) {
    final assets = (data?['assets'] as List?) ?? [];
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
            // --- Demo assets table (unchanged) ---
            DataTable(
              columns: const [
                DataColumn(label: Text('Asset')),
                DataColumn(label: Text('Quantity')),
                DataColumn(label: Text('USD')),
                DataColumn(label: Text('24h')),
                DataColumn(label: Text('Spark')),
              ],
              rows: assets.map((a) {
                final sym = '${a['symbol'] ?? a['asset'] ?? '-'}';
                final qty = (a['quantity'] ?? a['qty'] ?? 0).toDouble();
                final usd = (a['usd'] ?? a['total_usd'] ?? a['value_usd'] ?? 0)
                    .toDouble();
                final ch = (a['_change_24h_pct'] ?? 0).toDouble();
                final sp = ((a['_spark'] as List?) ?? [])
                    .map((e) => (e as num).toDouble())
                    .toList();
                final chColor =
                    ch >= 0 ? const Color(0xFF4CC38A) : const Color(0xFFEF4444);
                return DataRow(cells: [
                  DataCell(Text(sym)),
                  DataCell(Text(qty.toStringAsFixed(6))),
                  DataCell(Text(fMoney.format(usd))),
                  DataCell(Text(
                      '${ch >= 0 ? '+' : ''}${ch.toStringAsFixed(2)}%',
                      style: TextStyle(color: chColor))),
                  DataCell(
                      SizedBox(width: 120, height: 36, child: sparkLine(sp))),
                ]);
              }).toList(),
            ),

            // --- IBKR positions table (new) ---
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
                    DataColumn(label: Text('Qty')),
                    DataColumn(label: Text('Avg Cost')),
                    DataColumn(label: Text('CCY')),
                    DataColumn(label: Text('Exchange')),
                  ],
                  rows: _ibkrPos.map((m) {
                    final qty = (m['position'] as num?) ?? 0;
                    final avg = (m['avgCost'] as num?) ?? 0;
                    return DataRow(cells: [
                      DataCell(Text(m['account']?.toString() ?? '')),
                      DataCell(Text(m['symbol']?.toString() ?? '')),
                      DataCell(Text(m['secType']?.toString() ?? '')),
                      DataCell(Text(qty.toString())),
                      DataCell(Text(fMoney.format(avg))),
                      DataCell(Text(m['currency']?.toString() ?? '')),
                      DataCell(Text(m['exchange']?.toString() ?? '')),
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
}
