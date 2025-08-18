// settings_ibkr_embed.dart
// Simple noVNC embed inside Flutter Web Settings page.
// Works on Flutter Web using package:web instead of dart:html.

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web; // replacement for dart:html
import 'dart:ui_web' as ui_web; // replacement for dart:ui platformViewRegistry

class IbkrGatewayPanel extends StatefulWidget {
  const IbkrGatewayPanel({super.key});

  @override
  State<IbkrGatewayPanel> createState() => _IbkrGatewayPanelState();
}

class _IbkrGatewayPanelState extends State<IbkrGatewayPanel> {
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();

    // Autoconnect to /websockify with scaling
    final url =
        '/novnc/vnc.html?autoconnect=true&resize=scale&view_only=false&path=websockify';

    _iframe = web.HTMLIFrameElement()
      ..src = url
      ..style.border = '0'
      ..allowFullscreen = true
      ..style.width = '100%'
      ..style.height = '720px';

    // Register view type (note the dart:ui_web instead of dart:ui)
    ui_web.platformViewRegistry.registerViewFactory(
      'ibkr-novnc',
      (int viewId) => _iframe,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'IBKR Gateway Console',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Accept the agreement, log in, and complete 2FA when prompted.',
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 720,
              child: const HtmlElementView(viewType: 'ibkr-novnc'),
            ),
          ],
        ),
      ),
    );
  }
}
