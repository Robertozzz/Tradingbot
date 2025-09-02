// lib/ibkr_panel_web.dart
import 'dart:convert';
import 'dart:js_interop'; // .toDart for JS Promises
import 'dart:math' as math;
import 'dart:ui_web' as ui_web; // platformViewRegistry
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web; // JS interop DOM (instead of dart:html)

class IbkrGatewayPanel extends StatefulWidget {
  const IbkrGatewayPanel({super.key});

  @override
  State<IbkrGatewayPanel> createState() => _IbkrGatewayPanelState();
}

class _IbkrGatewayPanelState extends State<IbkrGatewayPanel> {
  // ---- iframe / viewer state ----
  static bool _registered = false;
  late final web.HTMLIFrameElement _iframe;
  bool _showOverlay = false; // error overlay over iframe (only when visible)
  bool _showXpra = false; // actually mount the iframe
  bool _starting = false;

  // ---- settings (merged from IbcConfigCard) ----
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String _mode = 'paper';
  bool _busy = false;
  String? _status;
  bool _dbg = false; // switch state (server toggle)
  bool _dbgBusy = false; // POST in flight
  bool _showPw = false; // toggle for password visibility

  @override
  void initState() {
    super.initState();

    // Build iframe element (initially src-less; we set it only when allowed+online)
    _xpraUrl(); // includes DPI+audio flags
    _iframe = web.HTMLIFrameElement()
      ..src = '' // lazy: only set when we decide to show
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0'
      ..style.overflow = 'hidden'
      ..style.display = 'none' // ensure not visible until enabled
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

    // initial loads
    _loadConfig();
    _syncDebugStatusAndMaybeShow();
  }

  // Build the xpra HTML5 client URL with just the essentials:
  // - scaling=off, pixel_ratio=1, dpi=96 : prevent DPI conflict/flicker
  // - speaker=false, microphone=false, audio=false : fully mute
  String _xpraUrl({bool bust = false}) {
    final base = '/xpra-main/index.html';
    final u = web.URL(base, web.window.location.href);

    // Clear query (not used) and set options in the hash:
    u.search = bust ? '?v=${DateTime.now().millisecondsSinceEpoch}' : '';
    u.hash =
        'scaling=off&pixel_ratio=1&dpi=96&speaker=off&microphone=off&audio=off&bell=off';

    return u.toString();
  }

