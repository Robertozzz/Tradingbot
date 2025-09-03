import 'package:flutter/material.dart';
import 'package:tradingbot/ibkr_panel.dart';

class IbkrPage extends StatelessWidget {
  const IbkrPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IBKR Gateway (embedded)')),
      body: Padding(
        padding: const EdgeInsets.all(0), // full-bleed
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Fill all available space for the iframe canvas
            return const SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: IbkrGatewayPanel(),
            );
          },
        ),
      ),
    );
  }
}
