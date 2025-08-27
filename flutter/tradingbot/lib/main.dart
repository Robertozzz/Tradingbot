import 'package:flutter/material.dart';
import 'lib/auth_gate.dart';
import 'lib/dashboard.dart';
import 'lib/app_events.dart';
import 'lib/accounts.dart';
import 'lib/assets.dart';
import 'lib/news_stream_panel.dart';
import 'lib/trades.dart';
import 'lib/settings.dart';
import 'lib/trading_clock.dart';
import 'lib/ibkr_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initTz(); // timezone DB (safe to skip on web if asset missing)
  } catch (_) {
    // ignore; UI should still boot
  }
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B1220),
      cardColor: const Color(0xFF111A2E),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF60A5FA),
        secondary: Color(0xFF4CC38A),
        error: Color(0xFFEF4444),
        surface: Color(0xFF0F1628),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Color(0xFFE2E8F0)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0F1628),
        elevation: 0,
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tradingbot',
      theme: theme,
      home:
          //TODO DEBUG
          // AuthGate(child:
          const Shell(), // your existing scaffold/nav/pages
      // ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;
  bool railExpanded = true;

  bool showMarketClock = true;
  // "UTC" or "Local"
  String displayTzName = 'Local';

  // Simulated prefs for which markets to show
  Map<String, bool> enabledMarkets = {
    'NYSE': true,
    'LONDON': true,
    'TOKYO': true,
    // others off
    'NASDAQ': false,
    'TSX': false,
    'FRANKFURT': false,
    'PARIS': false,
    'ZURICH': false,
    'MADRID': false,
    'HONG KONG': false,
    'SHANGHAI': false,
    'SINGAPORE': false,
    'SYDNEY': false,
    'NZX': false,
    'TADAWUL': false,
    'DUBAI': false,
  };

  @override
  void initState() {
    super.initState();
    // Start the single, auto-reconnecting global orders stream.
    OrderEvents.instance.ensureStarted();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 1100;

    final pages = [
      const DashboardPage(),
      const AccountsPage(),
      const AssetsPage(),
      const TradesPage(),
      const IbkrPage(),
      SettingsPage(
        showMarketClock: showMarketClock,
        onMarketClockToggle: (v) => setState(() => showMarketClock = v),
        enabledMarkets: enabledMarkets,
        onMarketToggle: (name, v) => setState(() {
          enabledMarkets = Map<String, bool>.from(enabledMarkets)..[name] = v;
        }),
        displayTzName: displayTzName,
        onDisplayTzChanged: (tz) => setState(() => displayTzName = tz),
      ),
      const NewsStreamPanel(),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Tradingbot')),
      body: Column(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (wide)
                  _SidePanel(
                    expanded: railExpanded,
                    selectedIndex: index,
                    onToggleExpanded: () =>
                        setState(() => railExpanded = !railExpanded),
                    onSelect: (i) => setState(() => index = i),
                  ),
                // Use a loose fit so the page takes its natural height
                // and stays pinned to the top (with a nice max width).
                Flexible(
                  fit: FlexFit.loose,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1400),
                      child: pages[index],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showMarketClock)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Column(
                children: [
                  // TAPE CLOCK (auto-height) at bottom
                  TapeClockCentered(
                    key: ValueKey('Tape-$displayTzName'),
                    markets: defaultMarkets,
                    enabled: enabledMarkets,
                    displayTzName: displayTzName,
                    autoHeight: true,
                    minHeight: 84,
                  ),
                ],
              ),
            ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => index = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.dashboard), label: 'Dashboard'),
                NavigationDestination(
                    icon: Icon(Icons.account_balance), label: 'Accounts'),
                NavigationDestination(
                    icon: Icon(Icons.pie_chart), label: 'Assets'),
                NavigationDestination(
                    icon: Icon(Icons.swap_horiz), label: 'Trades'),
                NavigationDestination(
                    icon: Icon(Icons.desktop_windows), label: 'IBKR'),
                NavigationDestination(
                    icon: Icon(Icons.settings), label: 'Settings'),
                NavigationDestination(
                    icon: Icon(Icons.newspaper), label: 'News'),
              ],
            ),
    );
  }
}

/// Pretty, expandable left panel with categories & dividers.
class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.expanded,
    required this.selectedIndex,
    required this.onSelect,
    required this.onToggleExpanded,
  });

  final bool expanded;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggleExpanded;

  static const _itemsCore = [
    (Icons.dashboard, 'Dashboard'),
    (Icons.account_balance, 'Accounts'),
    (Icons.pie_chart, 'Assets'),
    (Icons.swap_horiz, 'Trades'),
  ];
  static const _itemsSystem = [
    // NEW: IBKR console as its own page
    (Icons.desktop_windows, 'IBKR'),
    (Icons.settings, 'Settings'),
    (Icons.newspaper, 'News'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = expanded ? 260.0 : 76.0;
    final textStyle = Theme.of(context)
        .textTheme
        .bodyMedium!
        .copyWith(fontWeight: FontWeight.w600, letterSpacing: .2);
    final sectionStyle = textStyle.copyWith(
      color: Colors.white70,
      fontSize: 12,
      letterSpacing: 1.1,
    );

    Widget buildTile(int i, (IconData, String) data) {
      final (icon, label) = data;
      final selected = selectedIndex == i;
      final bg =
          selected ? scheme.primary.withValues(alpha: .12) : Colors.transparent;
      final fg =
          selected ? scheme.primary : Colors.white.withValues(alpha: .88);
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: () => onSelect(i),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: selected
                  ? Border.all(color: scheme.primary.withValues(alpha: .35))
                  : null,
            ),
            padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
            child: Row(
              mainAxisAlignment:
                  expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(icon, size: expanded ? 24 : 22, color: fg),
                if (expanded) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(label, style: textStyle.copyWith(color: fg)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .6),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: .06)),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment:
                expanded ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              // Header / Brand + expand button
              Row(
                mainAxisAlignment: expanded
                    ? MainAxisAlignment.spaceBetween
                    : MainAxisAlignment.center,
                children: [
                  if (expanded)
                    Row(
                      children: [
                        const Icon(Icons.show_chart, size: 20),
                        const SizedBox(width: 8),
                        Text('Tradingbot xpra',
                            style: sectionStyle.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.6,
                            )),
                      ],
                    ),
                  IconButton(
                    tooltip: expanded ? 'Collapse' : 'Expand',
                    onPressed: onToggleExpanded,
                    icon: Icon(
                      expanded ? Icons.chevron_left : Icons.chevron_right,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Divider(color: Colors.white.withValues(alpha: .08)),
              // Scrollable middle section (prevents overflow)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  physics: const ClampingScrollPhysics(),
                  children: [
                    if (expanded)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, bottom: 8),
                        child: Text('CORE', style: sectionStyle),
                      ),
                    ...List.generate(
                      _itemsCore.length,
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: buildTile(i, _itemsCore[i]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Divider(color: Colors.white.withValues(alpha: .08)),
                    const SizedBox(height: 8),
                    if (expanded)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, bottom: 8),
                        child: Text('SYSTEM', style: sectionStyle),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: buildTile(4, _itemsSystem[0]),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: buildTile(5, _itemsSystem[1]), // Settings
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: buildTile(6, _itemsSystem[2]), // News
                    ),
                  ],
                ),
              ),
              // Footer stays visible without causing overflow
              if (expanded)
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 8, top: 8),
                  child: Text(
                    'v1.0 • Dark',
                    style: sectionStyle.copyWith(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
