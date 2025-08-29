// lib/ibkr_panel_web.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web; // JS interop DOM (instead of dart:html)
import 'dart:ui_web' as ui_web; // platformViewRegistry
import 'dart:js_interop'; // .toDart for JS Promises

class IbkrPanelWeb extends StatefulWidget {
  const IbkrPanelWeb({super.key});

  @override
  State<IbkrPanelWeb> createState() => _IbkrPanelWebState();
}

class _IbkrPanelWebState extends State<IbkrPanelWeb> {
  // ----- Settings state
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _totp = TextEditingController();
  String _mode = 'paper';
  String? _status;
  bool _saving = false;

  // ----- Viewer + control state
  static bool _registered = false;
  late final web.HTMLIFrameElement _iframe;
  bool _showOverlay = false;
  bool _showViewer = true; // toggle to show/hide embed
  bool _ctlBusy = false;

  // optional debug viewer switch (separate lightweight Xpra viewer)
  bool _dbg = false;
  bool _dbgBusy = false;

  @override
  void initState() {
    super.initState();
    _restoreViewerToggle();
    _initIframe();
    _loadConfig();
    _loadDebugViewer();
  }

  void _initIframe() {
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

    _iframe.onLoad.listen((_) {
      if (mounted) setState(() => _showOverlay = false);
    });
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
    u.search = '';
    u.hash =
        'scaling=off&pixel_ratio=1&dpi=96&speaker=off&microphone=off&audio=off&bell=off';
    return u.toString();
  }

