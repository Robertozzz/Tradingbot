import 'package:flutter/material.dart';

class TradesPage extends StatelessWidget {
  const TradesPage({super.key});
  @override
  Widget build(BuildContext context) {
    return const Center(child: Padding(
      padding: EdgeInsets.all(16),
      child: Text('Trades – wire to trades_open.json / trades_closed.json when exported.'),
    ));
  }
}
