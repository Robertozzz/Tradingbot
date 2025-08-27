// lib/ibc_settings_card.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web; // for window.open on web

class IbcConfigCard extends StatefulWidget {
  const IbcConfigCard({super.key});

  @override
  State<IbcConfigCard> createState() => _IbcConfigCardState();
}

class _IbcConfigCardState extends State<IbcConfigCard> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _totp = TextEditingController();
  String _mode = 'paper';
  bool _busy = false;
  String? _status;
  bool _dbg = false;
  bool _dbgBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadDebug();
  }

  Future<void> _load() async {
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

  Future<void> _loadDebug() async {
    try {
      final r = await http.get(Uri.parse('/ibkr/ibc/debugviewer/status'));
      if (r.statusCode == 200) {
        final j = json.decode(r.body) as Map<String, dynamic>;
        setState(() => _dbg = (j['active'] == true));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
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
          'totp': _totp.text.trim(),
          'mode': _mode,
          'restart': true,
        }),
      );
      if (r.statusCode == 200) {
        final j = json.decode(r.body);
        setState(() {
          _status = 'Saved. Restarted (port ${j['port']}).';
        });
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
        _totp.clear();
      });
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
        setState(() => _dbg = (j['active'] == true));
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
      setState(() => _dbgBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surface.withValues(alpha: .6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                onChanged:
                    _busy ? null : (v) => setState(() => _mode = v ?? 'paper'),
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
            // --- Debug viewer toggle row ---
            Row(children: [
              const Icon(Icons.display_settings, size: 18),
              const SizedBox(width: 8),
              const Text('Debug Viewer (Xpra)'),
              const Spacer(),
              TextButton.icon(
                onPressed: _dbg
                    ? () {
                        try {
                          web.window.open('/xpra-ibc/', '_blank');
                        } catch (_) {}
                      }
                    : null,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open viewer'),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: _dbg,
                onChanged: _dbgBusy ? null : (v) => _setDebug(v),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _save,
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
                    child: Text(_status!, overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ),
      ),
    );
  }
}
