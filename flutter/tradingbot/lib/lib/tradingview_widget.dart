import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class TradingViewWidget extends StatefulWidget {
  final String symbol; // e.g. NASDAQ:AAPL or BINANCE:BTCUSDT
  const TradingViewWidget({super.key, required this.symbol});

  @override
  State<TradingViewWidget> createState() => _TradingViewWidgetState();
}

class _TradingViewWidgetState extends State<TradingViewWidget> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      final html = _html(widget.symbol);
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadHtmlString(html,
            baseUrl: Uri.parse('https://s3.tradingview.com/').toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // webview_flutter doesn’t support Flutter Web.
      // (Option: implement an HtmlElementView/iFrame version.)
      return _unsupportedHint();
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: WebViewWidget(controller: _controller!),
    );
  }

  Widget _unsupportedHint() => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF111A2E),
          border: Border.all(color: const Color(0xFF22314E)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'TradingView embed isn’t supported on Flutter Web via webview_flutter.\n'
            'Use an HtmlElementView/iFrame approach for web.',
            textAlign: TextAlign.center,
          ),
        ),
      );

  String _html(String symbol) => '''
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1" />
<style>html,body,#tv {margin:0;padding:0;height:100%;background:#0E1526;}</style>
</head><body>
<div id="tv"></div>
<script src="https://s3.tradingview.com/tv.js"></script>
<script>
  new TradingView.widget({
    "container_id": "tv",
    "symbol": "$symbol",
    "interval": "30",
    "theme": "dark",
    "style": "1",
    "locale": "en",
    "toolbar_bg": "#0E1526",
    "hide_legend": false,
    "hide_top_toolbar": false,
    "hide_side_toolbar": false,
    "allow_symbol_change": false,
    "autosize": true
  });
</script>
</body></html>
''';
}
