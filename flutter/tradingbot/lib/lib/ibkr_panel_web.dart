// lib/ibkr_panel_web.dart
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web; // replaces dart:html
import 'dart:ui_web' as ui_web; // for platformViewRegistry

class IbkrGatewayPanel extends StatefulWidget {
  const IbkrGatewayPanel({super.key});

  @override
  State<IbkrGatewayPanel> createState() => _IbkrGatewayPanelState();
}

class _IbkrGatewayPanelState extends State<IbkrGatewayPanel> {
  static bool _registered = false;
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();

    // Xpra HTML5 client (proxied by nginx at /xpra/).
    // Same-origin, interactive, and supports seamless window forwarding.
    _iframe = web.HTMLIFrameElement()
      ..src =
          '/xpra/?embedded=1&toolbar=0&tray=0&menus=0&notifications=0&background=0'
              '&scaling=fit&keyboard=1&reconnect=1'
      ..style.border = '0'
      ..style.pointerEvents = 'auto'
      ..tabIndex = -1 // allow focusing for keyboard input
      ..allowFullscreen = true
      // Allow clipboard + fullscreen for a nicer experience.
      ..allow = 'clipboard-read; clipboard-write; fullscreen'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0'
      ..style.pointerEvents = 'auto'
      ..allowFullscreen = true
      ..tabIndex = -1 // allow focusing for keyboard input
      ..style.width = '100%'
      ..style.height = '100%';

    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(
        'ibkr-xpra',
        (int _) => _iframe,
      );
      _registered = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fill remaining space; use Scaffold surrounding page to define padding
    return const HtmlElementView(viewType: 'ibkr-xpra');
  }
}
