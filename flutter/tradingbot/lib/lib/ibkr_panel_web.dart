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

  @override
  void initState() {
    super.initState();

    // Build a very clean, full-bleed iframe using the noVNC "lite" client
    Uri(queryParameters: {
      'autoconnect': 'true',
      'reconnect': 'true',
      'reconnect_delay': '2000',
      'resize': 'scale', // scale canvas to iframe
      'view_only': 'false',
      'path': 'websockify', // our nginx -> 127.0.0.1:6080
      // Optional knobs you can experiment with:
      // 'show_dot': 'true',         // small cursor dot
      // 'quality': '9',             // jpeg quality (0-9)
      // 'compression': '0',         // 0-9
    }).toString();
    final iframe = web.HTMLIFrameElement()
      ..src = '/novnc/vnc_lite.html'
          '?autoconnect=1'
          '&reconnect=1'
          '&reconnect_delay=1000'
          '&resize=scale'
          '&path=websockify'
      // NOTE: omit view_only entirely (default = interactive),
      // or explicitly: '&view_only=false'
      ..style.border = '0'
      ..style.pointerEvents = 'auto'
      ..allowFullscreen = true
      ..tabIndex = -1 // allow focusing for keyboard input
      ..style.width = '100%'
      ..style.height = '100%';

    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(
        'ibkr-novnc-lite',
        (int _) => iframe,
      );
      _registered = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fill remaining space; use Scaffold surrounding page to define padding
    return const HtmlElementView(viewType: 'ibkr-novnc-lite');
  }
}