  Future<void> _loadConfig() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/config'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() {
          _user.text = (j['IB_USER'] ?? '') as String;
          _mode = (j['IB_MODE'] ?? 'paper') as String;
          _status =
              'Using port ${j['IB_PORT'] ?? '4002'}${(j['IB_TOTP_SECRET_SET'] == true) ? ' • TOTP set' : ''}';
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConfigAndRestart() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final r = await http.post(
        Uri.parse('/ibkr/ibc/config'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'user': _user.text.trim(),
          'password': _pass.text,
          'totp': _totp.text.trim(),
          'mode': _mode,
          'restart': true,
        }),
      );
      if (r.statusCode == 200) {
        final j = json.decode(r.body);
        setState(() => _status = 'Saved. Restarted (port ${j['port']}).');
        // give systemd a beat, then reload the viewer
        await Future.delayed(const Duration(seconds: 1));
        _reloadViewer();
      } else {
        setState(() => _status = 'Error ${r.statusCode}: ${r.body}');
      }
    } catch (e) {
      setState(() => _status = 'Network error: $e');
    } finally {
      setState(() {
        _saving = false;
        _pass.clear();
        _totp.clear();
      });
    }
  }

  Future<void> _controlGateway(String action) async {
    if (_ctlBusy) return;
    setState(() => _ctlBusy = true);
    try {
      final url = web.URL('/system/control', web.window.location.href);
      final hdrs = web.Headers()..set('Content-Type', 'application/json');
      final init = web.RequestInit(
        method: 'POST',
        headers: hdrs,
        body: '{"module":"ibgateway","action":"$action"}'.toJS,
      );
      final res = await web.window.fetch(url, init).toDart;
      if ((res.status ?? 500) >= 200 && (res.status ?? 500) < 300) {
        setState(() => _status =
            '${action[0].toUpperCase()}${action.substring(1)} command sent.');
        await Future.delayed(const Duration(seconds: 1));
        _reloadViewer();
      } else {
        setState(() => _status = 'Gateway $action failed: ${res.status}');
      }
    } catch (e) {
      setState(() => _status = 'Gateway $action error: $e');
    } finally {
      if (mounted) setState(() => _ctlBusy = false);
    }
  }

  Future<void> _loadDebugViewer() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/debugviewer/status'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() => _dbg = (j['active'] == true));
      }
    } catch (_) {}
  }

  Future<void> _setDebugViewer(bool enable) async {
    setState(() => _dbgBusy = true);
    try {
      final r = await http.post(
        Uri.parse('/ibkr/ibc/debugviewer'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'enabled': enable}),
      );
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() => _dbg = (j['active'] == true));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Debug viewer: ${r.statusCode} ${r.body}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Debug viewer error: $e')),
        );
      }
    } finally {
      setState(() => _dbgBusy = false);
    }
  }

  void _reloadViewer() {
    _iframe.src = _xpraUrl();
    setState(() => _showOverlay = false);
  }

  void _openViewerInTab() {
    try {
      web.window.open('/xpra-main/', '_blank');
    } catch (_) {}
  }

  // ----- viewer toggle persisted locally (client-side only)
  void _restoreViewerToggle() {
    try {
      final v = web.window.localStorage.getItem('ibkr.showViewer');
      _showViewer = (v == null) ? true : (v == '1');
    } catch (_) {
      _showViewer = true;
    }
  }

  void _setViewerToggle(bool v) {
    setState(() => _showViewer = v);
    try {
      web.window.localStorage.setItem('ibkr.showViewer', v ? '1' : '0');
    } catch (_) {}
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _totp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // ======= IBC SETTINGS CARD (sits above the embed) =======
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
                  // Viewer visibility switch
                  Row(children: [
                    const Text('Show embedded viewer'),
                    const SizedBox(width: 8),
                    Switch.adaptive(
                      value: _showViewer,
                      onChanged: (v) => _setViewerToggle(v),
                    ),
                  ]),
                  const SizedBox(width: 16),
                  DropdownButton<String>(
                    value: _mode,
                    onChanged: _saving
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
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _pass,
                      decoration: const InputDecoration(
                        labelText: 'Password (not shown after save)',
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: _totp,
                  decoration: const InputDecoration(
                    labelText: 'TOTP Secret (Base32, optional)',
                    helperText: 'If set, IBC will auto-complete 2FA.',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 12),

                // Debug viewer row
                Row(children: [
                  const Icon(Icons.display_settings, size: 18),
                  const SizedBox(width: 8),
                  const Text('Debug Viewer (Xpra)'),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _dbg ? _openViewerInTab : null,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open viewer'),
                  ),
                  const SizedBox(width: 8),
                  Switch.adaptive(
                    value: _dbg,
                    onChanged: _dbgBusy ? null : (v) => _setDebugViewer(v),
                  ),
                ]),

                const SizedBox(height: 12),

                // Control buttons
                Wrap(spacing: 12, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: _saving ? null : _saveConfigAndRestart,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save),
                    label: const Text('Save & Restart Gateway'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _ctlBusy ? null : () => _controlGateway('start'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _ctlBusy ? null : () => _controlGateway('stop'),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        _ctlBusy ? null : () => _controlGateway('restart'),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Restart'),
                  ),
                  TextButton.icon(
                    onPressed: _openViewerInTab,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open in new tab'),
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(_status!, overflow: TextOverflow.ellipsis),
                    ),
                ]),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ======= EMBEDDED VIEWER AREA (show/hide by switch) =======
        if (_showViewer)
          Expanded(
            child: Stack(
              children: [
                const HtmlElementView(viewType: 'ibkr-xpra'),
                // tiny reload button
                Positioned(
                  right: 8,
                  top: 8,
                  child: Tooltip(
                    message: 'Reload viewer',
                    child: IconButton(
                      onPressed: _reloadViewer,
                      icon: const Icon(Icons.refresh, size: 20),
                      style: ButtonStyle(
                        backgroundColor:
                            WidgetStateProperty.all(const Color(0x66000000)),
                        foregroundColor: WidgetStateProperty.all(Colors.white),
                      ),
                    ),
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
                            const Text('IBKR Gateway is not reachable',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            const Text(
                                'Start or restart the app, then this panel will load.',
                                style: TextStyle(color: Colors.white70)),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton.icon(
                                  onPressed: _ctlBusy
                                      ? null
                                      : () => _controlGateway('restart'),
                                  icon: _ctlBusy
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
                                  onPressed: _reloadViewer,
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
            ),
          )
        else
          // Viewer hidden placeholder
          Container(
            height: 80,
            alignment: Alignment.center,
            child: const Text(
                'Embedded viewer is hidden — toggle it on to show the Xpra panel.'),
          ),
      ],
    );
  }
}
