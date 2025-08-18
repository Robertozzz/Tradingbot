import 'package:flutter/material.dart';

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
          // ===== Tape Clock (combined controls) =====
          Card(
            elevation: 0,
            color: scheme.surface.withOpacity(.6),
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
            color: scheme.surface.withOpacity(.6),
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
