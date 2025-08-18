// lib/ibkr_panel_stub.dart
import 'package:flutter/material.dart';

class IbkrGatewayPanel extends StatelessWidget {
  const IbkrGatewayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('IBKR Gateway Console',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Available on Web builds. This desktop/mobile build does not '
                'embed the gateway UI.'),
          ],
        ),
      ),
    );
  }
}
