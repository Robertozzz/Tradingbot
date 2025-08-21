import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart' as winwv;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// Web-only factory (HtmlElementView) implemented below
import 'tv_iframe_stub.dart' if (dart.library.html) 'tv_iframe_web.dart';

class TradingViewWidget extends StatefulWidget {
  final String symbol; // e.g. NASDAQ:AAPL or BINANCE:BTCUSDT
  const TradingViewWidget({super.key, required this.symbol});

  @override
  State<TradingViewWidget> createState() => _TradingViewWidgetState();
}

class _TradingViewWidgetState extends State<TradingViewWidget> {
  winwv.WebviewController? _win;
  // Reuse WebView2 per symbol so drawings/layout remain in-memory too.
  static final Map<String, winwv.WebviewController> _winCache = {};

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _initWin();
    }
  }

  Future<void> _initWin() async {
    try {
      // Reuse an existing controller if we already opened this symbol.
      if (_winCache.containsKey(widget.symbol)) {
        _win = _winCache[widget.symbol];
        setState(() {});
        return;
      }

      final w = winwv.WebviewController();

      // Persistent profile so localStorage/cookies stick across instances.
      final supportDir = await getApplicationSupportDirectory();
      final userDataDir = p.join(supportDir.path, 'webview2', 'tradingview');
      // await w.initialize(userDataFolder: userDataDir);

      await w.setBackgroundColor(Colors.transparent);
      await w.setPopupWindowPolicy(winwv.WebviewPopupWindowPolicy.deny);
      await w.loadStringContent(_winHtml(widget.symbol));
      if (!mounted) return;
      _winCache[widget.symbol] = w;
      setState(() => _win = w);
    } catch (_) {
      // leave null → show fallback
    }
  }

  @override
  void didUpdateWidget(covariant TradingViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.symbol == oldWidget.symbol) return;
    if (kIsWeb) {
      // web version rebuilds the HtmlElementView
      setState(() {});
    } else if (defaultTargetPlatform == TargetPlatform.windows &&
        _win != null) {
      // Switch to (or create) the cached controller for the new symbol.
      final cached = _winCache[widget.symbol];
      if (cached != null) {
        setState(() => _win = cached);
      } else {
        _win = null;
        _initWin();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return buildTradingViewIframe(widget.symbol);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      if (_win == null) return const _Hint('WebView2 not ready');
      return winwv.Webview(_win!);
    }
    return const _Hint('Unsupported platform in this demo');
  }

  @override
  void dispose() {
    // _win?.dispose();
    super.dispose();
  }

  String _winHtml(String symbol) {
    final src = _tvEmbedUrl(symbol);
    return '''
      <!doctype html><html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>
          html,body {margin:0;height:100%;background:#0E1526;overflow:hidden;}
          iframe {position:absolute;inset:0;border:0;width:100%;height:100%;}
        </style>
      </head>
      <body>
        <iframe src="$src" allow="clipboard-read; clipboard-write; fullscreen"></iframe>
      </body></html>
    ''';
  }
}

/// Build the official TradingView embed URL (Advanced Chart widget).
String _tvEmbedUrl(String symbol) {
  // Note: autosize=1 makes it fill its iframe. No scrolling.
  final enc = Uri.encodeComponent(symbol);
  final params = {
    'symbol': enc,
    'interval': 'D',
    'theme': 'dark',
    'style': '1',
    'hide_legend': '0',
    'hide_side_toolbar': '0',
    'allow_symbol_change': '0',
    'autosize': '1',
    'locale': 'en',
    'toolbar_bg': 'rgba(14,21,38,1)',
  };
  final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
  return 'https://s.tradingview.com/widgetembed/?$query';
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        color: const Color(0xFF0E1526),
        child: Text(text),
      );
}
