// lib/lib/trading_clock.dart
// Trading Radial & Tape clocks with time-zone aware market sessions.
// Style: solid, flat bands (no glow/gradients), bold uppercase labels.
// Requires: timezone: ^0.9.2
//
// In main.dart you already call: await initTz();

import 'dart:async';
import 'dart:math';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// How many whole-day copies we render on each side of "today" on the tape.
/// Keep this in sync with the scroll clamp below.
const int kRepeatDays = 4; // was 3

Future<void> initTz() async {
  tzdata.initializeTimeZones();
  // Force local to match system offset if tz.local is wrong
  final utc = tz.getLocation('UTC');
  final sysOffset = DateTime.now().timeZoneOffset;
  final tzLocal = tz.local;
  final tzLocalOff = tz.TZDateTime.now(tzLocal).timeZoneOffset;
  final utcOff = tz.TZDateTime.now(utc).timeZoneOffset;
  if (tzLocalOff == utcOff && sysOffset != utcOff) {
    // Replace tz.local with your actual IANA zone
    tz.setLocalLocation(
        tz.getLocation('Europe/Moscow')); // change to your actual zone
  }
}

/// =====================
/// Styling & constants
/// =====================
const Color kBgDark = Color(0xFF0B1118);
const Color kCardDark = Color(0xFF0F1620);
const Color kGrid = Color.fromARGB(255, 49, 57, 70);
const Color kTick = Color(0xFF2A2F37);
const Color kNumber = Color(0xFFB4BAC5);
const Color kNowLine = Color(0xFFE53935); // bright red

// Color scheme: pre=yellow, regular=turquoise, after=blue
const Color PRE_YELLOW = Color(0xFFF6C445);
const Color REG_TURQ = Color(0xFF26D0C9);
const Color AFTER_BLUE = Color(0xFF4C78FF);

const PRE_THICKNESS = 20.0;
const REG_THICKNESS = PRE_THICKNESS;
const AFTER_THICKNESS = PRE_THICKNESS;

// Label style (inside bands)
const TextStyle kBandLabel = TextStyle(
  color: Colors.black,
  fontSize: 12,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.8,
  height: 1.0,
);

enum BandKind { pre, regular, after }

class Market {
  final String name;
  final String tzName;
  final List<MarketBandSpec> bands;

  /// Weekdays the market trades on. Dart weekday: 1=Mon .. 7=Sun
  final Set<int> tradingWeekdays;
  const Market({
    required this.name,
    required this.tzName,
    required this.bands,
    this.tradingWeekdays = const {1, 2, 3, 4, 5}, // Mon–Fri by default
  });
}

class MarketBandSpec {
  final BandKind kind;
  final int startHour, startMinute;
  final int endHour, endMinute;
  final Color color;
  final double thickness;
  final bool showLabel;
  const MarketBandSpec({
    required this.kind,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.color,
    this.thickness = 26, // slimmer
    this.showLabel = false,
  });
}

/// =====================
/// Markets & sessions
/// =====================
final List<Market> defaultMarkets = [
  // ---------- North America ----------
  Market(
    name: 'NYSE',
    tzName: 'America/New_York',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 4,
          startMinute: 0,
          endHour: 9,
          endMinute: 30,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 30,
          endHour: 16,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 16,
          startMinute: 0,
          endHour: 20,
          endMinute: 0,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),
  Market(
    name: 'NASDAQ',
    tzName: 'America/New_York',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 4,
          startMinute: 0,
          endHour: 9,
          endMinute: 30,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 30,
          endHour: 16,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 16,
          startMinute: 0,
          endHour: 20,
          endMinute: 0,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),
  Market(
    name: 'TSX',
    tzName: 'America/Toronto',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 7,
          startMinute: 0,
          endHour: 9,
          endMinute: 30,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 30,
          endHour: 16,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 16,
          startMinute: 15,
          endHour: 17,
          endMinute: 0,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),

  // ---------- Europe ----------
  Market(
    name: 'LONDON',
    tzName: 'Europe/London',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 7,
          startMinute: 50,
          endHour: 8,
          endMinute: 0,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 8,
          startMinute: 0,
          endHour: 16,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 16,
          startMinute: 30,
          endHour: 17,
          endMinute: 0,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),
  Market(
    name: 'FRANKFURT',
    tzName: 'Europe/Berlin',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 7,
          startMinute: 30,
          endHour: 9,
          endMinute: 0,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 17,
          startMinute: 30,
          endHour: 20,
          endMinute: 0,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),
  Market(
    name: 'PARIS',
    tzName: 'Europe/Paris',
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),
  Market(
    name: 'ZURICH',
    tzName: 'Europe/Zurich',
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),
  Market(
    name: 'MADRID',
    tzName: 'Europe/Madrid',
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 17,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),

  // ---------- Asia-Pacific ----------
  Market(
    name: 'TOKYO',
    tzName: 'Asia/Tokyo',
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 11,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 12,
          startMinute: 30,
          endHour: 15,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS),
    ],
  ),
  Market(
    name: 'HONG KONG',
    tzName: 'Asia/Hong_Kong',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 9,
          startMinute: 0,
          endHour: 9,
          endMinute: 30,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 30,
          endHour: 12,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 13,
          startMinute: 0,
          endHour: 16,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS),
      MarketBandSpec(
          kind: BandKind.after,
          startHour: 16,
          startMinute: 0,
          endHour: 16,
          endMinute: 10,
          color: AFTER_BLUE,
          thickness: AFTER_THICKNESS),
    ],
  ),
  Market(
    name: 'SHANGHAI',
    tzName: 'Asia/Shanghai',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 9,
          startMinute: 15,
          endHour: 9,
          endMinute: 30,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 30,
          endHour: 11,
          endMinute: 30,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 13,
          startMinute: 0,
          endHour: 15,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS),
    ],
  ),
  Market(
    name: 'SINGAPORE',
    tzName: 'Asia/Singapore',
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 9,
          startMinute: 0,
          endHour: 12,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 13,
          startMinute: 0,
          endHour: 17,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS),
    ],
  ),
  Market(
    name: 'SYDNEY',
    tzName: 'Australia/Sydney',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 7,
          startMinute: 0,
          endHour: 10,
          endMinute: 0,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 10,
          startMinute: 0,
          endHour: 16,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),
  Market(
    name: 'NZX',
    tzName: 'Pacific/Auckland',
    bands: const [
      MarketBandSpec(
          kind: BandKind.pre,
          startHour: 8,
          startMinute: 0,
          endHour: 10,
          endMinute: 0,
          color: PRE_YELLOW,
          thickness: PRE_THICKNESS),
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 10,
          startMinute: 0,
          endHour: 16,
          endMinute: 45,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),

  // ---------- Middle East ----------
  Market(
    name: 'TADAWUL',
    tzName: 'Asia/Riyadh',
    tradingWeekdays: const {7, 1, 2, 3, 4}, // Sun–Thu
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 10,
          startMinute: 0,
          endHour: 15,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),
  Market(
    name: 'DUBAI',
    tzName: 'Asia/Dubai',
    tradingWeekdays: const {7, 1, 2, 3, 4}, // Sun–Thu
    bands: const [
      MarketBandSpec(
          kind: BandKind.regular,
          startHour: 10,
          startMinute: 0,
          endHour: 14,
          endMinute: 0,
          color: REG_TURQ,
          thickness: REG_THICKNESS,
          showLabel: true),
    ],
  ),
];

