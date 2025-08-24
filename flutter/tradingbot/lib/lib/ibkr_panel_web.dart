// lib/ibkr_panel_web.dart
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web; // replaces dart:html
import 'dart:ui_web' as ui_web; // for platformViewRegistry
import 'dart:js_interop'; // for .toDart on JS Promises

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

    // Xpra HTML5 client (proxied by nginx at /xpra/).
    // Same-origin, interactive, and supports seamless window forwarding.
    _iframe = web.HTMLIFrameElement()
      ..src = '/xpra-lite/singlewindow.html?mute=1&dpi=96&pixel_ratio=1'
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
      ..style.height = '100%'
      ..sandbox.add('allow-forms')
      ..sandbox.add('allow-pointer-lock')
      ..sandbox.add('allow-scripts')
      ..sandbox.add('allow-same-origin'); // required to inspect DOM

    // Detect gateway/iframe error states (same-origin).
    _iframe.onLoad.listen((_) {
      try {
        final doc = _iframe.contentDocument;
        final bodyText = (doc?.body?.textContent ?? '').toLowerCase();
        final title = (doc?.title ?? '').toLowerCase();
        final looksBad = bodyText.contains('bad gateway') ||
            bodyText.contains('gateway') ||
            title.contains('gateway');
        setState(() => _showOverlay = looksBad);
      } catch (_) {
        // If we cannot read (shouldn’t happen with same-origin), do nothing.
      }
    });

    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(
        'ibkr-xpra',
        (int _) => _iframe,
      );
      _registered = true;
    }
  }

  Future<void> _restartGateway() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      // Build a proper URL and Request (package:web expects URL / RequestInfo).
      final url = web.URL('/admin/ibkr/start', web.window.location.href);
      final req = web.Request(url, web.RequestInit(method: 'POST'));
      // fetch() returns a JS Promise → convert to Dart Future via .toDart
      await web.window.fetch(req).toDart;
      // (optional) you can check resp.status/ok here if you want:
      // if (!resp.ok) { /* show an error */ }
      // Nudge the iframe to reload after a short delay.
      await Future.delayed(const Duration(milliseconds: 600));
      _iframe.src = _iframe.src; // reload
    } catch (_) {
      // keep overlay; user can try again
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _reload() {
    _iframe.src = _iframe.src;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const HtmlElementView(viewType: 'ibkr-xpra'),
        // Small persistent controls (top-right)
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
