// settings_ibkr_embed.dart
// Simple noVNC embed inside Flutter Web Settings page.
// Add this to your Settings screen and ensure it's only built on web.

import 'dart:html' as html; // Only on web builds
import 'dart:ui' as ui; // For platformViewRegistry
import 'package:flutter/material.dart';

class IbkrGatewayPanel extends StatefulWidget {
  const IbkrGatewayPanel({super.key});

  @override
  State<IbkrGatewayPanel> createState() => _IbkrGatewayPanelState();
}

class _IbkrGatewayPanelState extends State<IbkrGatewayPanel> {
  late final html.IFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    // Autoconnect to /websockify with scaling
    final url =
        '/novnc/vnc.html?autoconnect=true&resize=scale&view_only=false&path=websockify';
    _iframe = html.IFrameElement()
      ..src = url
      ..style.border = '0'
      ..allowFullscreen = true
      ..style.width = '100%'
      ..style.height = '720px';

    // Register a unique view type once
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry
        .registerViewFactory('ibkr-novnc', (int viewId) => _iframe);
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
            const Text('IBKR Gateway Console',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Accept the agreement, log in, and complete 2FA when prompted.'),
            const SizedBox(height: 12),
            SizedBox(
              height: 720,
              child: HtmlElementView(viewType: 'ibkr-novnc'),
            ),
          ],
        ),
      ),
    );
  }
}