  // ---------- merged settings logic ----------
  Future<void> _loadConfig() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/config'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() {
          _user.text = (j['IB_USER'] ?? '') as String;
          _mode = (j['IB_MODE'] ?? 'paper') as String;
          _status = null;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final r = await http.post(
        Uri.parse('/ibkr/ibc/config'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'user': _user.text.trim(),
          'password': _pass.text,
          'mode': _mode,
          'restart': true,
        }),
      );
      if (r.statusCode == 200) {
        setState(() {
          _status = 'Saved. Restarted.';
        });
        // if viewer is visible, detach and re-probe to avoid sticky 502
        if (_showXpra) {
          _hideIframe(); // fully detach
          // After a short pause, poll and re-show when ready.
          // Fire-and-forget; UI remains responsive.
          () async {
            await Future.delayed(const Duration(milliseconds: 600));
            final ok = await _probeXpraWithRetry(
                attempts: 30, delay: const Duration(milliseconds: 400));
            if (!mounted) return;
            if (ok) _showIframe(bust: true);
          }();
        }
      } else {
        setState(() {
          _status = 'Error ${r.statusCode}: ${r.body}';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Network error: $e';
      });
    } finally {
      setState(() {
        _busy = false;
        _pass.clear();
      });
    }
  }

  // ---------- debug viewer (toggle + reachability) ----------
  Future<bool> _getDebugActive() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/debugviewer/status'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        return (j['active'] == true);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _syncDebugStatusAndMaybeShow() async {
    final active = await _getDebugActive();
    if (!mounted) return;
    setState(() => _dbg = active);
    if (active) {
      final ok = await _probeXpraWithRetry();
      if (!mounted) return;
      if (ok) _showIframe();
    }
  }

  Future<void> _setDebug(bool enable) async {
    // capture messenger BEFORE any awaits to avoid using BuildContext across async gaps
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _dbgBusy = true);
    try {
      final r = await http.post(
        Uri.parse('/ibkr/ibc/debugviewer'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'enabled': enable}),
      );
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        final serverActive = (j['active'] == true);
        setState(() => _dbg = serverActive);

        if (serverActive) {
          // only reveal iframe once endpoint is actually reachable (avoid 502)
          final ok = await _probeXpraWithRetry();
          if (ok) {
            if (!mounted) return;
            _showIframe(bust: true);
          } else {
            if (!mounted) return;
            messenger?.showSnackBar(const SnackBar(
              content:
                  Text('Gateway screen enabled, waiting to come online...'),
            ));
          }
        } else {
          _hideIframe();
        }
      } else {
        messenger?.showSnackBar(
          SnackBar(content: Text('Debug viewer: ${r.statusCode} ${r.body}')),
        );
      }
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Debug viewer error: $e')),
      );
    } finally {
      if (mounted) setState(() => _dbgBusy = false);
    }
  }

  Future<bool> _probeXpraOnce() async {
    try {
      final url = web.URL('/xpra-main/index.html', web.window.location.href);
      final resp = await web.window.fetch(url).toDart;
      return resp.ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeXpraWithRetry(
      {int attempts = 10,
      Duration delay = const Duration(milliseconds: 300)}) async {
    for (var i = 0; i < attempts; i++) {
      if (await _probeXpraOnce()) return true;
      await Future.delayed(delay);
    }
    return false;
  }

  void _showIframe({bool bust = false}) {
    final url = _xpraUrl(bust: bust);
    _iframe.src = url;
    _iframe.style.display = ''; // unhide
    setState(() {
      _showXpra = true;
      _showOverlay = false; // will flip to true if onError fires
    });
  }

  void _hideIframe() {
    // Completely hide and detach to prevent overlay artifacts / stray 502.
    _iframe.src = 'about:blank';
    _iframe.style.display = 'none';
    setState(() {
      _showXpra = false;
      _showOverlay = false;
    });
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
      // Detach the iframe to avoid stale 502, then probe and reattach.
      _hideIframe();
      await Future.delayed(const Duration(milliseconds: 600));
      final ok = await _probeXpraWithRetry(
          attempts: 30, delay: const Duration(milliseconds: 400));
      if (ok) _showIframe(bust: true);
    } catch (_) {
      // keep overlay; user can try again
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void reload({bool bust = false}) {
    if (_showXpra) _iframe.src = _xpraUrl(bust: bust);
  }

  // Make the viewer height responsive to the viewport so we don't clip.
  // ~60% of the window height, clamped to a sensible min/max.
  double viewerHeight(BuildContext context) {
    final vh = MediaQuery.of(context).size.height;
    final target = vh * 0.60;
    // keep at least 480px so IBKR is usable; cap to avoid silly tall panes
    final clamped = math.max(480.0, math.min(target, 900.0));
    return clamped;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          // ---- merged settings card ----
          Card(
            elevation: 0,
            color: scheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Compact header: user, password (with eye), mode, debug, save
                  Wrap(
                    runSpacing: 10,
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Icon(Icons.lock, size: 18),
                      ConstrainedBox(
                        constraints:
                            const BoxConstraints(minWidth: 220, maxWidth: 300),
                        child: TextField(
                          controller: _user,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'IBKR username',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints:
                            const BoxConstraints(minWidth: 220, maxWidth: 300),
                        child: TextField(
                          controller: _pass,
                          obscureText: !_showPw,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: 'Password',
                            border: const OutlineInputBorder(),
                            suffixIcon: Focus(
                              canRequestFocus: false,
                              child: IconButton(
                                tooltip:
                                    _showPw ? 'Hide password' : 'Show password',
                                onPressed: () =>
                                    setState(() => _showPw = !_showPw),
                                icon: Icon(_showPw
                                    ? Icons.visibility_off
                                    : Icons.visibility),
                              ),
                            ),
                          ),
                        ),
                      ),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _mode,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _mode = v ?? 'paper'),
                          items: const [
                            DropdownMenuItem(
                                value: 'paper', child: Text('Paper')),
                            DropdownMenuItem(
                                value: 'live', child: Text('Live')),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Show IB gateway screen'),
                          const SizedBox(width: 6),
                          Switch.adaptive(
                            value: _dbg,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: _dbgBusy ? null : (v) => _setDebug(v),
                          ),
                        ],
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _saveConfig,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save),
                        label: const Text('Save & Restart'),
                      ),
                      if (_status != null)
                        Text(_status!, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ---- viewer (only rendered when enabled + reachable) ----
          if (_showXpra) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: viewerHeight(context),
              child: Stack(children: [
                // solid background to prevent perceived color shift on scroll
                Positioned.fill(child: Container(color: scheme.surface)),
                const HtmlElementView(viewType: 'ibkr-xpra'),

                // top-right tiny controls
                Positioned(
                  right: 8,
                  top: 8,
                  child: Row(children: [
                    Tooltip(
                      message: 'Reload',
                      child: IconButton(
                        onPressed: () => reload(bust: true),
                        icon: const Icon(Icons.refresh, size: 20),
                        style: ButtonStyle(
                          backgroundColor:
                              WidgetStateProperty.all(const Color(0x66000000)),
                          foregroundColor:
                              WidgetStateProperty.all(Colors.white),
                        ),
                      ),
                    ),
                  ]),
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
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700),
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
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(Icons.power_settings_new),
                                  label: const Text('Start / Restart Gateway'),
                                ),
                                const SizedBox(width: 12),
                                OutlinedButton.icon(
                                  onPressed: reload,
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
              ]),
            ),
          ],
        ],
      ),
    );
  }
}