/// “Prefs” helper
Map<String, bool> seedEnabledFewImportant(Iterable<Market> markets) {
  const onSet = {'NYSE', 'NASDAQ', 'LONDON', 'TOKYO'};
  return {for (final m in markets) m.name: onSet.contains(m.name)};
}

/// =====================
/// Shared time helpers
/// =====================
double _hourOfDaySince(tz.TZDateTime dt, tz.TZDateTime dayStart) {
  final diffHours = dt.difference(dayStart).inSeconds / 3600.0;
  var h = diffHours;
  while (h < 0) {
    h += 24;
  }
  while (h >= 24) {
    h -= 24;
  }
  return h;
}

tz.TZDateTime _displayMidnight(tz.Location displayLoc) {
  final now = tz.TZDateTime.now(displayLoc);
  return tz.TZDateTime(displayLoc, now.year, now.month, now.day);
}

/// Market band -> start/end hour-of-day in chosen display zone.
({double startH, double endH, tz.TZDateTime openD, tz.TZDateTime closeD})
    _bandHoursInDisplay({
  required MarketBandSpec band,
  required tz.Location marketLoc,
  required tz.Location displayLoc,
  tz.TZDateTime?
      baseMarketDay, // optional: compute for a specific market-local day
}) {
  final base = baseMarketDay ?? tz.TZDateTime.now(marketLoc);
  var openM = tz.TZDateTime(marketLoc, base.year, base.month, base.day,
      band.startHour, band.startMinute);
  var closeM = tz.TZDateTime(
      marketLoc, base.year, base.month, base.day, band.endHour, band.endMinute);
  if (!closeM.isAfter(openM)) closeM = closeM.add(const Duration(days: 1));

  final openD = tz.TZDateTime.from(openM, displayLoc);
  final closeD = tz.TZDateTime.from(closeM, displayLoc);

  final midD = _displayMidnight(displayLoc);
  final startH = _hourOfDaySince(openD, midD);
  final endH = _hourOfDaySince(closeD, midD);
  return (startH: startH, endH: endH, openD: openD, closeD: closeD);
}

/// Compute the single next event text for a market (open/close of any band)

String _nextEventText(Market m, tz.Location displayLoc) {
  final marketLoc = tz.getLocation(m.tzName);
  final now = tz.TZDateTime.now(displayLoc);

  // Build candidate open/close events on future TRADING days (weekend-aware)
  final events = <({tz.TZDateTime t, String label})>[];

  String lblFor(BandKind kind, bool isOpen) {
    switch (kind) {
      case BandKind.pre:
        return isOpen ? 'Pre‑market opens' : 'Pre‑market closes';
      case BandKind.regular:
        return isOpen ? 'Market opens' : 'Market closes';
      case BandKind.after:
        return isOpen ? 'After‑hours opens' : 'After‑hours closes';
    }
  }

  // Look ahead up to 7 days; add events only for trading weekdays
  final todayM = tz.TZDateTime.now(marketLoc);
  for (int d = 0; d <= 7; d++) {
    final baseDay =
        tz.TZDateTime(marketLoc, todayM.year, todayM.month, todayM.day)
            .add(Duration(days: d));
    if (!m.tradingWeekdays.contains(baseDay.weekday)) continue; // skip weekends
    for (final b in m.bands) {
      final h = _bandHoursInDisplay(
        band: b,
        marketLoc: marketLoc,
        displayLoc: displayLoc,
        baseMarketDay: baseDay,
      );
      events.add((t: h.openD, label: lblFor(b.kind, true)));
      events.add((t: h.closeD, label: lblFor(b.kind, false)));
    }
  }

  events.sort((a, b) => a.t.compareTo(b.t));
  final next = events.firstWhere(
    (e) => e.t.isAfter(now),
    orElse: () => (t: now, label: ''),
  );
  if (next.label.isEmpty) return '';

  String two(int v) => v.toString().padLeft(2, '0');
  String hhmm(tz.TZDateTime t) => '${two(t.hour)}:${two(t.minute)}';

  final dur = next.t.difference(now);
  final hours = dur.inHours;
  final minutes = dur.inMinutes.remainder(60);
  final inTxt = hours > 0 ? 'in ${hours}h ${minutes}m' : 'in ${minutes}m';

  // Swap order and remove bullet: "… in 1h 16m (00:00)"
  return '${next.label} $inTxt (${hhmm(next.t)})';
}

