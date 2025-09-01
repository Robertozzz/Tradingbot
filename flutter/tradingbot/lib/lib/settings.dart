import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class SettingsPage extends StatelessWidget {
  final bool showMarketClock;
  final ValueChanged<bool> onMarketClockToggle;

  final Map<String, bool> enabledMarkets;
  final void Function(String, bool) onMarketToggle;

  final String displayTzName; // "UTC" or "Local"
  final ValueChanged<String> onDisplayTzChanged;

  const SettingsPage({
    super.key,
    required this.showMarketClock,
    required this.onMarketClockToggle,
    required this.enabledMarkets,
    required this.onMarketToggle,
    required this.displayTzName,
    required this.onDisplayTzChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          // ===== AI / API Settings =====
          _ApiSettingsCard(),
          const SizedBox(height: 16),
          // ===== Tape Clock (combined controls) =====
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
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Market Tape Clock',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Text('Show',
                              style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(width: 8),
                          Switch.adaptive(
                            value: showMarketClock,
                            onChanged: onMarketClockToggle,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Timezone',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment<String>(
                                value: 'UTC', label: Text('UTC')),
                            ButtonSegment<String>(
                                value: 'Local', label: Text('Local')),
                          ],
                          selected: {displayTzName},
                          onSelectionChanged: (s) =>
                              onDisplayTzChanged(s.first),
                          multiSelectionEnabled: false,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ===== Markets (compact chips) =====
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
                  Row(
                    children: [
                      const Icon(Icons.store_mall_directory, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Visible Markets',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          for (final k in enabledMarkets.keys) {
                            onMarketToggle(k, true);
                          }
                        },
                        child: const Text('Select all'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          for (final k in enabledMarkets.keys) {
                            onMarketToggle(k, false);
                          }
                        },
                        child: const Text('None'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: enabledMarkets.keys.map((name) {
                      final selected = enabledMarkets[name] ?? false;
                      return FilterChip(
                        label: Text(name),
                        selected: selected,
                        onSelected: (v) => onMarketToggle(name, v),
                        showCheckmark: false,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal API settings UI with Save/Test wired to backend.
class _ApiSettingsCard extends StatefulWidget {
  @override
  State<_ApiSettingsCard> createState() => _ApiSettingsCardState();
}

class _ApiSettingsCardState extends State<_ApiSettingsCard> {
  final _formKey = GlobalKey<FormState>();
  final _openaiKeyC = TextEditingController();
  final _searchKeyC = TextEditingController();
  String _model = 'gpt-5';
  bool _enableBrowsing = true;
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _hasOpenAIKey = false;
  bool _hasSearchKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await http.get(Uri.parse('/api/openai/settings'));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _model = (j['model'] as String?) ?? 'gpt-5';
        _enableBrowsing = (j['enable_browsing'] as bool?) ?? true;
        _hasOpenAIKey = (j['has_openai_api_key'] as bool?) ?? false;
        _hasSearchKey = (j['has_search_api_key'] as bool?) ?? false;
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final body = {
        "model": _model,
        // Only send when user typed something; keep empty to clear server-side
        "openai_api_key": _openaiKeyC.text.isNotEmpty ? _openaiKeyC.text : null,
        "search_api_key": _searchKeyC.text.isNotEmpty ? _searchKeyC.text : null,
        "enable_browsing": _enableBrowsing,
      };
      body.removeWhere((k, v) => v == null);
      final r = await http.post(
        Uri.parse('/api/openai/settings'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );
      if (r.statusCode >= 200 && r.statusCode < 300) {
        if (_openaiKeyC.text.isNotEmpty) _hasOpenAIKey = true;
        if (_searchKeyC.text.isNotEmpty) _hasSearchKey = true;
        _openaiKeyC.clear();
        _searchKeyC.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('API settings saved')),
          );
        }
      } else {
        throw Exception('Save failed (${r.statusCode})');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save error: $e')),
        );
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      final r = await http.post(Uri.parse('/api/openai/test'),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"prompt": "ping"}));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final reply = (j['reply'] ?? '').toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OpenAI test: $reply')),
        );
      } else {
        throw Exception('HTTP ${r.statusCode}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Test error: $e')),
      );
    } finally {
      setState(() => _testing = false);
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
        child: _loading
            ? const Center(
                child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ))
            : Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.smart_toy, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'AI / API Settings',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.save),
                          label: const Text('Save'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _testing ? null : _test,
                          icon: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.play_arrow),
                          label: const Text('Test'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _model,
                            items: const [
                              DropdownMenuItem(
                                  value: 'gpt-5', child: Text('gpt-5')),
                              DropdownMenuItem(
                                  value: 'gpt-5-mini',
                                  child: Text('gpt-5-mini')),
                            ],
                            onChanged: (v) =>
                                setState(() => _model = v ?? 'gpt-5'),
                            decoration:
                                const InputDecoration(labelText: 'Model'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Row(
                          children: [
                            const Text('Enable browsing'),
                            const SizedBox(width: 8),
                            Switch.adaptive(
                              value: _enableBrowsing,
                              onChanged: (v) =>
                                  setState(() => _enableBrowsing = v),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _openaiKeyC,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: _hasOpenAIKey
                            ? 'OpenAI API key (set)'
                            : 'OpenAI API key',
                        helperText: _hasOpenAIKey
                            ? 'Leave blank to keep existing key.'
                            : 'Paste your OpenAI API key.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _searchKeyC,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: _hasSearchKey
                            ? 'Search API key (set)'
                            : 'Search API key',
                        helperText:
                            'Optional: for web_search tool (Bing/SerpAPI/etc.).',
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
