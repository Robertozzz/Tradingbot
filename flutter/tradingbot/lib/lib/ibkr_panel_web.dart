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

  @override
  void initState() {
    super.initState();

    // Build iframe element (initially src-less; we set it only when allowed+online)
    final xpraUrl = _xpraUrl(); // includes DPI+audio flags
    _iframe = web.HTMLIFrameElement()
      ..src = '' // lazy: only set when we decide to show
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

    // initial loads
    _loadConfig();
    _syncDebugStatusAndMaybeShow();
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

  // ---------- merged settings logic ----------
  Future<void> _loadConfig() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/config'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() {
          _user.text = (j['IB_USER'] ?? '') as String;
          _mode = (j['IB_MODE'] ?? 'paper') as String;
          _status = "Using port ${j['IB_PORT'] ?? '4002'}";
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
        final j = json.decode(r.body);
        setState(() {
          _status = 'Saved. Restarted (port ${j['port']}).';
        });
        // if viewer is visible, nudge a reload after restart
        if (_showXpra) _reload();
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
            _showIframe();
          } else {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text(
                      'Viewer enabled, waiting for Xpra to come online...')),
            );
          }
        } else {
          _hideIframe();
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Debug viewer: ${r.statusCode} ${r.body}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
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

  void _showIframe() {
    final url = _xpraUrl();
    _iframe.src = url;
    setState(() {
      _showXpra = true;
      _showOverlay = false; // will flip to true if onError fires
    });
  }

  void _hideIframe() {
    _iframe.src = ''; // detach
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
      await Future.delayed(const Duration(seconds: 1));
      if (_showXpra) {
        _iframe.src = _xpraUrl();
        setState(() => _showOverlay = false);
      }
    } catch (_) {
      // keep overlay; user can try again
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _reload() {
    if (_showXpra) _iframe.src = _xpraUrl();
  }

  // Make the viewer height responsive to the viewport so we don't clip.
  // ~60% of the window height, clamped to a sensible min/max.
  double _viewerHeight(BuildContext context) {
    final vh = MediaQuery.of(context).size.height;
    final target = vh * 0.60;
    // keep at least 480px so IBKR is usable; cap to avoid silly tall panes
    final clamped = math.max(480.0, math.min(target, 900.0));
    return clamped;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(children: [
          // ---- merged settings card ----
          Card(
            elevation: 0,
            color: scheme.surface.withValues(alpha: .6),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.lock, size: 18),
                    const SizedBox(width: 8),
                    Text('IBKR Gateway (IBC)',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    DropdownButton<String>(
                      value: _mode,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _mode = v ?? 'paper'),
                      items: const [
                        DropdownMenuItem(value: 'paper', child: Text('Paper')),
                        DropdownMenuItem(value: 'live', child: Text('Live')),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child: TextField(
                      controller: _user,
                      decoration: const InputDecoration(
                        labelText: 'IBKR Username',
                        border: OutlineInputBorder(),
                      ),
                    )),
                    const SizedBox(width: 12),
                    Expanded(
                        child: TextField(
                      controller: _pass,
                      decoration: const InputDecoration(
                        labelText: 'Password (not shown after save)',
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                    )),
                  ]),
                  const SizedBox(height: 12),
                  // Debug viewer row (controls the iframe visibility too)
                  Row(children: [
                    const Icon(Icons.display_settings, size: 18),
                    const SizedBox(width: 8),
                    const Text('Debug Viewer (Xpra)'),
                    const Spacer(),
                    Switch.adaptive(
                      value: _dbg,
                      onChanged: _dbgBusy ? null : (v) => _setDebug(v),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _saveConfig,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save),
                      label: const Text('Save & Restart Gateway'),
                    ),
                    const SizedBox(width: 12),
                    if (_status != null)
                      Expanded(
                          child:
                              Text(_status!, overflow: TextOverflow.ellipsis)),
                  ]),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ---- viewer (hidden until enabled + reachable) ----
          SizedBox(
            height: _viewerHeight(context),
            child: _showXpra
                ? Stack(children: [
                    const HtmlElementView(viewType: 'ibkr-xpra'),

                    // top-right tiny controls
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Row(children: [
                        Tooltip(
                          message: 'Reload',
                          child: IconButton(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh, size: 20),
                            style: ButtonStyle(
                              backgroundColor: WidgetStateProperty.all(
                                  const Color(0x66000000)),
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
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700),
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
                                      onPressed:
                                          _starting ? null : _restartGateway,
                                      icon: _starting
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2))
                                          : const Icon(
                                              Icons.power_settings_new),
                                      label:
                                          const Text('Start / Restart Gateway'),
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
                  ])
                : Center(
                    child: Text(
                      _dbg
                          ? 'Enabling viewer… waiting for Xpra to come online'
                          : 'Viewer hidden. Enable “Debug Viewer (Xpra)” to show it here.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