/// Current band status per market with time to next boundary.
String _currentBandInfo(Market m, tz.Location displayLoc) {
  final marketLoc = tz.getLocation(m.tzName);
  final now = tz.TZDateTime.now(displayLoc);

  ({double startH, double endH, tz.TZDateTime openD, tz.TZDateTime closeD})
      hoursFor(BandKind kind) {
    final b =
        m.bands.firstWhere((b) => b.kind == kind, orElse: () => m.bands.first);
    return _bandHoursInDisplay(
        band: b, marketLoc: marketLoc, displayLoc: displayLoc);
  }

  bool containsNow(
      ({
        double startH,
        double endH,
        tz.TZDateTime openD,
        tz.TZDateTime closeD
      }) h) {
    return now.isAfter(h.openD) && now.isBefore(h.closeD);
  }

  String two(int v) => v.toString().padLeft(2, '0');
  String hhmm(tz.TZDateTime t) => '${two(t.hour)}:${two(t.minute)}';

  final pre = hoursFor(BandKind.pre);
  final reg = hoursFor(BandKind.regular);
  final aft = hoursFor(BandKind.after);

  if (containsNow(pre)) {
    final dur = pre.closeD.difference(now);
    final h = dur.inHours, m = dur.inMinutes.remainder(60);
    final inTxt = h > 0 ? 'in ${h}h ${m}m' : 'in ${m}m';
    return 'Pre-market opens $inTxt (${hhmm(reg.openD)})';
  }
  if (containsNow(reg)) {
    final dur = reg.closeD.difference(now);
    final h = dur.inHours, m = dur.inMinutes.remainder(60);
    final inTxt = h > 0 ? 'in ${h}h ${m}m' : 'in ${m}m';
    return 'Market closes $inTxt (${hhmm(reg.closeD)})';
  }
  if (containsNow(aft)) {
    final dur = aft.closeD.difference(now);
    final h = dur.inHours, m = dur.inMinutes.remainder(60);
    final inTxt = h > 0 ? 'in ${h}h ${m}m' : 'in ${m}m';
    // Match desired order like the others
    return 'After-hours closes $inTxt (${hhmm(aft.closeD)})';
  }

  // Fallback if we're between bands: show the next event.
  return _nextEventText(m, displayLoc);
}

/// =====================
/// RADIAL CLOCK
/// =====================
class TradingRadialClock extends StatefulWidget {
  final bool visible;
  final List<Market> markets;
  final Map<String, bool>? enabledMarkets;
  final String? displayTzName; // 'UTC' | 'Local'
  final double size;
  final bool showPre;
  final bool showRegular;
  final bool showAfter;

  final double ringPre, ringRegular, ringAfter;

  TradingRadialClock({
    super.key,
    required this.visible,
    List<Market>? markets,
    this.enabledMarkets,
    this.displayTzName,
    this.size = 360,
    this.showPre = true,
    this.showRegular = true,
    this.showAfter = true,
    this.ringPre = 0.72,
    this.ringRegular = 0.60,
    this.ringAfter = 0.84,
  }) : markets = markets ?? defaultMarkets;

  @override
  State<TradingRadialClock> createState() => _TradingRadialClockState();
}

class _TradingRadialClockState extends State<TradingRadialClock> {
  late Timer _t;
  late tz.Location _displayLoc;
  DateTime _nowDisplayNaive = DateTime.now(); // only H:M:S used

  tz.Location _locFromName(String? name) {
    if (name == null || name == 'Local') return tz.local;
    if (name == 'UTC') return tz.getLocation('UTC');
    return tz.getLocation(name);
  }

  void _refreshDisplayLoc() {
    _displayLoc = _locFromName(widget.displayTzName);
  }

  @override
  void initState() {
    super.initState();
    _refreshDisplayLoc();
    _tickNow();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _tickNow());
  }

  @override
  void didUpdateWidget(covariant TradingRadialClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tzChanged = oldWidget.displayTzName != widget.displayTzName;
    if (tzChanged) {
      _refreshDisplayLoc();
      _tickNow(); // refresh immediately
      setState(() {}); // repaint
    } else {
      if (oldWidget.enabledMarkets != widget.enabledMarkets ||
          oldWidget.markets != widget.markets) {
        setState(() {});
      }
    }
  }

  void _tickNow() {
    if (!mounted) return;
    _refreshDisplayLoc(); // read current dropdown selection
    final nd = tz.TZDateTime.now(_displayLoc);
    setState(() {
      _nowDisplayNaive = DateTime(2000, 1, 1, nd.hour, nd.minute, nd.second);
    });
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    final enabled = widget.enabledMarkets ?? const <String, bool>{};
    final selected =
        widget.markets.where((m) => enabled[m.name] == true).toList();
    if (selected.isEmpty) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(
          child: Text('No markets selected',
              style: TextStyle(
                  color: Color(0x66FFFFFF), fontWeight: FontWeight.w600)),
        ),
      );
    }

    final bands = _marketsToRadialBands(
      selected,
      displayLoc: _displayLoc,
      showPre: widget.showPre,
      showRegular: widget.showRegular,
      showAfter: widget.showAfter,
      ringPre: widget.ringPre,
      ringRegular: widget.ringRegular,
      ringAfter: widget.ringAfter,
    );

    return Container(
      decoration: const BoxDecoration(color: kCardDark),
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _WorldClockPainter(now: _nowDisplayNaive, bands: bands),
      ),
    );
  }
}

class _RadialBand {
  final String label;
  final Color color;
  final double ring;
  final double thickness;
  final double startHourLocal; // 0..24 in DISPLAY tz
  final double endHourLocal; // 0..24 in DISPLAY tz
  final bool wraps;
  const _RadialBand({
    required this.label,
    required this.color,
    required this.ring,
    required this.thickness,
    required this.startHourLocal,
    required this.endHourLocal,
    required this.wraps,
  });
}

