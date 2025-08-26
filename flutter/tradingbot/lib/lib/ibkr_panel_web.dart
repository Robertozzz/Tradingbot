// lib/ibkr_panel_web.dart
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web; // JS interop DOM (instead of dart:html)
import 'dart:ui_web' as ui_web; // platformViewRegistry
import 'dart:js_interop'; // .toDart for JS Promises

class IbkrGatewayPanel extends StatefulWidget {
  const IbkrGatewayPanel({super.key});

  @override
  State<IbkrGatewayPanel> createState() => _IbkrGatewayPanelState();
}

class _IbkrGatewayPanelState extends State<IbkrGatewayPanel> {
  static bool _registered = false;
  late final web.HTMLIFrameElement _iframe;
  bool _showOverlay = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();

    // Minimal, no fancy sizing. Let the iframe fill the widget.
    final xpraUrl = _xpraUrl(); // includes DPI+audio flags
    _iframe = web.HTMLIFrameElement()
      ..src = xpraUrl
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0'
      ..style.overflow = 'hidden'
      ..allowFullscreen = true
      ..allow = 'clipboard-read; clipboard-write; fullscreen'
      ..sandbox.add('allow-forms')
      ..sandbox.add('allow-pointer-lock')
      ..sandbox.add('allow-scripts')
      ..sandbox.add('allow-same-origin') // same-origin so we can inspect body
      ..tabIndex = -1;

    // If the iframe loads successfully, hide overlay.
    _iframe.onLoad.listen((_) {
      if (mounted) setState(() => _showOverlay = false);
    });

    // If the iframe fails to load at all (network/server down), show overlay.
    _iframe.onError.listen((_) {
      if (mounted) setState(() => _showOverlay = true);
    });

    if (!_registered) {
      ui_web.platformViewRegistry
          .registerViewFactory('ibkr-xpra', (int _) => _iframe);
      _registered = true;
    }
  }

  // Build the xpra HTML5 client URL with just the essentials:
  // - scaling=off, pixel_ratio=1, dpi=96 : prevent DPI conflict/flicker
  // - speaker=false, microphone=false, audio=false : fully mute
  String _xpraUrl() {
    final base = '/xpra-main/index.html';
    final u = web.URL(base, web.window.location.href);

    // Clear query (not used) and set options in the hash:
    u.search = '';
    u.hash =
        'scaling=off&pixel_ratio=1&dpi=96&speaker=off&microphone=off&audio=off&bell=off';

    return u.toString();
  }

  Future<void> _restartGateway() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final url = web.URL('/system/control', web.window.location.href);

      // Create a concrete Headers object and set values on it.
      final hdrs = web.Headers();
      hdrs.set('Content-Type', 'application/json');

      // Build init with the headers instance and a JS string body.
      final init = web.RequestInit(
        method: 'POST',
        headers: hdrs,
        body: r'{"module":"ibgateway","action":"restart"}'.toJS,
      );

      await web.window.fetch(url, init).toDart;
      await Future.delayed(const Duration(seconds: 1));
      _iframe.src = _xpraUrl();
      setState(() => _showOverlay = false);
    } catch (_) {
      // keep overlay; user can try again
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _reload() {
    _iframe.src = _xpraUrl();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const HtmlElementView(viewType: 'ibkr-xpra'),

        // top-right tiny controls
        Positioned(
          right: 8,
          top: 8,
          child: Row(
            children: [
              Tooltip(
                message: 'Reload',
                child: IconButton(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh, size: 20),
                  style: ButtonStyle(
                    backgroundColor:
                        WidgetStateProperty.all(const Color(0x66000000)),
                    foregroundColor: WidgetStateProperty.all(Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Gateway-down overlay with quick actions
        if (_showOverlay)
          Positioned.fill(
            child: Container(
              color: const Color(0xCC0E1526),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'IBKR Gateway is not reachable',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Start or restart the app, then this panel will load.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.icon(
                          onPressed: _starting ? null : _restartGateway,
                          icon: _starting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.power_settings_new),
                          label: const Text('Start / Restart Gateway'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try Reload'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