List<_RadialBand> _marketsToRadialBands(
  List<Market> markets, {
  required tz.Location displayLoc,
  required bool showPre,
  required bool showRegular,
  required bool showAfter,
  required double ringPre,
  required double ringRegular,
  required double ringAfter,
}) {
  double ringFor(BandKind k) => switch (k) {
        BandKind.pre => ringPre,
        BandKind.regular => ringRegular,
        BandKind.after => ringAfter,
      };
  bool visible(BandKind k) => switch (k) {
        BandKind.pre => showPre,
        BandKind.regular => showRegular,
        BandKind.after => showAfter,
      };

  final out = <_RadialBand>[];
  for (final m in markets) {
    final marketLoc = tz.getLocation(m.tzName);

    for (final b in m.bands) {
      if (!visible(b.kind)) continue;
      final h = _bandHoursInDisplay(
          band: b, marketLoc: marketLoc, displayLoc: displayLoc);
      final start = h.startH;
      final end = h.endH;
      final wraps = end < start;

      out.add(_RadialBand(
        label: b.showLabel ? m.name : '',
        color: b.color,
        ring: ringFor(b.kind),
        thickness: b.thickness,
        startHourLocal: start,
        endHourLocal: end,
        wraps: wraps,
      ));
    }
  }
  return out;
}

class _WorldClockPainter extends CustomPainter {
  final DateTime now; // naive; only hour/minute used
  final List<_RadialBand> bands;
  _WorldClockPainter({required this.now, required this.bands});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final R = size.shortestSide / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = kBgDark);
    canvas.translate(center.dx, center.dy);

    _drawOuter24Scale(canvas, R);
    _drawMinuteGrid(canvas, R * 0.80);

    for (final b in bands) {
      _drawBand(canvas, R, b);
    }

    // NOW hands + red ref at 12 o’clock
    _drawHands(canvas, R, now);
    canvas.drawCircle(Offset.zero, 5, Paint()..color = Colors.white);
  }

  void _drawOuter24Scale(Canvas canvas, double R) {
    canvas.drawCircle(Offset.zero, R, Paint()..color = kCardDark);

    final tickOuter = R * 0.95;
    final minor = tickOuter - 8;
    final major = tickOuter - 14;
    final tick = Paint()
      ..color = kTick
      ..strokeWidth = 2;

    for (int h = 0; h < 24; h++) {
      final a = _hourToRad(h.toDouble());
      final inner = (h % 3 == 0) ? major : minor;
      canvas.drawLine(
        Offset.fromDirection(a, inner),
        Offset.fromDirection(a, tickOuter),
        tick..strokeWidth = (h % 3 == 0) ? 2.6 : 1.4,
      );

      final labelPos = Offset.fromDirection(a, R * 0.985);
      final tp = TextPainter(
        text: TextSpan(
          text: h == 0 ? '24' : h.toString().padLeft(2, '0'),
          style: const TextStyle(
              color: kNumber, fontSize: 11, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, labelPos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _drawMinuteGrid(Canvas canvas, double ringR) {
    final grid = Paint()
      ..color = kGrid
      ..strokeWidth = 1;
    for (int h = 0; h < 24; h++) {
      for (int i = 1; i < 12; i++) {
        final a = _hourToRad(h + i / 12.0);
        canvas.drawLine(Offset.zero, Offset.fromDirection(a, ringR), grid);
      }
    }
  }

  void _drawBand(Canvas canvas, double R, _RadialBand b) {
    if ((b.endHourLocal - b.startHourLocal).abs() < 0.01) return;

    final bandR = R * b.ring;
    final rect = Rect.fromCircle(center: Offset.zero, radius: bandR);

    void arcSolid(double sHour, double eHour) {
      const gapDeg = 6.0;
      final gapH = (gapDeg / 360.0) * 24.0;
      final sTrim = sHour + gapH;
      final eTrim = eHour - gapH;
      if (eTrim <= sTrim) return;

      final start = _hourToRad(sTrim);
      final end = _hourToRad(eTrim);
      final sweep = end - start;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = b.thickness
        ..color = b.color;

      canvas.drawArc(rect, start, sweep, false, p);

      if (b.label.isNotEmpty) {
        final mid = start + sweep / 2;
        final pos = Offset.fromDirection(mid, bandR);
        final tp = TextPainter(
          text: TextSpan(text: b.label.toUpperCase(), style: kBandLabel),
          textDirection: TextDirection.ltr,
        )..layout();
        final pill = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: pos, width: tp.width + 16, height: tp.height + 8),
          const Radius.circular(999),
        );
        final pillBg = Paint()..color = b.color;
        canvas.drawRRect(pill, pillBg);
        tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
      }
    }

    if (b.wraps) {
      arcSolid(b.startHourLocal, 24);
      arcSolid(0, b.endHourLocal);
    } else {
      arcSolid(b.startHourLocal, b.endHourLocal);
    }
  }

  void _drawHands(Canvas canvas, double R, DateTime now) {
    final h = (now.hour % 12) + now.minute / 60.0;
    final m = now.minute + now.second / 60.0;
    final hourA = (2 * pi) * (h / 12.0) - pi / 2;
    final minA = (2 * pi) * (m / 60.0) - pi / 2;

    final hourPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final minPaint = Paint()
      ..color = kNumber
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
        Offset.zero, Offset.fromDirection(hourA, R * 0.60), hourPaint);
    canvas.drawLine(
        Offset.zero, Offset.fromDirection(minA, R * 0.85), minPaint);

    // Red reference line at 12 o'clock
    canvas.drawLine(
        Offset.zero,
        Offset(0, -R * 0.92),
        Paint()
          ..color = kNowLine
          ..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(covariant _WorldClockPainter old) =>
      old.now.minute != now.minute || old.bands != bands;
}

double _hourToRad(double hour24) {
  final frac = (hour24 % 24) / 24.0;
  return (2 * pi * frac) - pi / 2;
}

/// =====================
/// TAPE CLOCK (centered; drag to scroll)
/// =====================
class TapeClockCentered extends StatefulWidget {
  final List<Market> markets;
  final Map<String, bool>? enabled;
  final String? displayTzName; // 'UTC' | 'Local'
  final double height;
  final EdgeInsets padding;

  /// Fixed left column reserved for the per-band mini info
  final double infoGutter; // px
  final Duration snapBackDelay;
  final Duration snapDuration;
  final bool autoHeight;
  final double minHeight;

  /// Total hours visible across the tape (constant regardless of widget width).
  /// Smaller value -> larger scale (less compressed). 16 is a nice default.
  final double visibleHours;

  TapeClockCentered({
    super.key,
    List<Market>? markets,
    this.enabled,
    this.displayTzName,
    this.height = 160,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.infoGutter = 400,
    this.snapBackDelay = const Duration(seconds: 2),
    this.snapDuration = const Duration(milliseconds: 800),
    this.autoHeight = false,
    this.minHeight = 80,
    this.visibleHours = 24.0,
  }) : markets = markets ?? defaultMarkets;

  @override
  State<TapeClockCentered> createState() => _TapeClockCenteredState();
}

class _LaneData {
  final String marketName;
  // Deprecated single-line mini; kept for compatibility
  final String miniInfo;
  final List<_Seg> segs;
  // New: single next event across all bands (what you asked for)
  final String infoNext;
  _LaneData(this.marketName, this.miniInfo, this.segs, this.infoNext);
}

class _TapeClockCenteredState extends State<TapeClockCentered>
    with SingleTickerProviderStateMixin {
  late Timer _timer;
  late tz.Location _displayLoc;
  late List<_LaneData> _lanes;

  // One reused controller (fixes multiple ticker errors)
  late final AnimationController _anim;
  Animation<double>? _animTween;
  Timer? _snapTimer;

  int _weekdayDisplay = DateTime.now().weekday; // 1=Mon..7=Sun in DISPLAY tz

  double _nowHour = 0.0; // display time hour-of-day
  double _hourOffset = 0.0; // drag offset in hours

  tz.Location _locFromName(String? name) {
    if (name == null || name == 'Local') return tz.local;
    if (name == 'UTC') return tz.getLocation('UTC');
    return tz.getLocation(name);
  }

  void _refreshDisplayLoc() {
    _displayLoc = _locFromName(widget.displayTzName);
  }

  @override
  void initState() {
    super.initState();
    _refreshDisplayLoc();
    _lanes = _buildOrderedLanes(widget.markets, widget.enabled, _displayLoc);

    _anim = AnimationController(vsync: this, duration: widget.snapDuration);
    _anim.addStatusListener((status) {
      // no-op, but present to keep reference if you want to hook completion
    });

    _tickNow();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tickNow());
  }

  @override
  void didUpdateWidget(covariant TapeClockCentered oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tzChanged = oldWidget.displayTzName != widget.displayTzName;
    final enabledChanged =
        oldWidget.enabled.toString() != widget.enabled.toString();
    final marketsChanged = oldWidget.markets != widget.markets;
    final durChanged = oldWidget.snapDuration != widget.snapDuration;

    if (tzChanged) {
      _refreshDisplayLoc();
    }
    if (tzChanged || enabledChanged || marketsChanged) {
      _lanes = _buildOrderedLanes(widget.markets, widget.enabled, _displayLoc);
      _tickNow(); // NOW line reflects new tz immediately
      setState(() {}); // repaint
    }
    if (durChanged) {
      // update controller duration for future snaps
      _anim.duration = widget.snapDuration;
    }
  }

  void _tickNow() {
    if (!mounted) return;
    _refreshDisplayLoc(); // respect current selection on every tick
    final nd = tz.TZDateTime.now(_displayLoc);
    setState(() {
      _nowHour = nd.hour + nd.minute / 60.0 + nd.second / 3600.0;
      _weekdayDisplay = nd.weekday; // keep weekday in the same display tz

      // Also refresh lane mini-info so countdowns & times update as time passes
      _lanes = _buildOrderedLanes(widget.markets, widget.enabled, _displayLoc);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _snapTimer?.cancel();
    if (mounted) {
      _anim.dispose();
    }
    super.dispose();
  }

  void _startSnapBack() {
    _snapTimer?.cancel();
    _snapTimer = Timer(widget.snapBackDelay, () {
      if (!mounted) return;
      // Rebuild tween from current offset to 0 each time
      final curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
      _animTween?.removeListener(_onAnimTick);
      _animTween = Tween<double>(begin: _hourOffset, end: 0.0).animate(curve)
        ..addListener(_onAnimTick);
      _anim.reset();
      _anim.forward();
    });
  }

  void _onAnimTick() {
    if (!mounted) return;
    // Also clamp during animation just in case
    final maxOff = kRepeatDays * 24 - widget.visibleHours / 2;
    setState(() {
      final v = _animTween?.value ?? 0.0;
      _hourOffset = v.clamp(-maxOff, maxOff);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled ?? const <String, bool>{};
    final anyOn = enabled.values.any((v) => v == true);

    if (!anyOn) {
      return Container(
        height: widget.autoHeight ? widget.minHeight : widget.height,
        color: kBgDark,
        alignment: Alignment.center,
        child: const Text('No markets selected',
            style: TextStyle(
                color: Color(0x66FFFFFF), fontWeight: FontWeight.w600)),
      );
    }

    return LayoutBuilder(builder: (_, c) {
      // --- AUTO HEIGHT CALC ---
      double tapeHeight = widget.height;
      if (widget.autoHeight) {
        const laneGap = 15.0;
        const minLaneHeight = 10.0;
        final laneCount = _lanes.length;
        const labelsExtra = 30.0;
        if (laneCount > 0) {
          tapeHeight = widget.padding.vertical +
              laneCount * minLaneHeight +
              (laneCount - 1) * laneGap +
              labelsExtra;
          tapeHeight = tapeHeight.clamp(widget.minHeight, 460.0);
        } else {
          tapeHeight = widget.minHeight;
        }
      }
      // ------------------------

      return GestureDetector(
        onHorizontalDragStart: (_) {
          _snapTimer?.cancel();
          if (_anim.isAnimating) _anim.stop();
        },
        onHorizontalDragUpdate: (details) {
          // tape width excludes the left info gutter
          final pxPerHour =
              (c.maxWidth - widget.padding.horizontal - widget.infoGutter) /
                  widget.visibleHours;
          final next = _hourOffset - details.delta.dx / pxPerHour;
          // Hard limit: never scroll beyond what we render (±kRepeatDays)
          final maxOff = kRepeatDays * 24 - widget.visibleHours / 2;
          setState(() => _hourOffset = next.clamp(-maxOff, maxOff));
        },
        onHorizontalDragEnd: (_) => _startSnapBack(),
        child: CustomPaint(
          size: Size(c.maxWidth, tapeHeight),
          painter: _CenteredTapePainter(
            lanes: _lanes,
            nowHour: _nowHour,
            padding: widget.padding,
            hourOffset: _hourOffset,
            infoGutter: widget.infoGutter,
            visibleHours: widget.visibleHours,
            weekdayToday: _weekdayDisplay,
            displayLoc: _displayLoc,
          ),
        ),
      );
    });
  }
}

class _Seg {
  double startH, endH; // 0..24 in DISPLAY tz
  Color color;
  double height;
  bool labelHere;
  final String label; // market name (used inside first regular band)
  // Control rounding so split-at-midnight halves meet without a gap
  bool roundLeft = true;
  bool roundRight = true;
  // New: weekday gating
  // Dart weekday: 1=Mon .. 7=Sun, all in the MARKET'S local time.
  final int baseWeekday; // the weekday for "today" in market tz
  final Set<int> tradingWeekdays; // which weekdays this market trades
  final tz.Location marketLoc; // <— needed to convert from display -> market
  _Seg(this.startH, this.endH, this.color, this.height, this.labelHere,
      this.label,
      {this.roundLeft = true,
      this.roundRight = true,
      required this.baseWeekday,
      required this.tradingWeekdays,
      required this.marketLoc});
}

/// Build lanes + one mini-info per market
List<_LaneData> _buildOrderedLanes(
  List<Market> markets,
  Map<String, bool>? enabled,
  tz.Location displayLoc,
) {
  final enabledMap = enabled ?? const <String, bool>{};

  final perMarket = <String, List<_Seg>>{};
  final earliest = <String, double>{};
  final infos = <String, String>{};

  for (final m in markets) {
    if (enabledMap[m.name] != true) continue;

    final marketLoc = tz.getLocation(m.tzName);
    final todayM = tz.TZDateTime.now(marketLoc);
    final baseWeekday = todayM.weekday; // 1..7 in MARKET TZ
    final segs = <_Seg>[];
    double? firstStart;

    for (final b in m.bands) {
      final hh = _bandHoursInDisplay(
          band: b, marketLoc: marketLoc, displayLoc: displayLoc);
      var s = hh.startH;
      var e = hh.endH;

      firstStart ??= s;

      // --- FIX: normalize exact-midnight end so it doesn't wrap ---
      const eps = 1e-6;
      if (e < s && e.abs() < eps) {
        // e == 0.0 (within tolerance) means the band ends exactly at 00:00
        // Draw as [s..24] with rounded caps (i.e., not a wrap).
        e = 24.0;
      }
      // optional: drop true zero-length leftovers (s == e)
      if ((e - s).abs() < eps) continue;
      // ------------------------------------------------------------

      if (e < s) {
        // real wrap across midnight -> split into two halves,
        // inner corners square so they meet cleanly.
        segs.add(_Seg(
          s,
          24,
          b.color,
          b.thickness,
          b.showLabel,
          m.name,
          roundRight: false,
          baseWeekday: baseWeekday,
          tradingWeekdays: m.tradingWeekdays,
          marketLoc: marketLoc,
        ));
        segs.add(_Seg(
          0,
          e,
          b.color,
          b.thickness,
          false,
          m.name,
          roundLeft: false,
          baseWeekday: baseWeekday,
          tradingWeekdays: m.tradingWeekdays,
          marketLoc: marketLoc,
        ));
      } else {
        segs.add(_Seg(
          s,
          e,
          b.color,
          b.thickness,
          b.showLabel,
          m.name,
          baseWeekday: baseWeekday,
          tradingWeekdays: m.tradingWeekdays,
          marketLoc: marketLoc,
        ));
      }
    }

    if (segs.isNotEmpty) {
      perMarket[m.name] = segs;
      earliest[m.name] = firstStart ?? 24.0;
      // keep legacy single-line mini (unused now)
      infos[m.name] = _currentBandInfo(m, displayLoc);
    }
  }

  final orderedNames = earliest.keys.toList()
    ..sort((a, b) => earliest[a]!.compareTo(earliest[b]!));

  final lanes = <_LaneData>[];
  for (final name in orderedNames) {
    final mkt = markets.firstWhere((m) => m.name == name);
    // Compute the single next event over ALL bands (open/close)
    final nextOne = _nextEventText(mkt, displayLoc);

    lanes.add(_LaneData(
      name,
      infos[name] ?? '',
      perMarket[name]!,
      nextOne,
    ));
  }
  return lanes;
}

class _CenteredTapePainter extends CustomPainter {
  final List<_LaneData> lanes;
  final double nowHour; // display-zone hour-of-day
  final EdgeInsets padding;
  final double hourOffset;
  final double infoGutter;
  final double visibleHours;
  final int weekdayToday; // 1=Mon..7=Sun in display tz
  final tz.Location displayLoc; // <— we need this to build display datetimes

  _CenteredTapePainter({
    required this.lanes,
    required this.nowHour,
    required this.padding,
    required this.hourOffset,
    required this.infoGutter,
    required this.visibleHours,
    required this.weekdayToday,
    required this.displayLoc,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // background
    canvas.drawRect(Offset.zero & size, Paint()..color = kBgDark);

    final top = padding.top;

    final bottom = size.height - padding.bottom * 2;
    // text is painted in [leftText .. leftText+infoGutter]
    final leftText = padding.left;
    // tape (grid + bands) start AFTER the info gutter:
    final left = padding.left;
    final right = size.width - padding.right;
    final width = (right - left).clamp(40.0, double.infinity);
    final height = (bottom - top).clamp(40.0, double.infinity);

    // Pixels per hour: constant hour span regardless of width.
    final spanHours = visibleHours; // total hours across the tape
    final pph = width / spanHours;
    // Center the time axis on the FULL canvas width (so the red line is centered),
    // not just within the tape area. Bands/labels will still be clipped by `left..right`.
    final tapeCenterX = (size.width) / 2.0;
    // Helpful locals
    double xForHour(double h) => tapeCenterX + pph * (h - nowHour - hourOffset);
    final nowX = xForHour(nowHour);

    // hour grid + labels
    final gridPaint = Paint()
      ..color = kGrid
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(
        color: kNumber, fontSize: 11, fontWeight: FontWeight.w700);
    final labelTp = TextPainter(textDirection: TextDirection.ltr);

    // Show +/- spanHours/2 around "now" so total == spanHours
    final halfSpan = spanHours / 2.0;
    final startTick = (nowHour + hourOffset - halfSpan).floor();
    final endTick = (nowHour + hourOffset + halfSpan).ceil();

    for (int h = startTick; h <= endTick; h++) {
      final x = xForHour(h.toDouble());
      // draw tick only if it's inside the tape area
      if (x < left || x > right) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), gridPaint);
    }

    // lane sizing
    final laneArea = height - (max(0, lanes.length - 1));
    final laneHeight = lanes.isEmpty ? 0.0 : laneArea / max(1, lanes.length);
    // final laneHeight = max(minLaneHeight, computedLaneH);

    // Left mini-info text style (less bold, slightly smaller)
    final miniInfoStyle = const TextStyle(
      color: Colors.white,
      fontSize: 14,
      height: 1.1,
    );

    // draw segments
    for (int i = 0; i < lanes.length; i++) {
      final yTop = top + i * (laneHeight);
      final cy = yTop + laneHeight / 2;
      // Collect visible band spans for this lane; we'll choose one for the single label
      final bandSpans = <({double leftX, double rightX, Color color})>[];
      final laneLabel = lanes[i].marketName.toUpperCase();

      // Prepare ONE mini-info line: the next event across all bands
      final String text = lanes[i].infoNext;
      final double colWidth = infoGutter - 16.0; // tiny extra padding
      final prepared = <({TextPainter tp, double dy})>[];
      if (text.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: miniInfoStyle),
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
          ellipsis: '…',
        )..layout(maxWidth: colWidth);
        prepared.add((tp: tp, dy: cy)); // center vertically in the lane
      }

      for (final seg in lanes[i].segs) {
        void drawSeg(double shift, int kDays) {
          // Representative instant for THIS periodic copy in DISPLAY tz:
          final nowD = tz.TZDateTime.now(displayLoc);
          final displayMidnight =
              tz.TZDateTime(displayLoc, nowD.year, nowD.month, nowD.day);
          final midHour = ((seg.startH + seg.endH) / 2.0) + shift; // hours
          final midDisplay =
              displayMidnight.add(Duration(minutes: (midHour * 60).round()));
          // Convert that instant to the MARKET tz and gate by its weekday
          final midMarket = tz.TZDateTime.from(midDisplay, seg.marketLoc);
          if (!seg.tradingWeekdays.contains(midMarket.weekday)) {
            return; // e.g., NZX Saturday gets filtered even if your local is Friday
          }

          // Screen x for this copy
          final s = xForHour(seg.startH + shift);
          final e = xForHour(seg.endH + shift);
          final leftX = min(s, e);
          final rightX = max(s, e);

          final h = min(seg.height, laneHeight);

          // Default: rounded caps.
          bool effRoundLeft = true;
          bool effRoundRight = true;

          // If this edge is an *inner* midnight edge (flag == false)
          // keep it SQUARE only when the seam is actually visible.
          if (!seg.roundLeft) {
            final seamX = (s < e) ? leftX : rightX; // start edge
            if (seamX >= left && seamX <= right) effRoundLeft = false;
          }
          if (!seg.roundRight) {
            final seamX = (s < e) ? rightX : leftX; // end edge
            if (seamX >= left && seamX <= right) effRoundRight = false;
          }

          final r = Radius.circular(10);
          final rr = RRect.fromRectAndCorners(
            Rect.fromCenter(
              center: Offset(((leftX + rightX) / 2).toDouble(), cy.toDouble()),
              width: (rightX - leftX).toDouble(),
              height: h.toDouble(),
            ),
            topLeft: effRoundLeft ? r : Radius.zero,
            bottomLeft: effRoundLeft ? r : Radius.zero,
            topRight: effRoundRight ? r : Radius.zero,
            bottomRight: effRoundRight ? r : Radius.zero,
          );
          canvas.drawRRect(rr, Paint()..color = seg.color);

          // Remember this span if any part is on screen; we’ll pick the best one for the label
          if (rightX > left && leftX < right) {
            bandSpans.add((leftX: leftX, rightX: rightX, color: seg.color));
          }
        }

        // Periodic copies every 24h to wrap around the tape.
        // Enough copies to cover any viewport width; keep in sync with clamp.
        for (int k = -kRepeatDays; k <= kRepeatDays; k++) {
          // k = days offset
          drawSeg(k * 24.0, k);
        }
      }

      // ---- Draw ONE lane label (choose the visible band nearest the red line where the pill fits) ----
      if (laneLabel.isNotEmpty && bandSpans.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: laneLabel, style: kBandLabel),
          textDirection: TextDirection.ltr,
        )..layout();
        const hPad = 8.0, vPad = 4.0;
        final pillW = tp.width + 2 * hPad;
        final pillH = tp.height + 2 * vPad;

        // Keep only spans that have enough visible width to fit the pill fully
        final fitting = <({double leftV, double rightV, Color color})>[];
        for (final s in bandSpans) {
          final leftV = math.max(s.leftX, left) + 4; // a little inner margin
          final rightV = math.min(s.rightX, right) - 4;
          if (rightV - leftV >= pillW) {
            fitting.add((leftV: leftV, rightV: rightV, color: s.color));
          }
        }

        if (fitting.isNotEmpty) {
          // Choose the span whose center is closest to the red NOW line
          fitting.sort((a, b) {
            final ac = (a.leftV + a.rightV) / 2;
            final bc = (b.leftV + b.rightV) / 2;
            return (ac - nowX).abs().compareTo((bc - nowX).abs());
          });
          final best = fitting.first;
          final halfW = pillW / 2;
          final cx = nowX.clamp(best.leftV + halfW, best.rightV - halfW);
          final pill = RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, cy),
              width: pillW,
              height: pillH,
            ),
            const Radius.circular(999),
          );
          canvas.drawRRect(pill,
              Paint()..color = fitting.first.color.withValues(alpha: 0.95));
          tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
        }
      }

      // Paint mini-infos LAST with a darker, more opaque pill background
      const bgColor = Color(0xE60F1620); // ~90% opaque
      for (final item in prepared) {
        final tp = item.tp;
        final dy = item.dy;
        final bg = RRect.fromRectAndRadius(
          Rect.fromLTWH(leftText - 6, dy - tp.height / 2 - 4, tp.width + 14,
              tp.height + 8),
          const Radius.circular(8),
        );
        canvas.drawRRect(bg, Paint()..color = bgColor);
        tp.paint(canvas, Offset(leftText + 2, dy - tp.height / 2));
      }
    }

    // NOW line (bright red), drawn last so it's on top
    canvas.drawLine(
      Offset(nowX, top - 2),
      Offset(nowX, bottom),
      Paint()
        ..color = kNowLine
        ..strokeWidth = 2,
    );

    // Clear the label strips (hours + days) and draw faint dividers
    const hourStripH = 16.0;
    const dayStripH = 16.0;
    canvas.drawRect(
      Rect.fromLTWH(0, bottom, size.width, hourStripH + dayStripH),
      Paint()..color = kBgDark,
    );
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = kGrid
        ..strokeWidth = 1,
    );

    // Divider between hours and days
    canvas.drawLine(
        Offset(0, bottom + hourStripH),
        Offset(size.width, bottom + hourStripH),
        Paint()
          ..color = kGrid
          ..strokeWidth = 1);

    // Finally paint hour LABELS centered in the strip
    for (int h = startTick; h <= endTick; h++) {
      final hh = (h % 24 + 24) % 24;
      final x = xForHour(h.toDouble());
      labelTp.text =
          TextSpan(text: hh.toString().padLeft(2, '0'), style: labelStyle);
      labelTp.layout();

      // draw label only when it fully fits inside the tape area
      final halfW = labelTp.width / 2;
      if (x - halfW < left || x + halfW > right) continue;

      // place vertically centered in the label strip (16px tall)

      final ly = bottom + (hourStripH - labelTp.height) / 2;
      labelTp.paint(
        canvas,
        Offset(x - halfW, ly),
      );
    }

    // ---- Days of week strip (centered between consecutive midnights) ----
    // Find midnight ticks in the visible range; midnights occur at hours ...,-24,0,24,48,...
    // We’ll label the segment between midnight_k and midnight_{k+1} with the appropriate weekday.
    final dayStyle = const TextStyle(
      color: kNumber,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );
    final dayTp = TextPainter(textDirection: TextDirection.ltr);

    // First midnight <= endTick and >= startTick-24 to cover edges
    int firstMidnight = (startTick / 24).floor() * 24;
    // Iterate midnights; draw labels for segments fully/partially visible
    for (int mH = firstMidnight; mH <= endTick + 24; mH += 24) {
      final x0 = xForHour(mH.toDouble());
      final x1 = xForHour((mH + 24).toDouble());
      // Skip segments fully off-screen
      final segLeft = math.min(x0, x1);
      final segRight = math.max(x0, x1);
      if (segRight < left || segLeft > right) continue;

      // Determine weekday name for the segment starting at mH.
      // mH==0 corresponds to "today" (weekdayToday). Positive mH -> future, negative -> past.
      final dayOffset = ((mH / 24).round()); // in whole days relative to today
      int wd = ((weekdayToday - 1 + dayOffset) % 7);
      if (wd < 0) wd += 7;
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final name = names[wd];

      // Center the label within the visible part of the segment
      final visL = math.max(segLeft, left) + 4;
      final visR = math.min(segRight, right) - 4;
      if (visR <= visL) continue;
      dayTp.text = TextSpan(text: name, style: dayStyle);
      dayTp.layout();
      final cx = ((visL + visR) / 2)
          .clamp(visL + dayTp.width / 2, visR - dayTp.width / 2);
      final ly = bottom + hourStripH + (dayStripH - dayTp.height) / 2;
      dayTp.paint(canvas, Offset(cx - dayTp.width / 2, ly));
    }
  }

  @override
  bool shouldRepaint(covariant _CenteredTapePainter old) {
    try {
      return old.lanes != lanes ||
          (old.nowHour - nowHour).abs() > 1e-6 ||
          old.hourOffset != hourOffset ||
          old.padding != padding ||
          old.infoGutter != infoGutter;
      // visibleHours changes are handled via layout; weekdayToday affects labels only
    } catch (_) {
      return true;
    }
  }
}
