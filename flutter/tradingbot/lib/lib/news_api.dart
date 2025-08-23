import 'dart:async';
import 'dart:convert';
import 'dart:html'
    as html; // Flutter Web; for desktop/mobile use EventSource pkg
import 'package:http/http.dart' as http;

class IbNewsItem {
  /// symbol can be null on provider-wide headlines
  final String? symbol;
  final String provider,
      articleId,
      headline,
      time,
      scope; // scope: 'provider' | 'symbol'
  final int ts;
  IbNewsItem(
    this.symbol,
    this.provider,
    this.articleId,
    this.headline,
    this.time,
    this.ts,
    this.scope,
  );
  factory IbNewsItem.fromJson(Map<String, dynamic> j) => IbNewsItem(
        j['symbol'] as String?,
        j['provider'] ?? '',
        j['articleId'] ?? '',
        j['headline'] ?? '',
        j['time'] ?? '',
        (j['ts'] ?? 0) as int,
        j['scope'] ?? 'symbol',
      );
}

class IbNewsApi {
  final String base; // '' for same origin, e.g. your FastAPI host
  IbNewsApi({this.base = ''});

  Future<Map<String, String>> providers() async {
    final r = await http.get(Uri.parse('$base/ibkr/news/providers'));
    if (r.statusCode >= 300) return {};
    final list = (json.decode(r.body) as List).cast<Map<String, dynamic>>();
    return {for (final p in list) (p['code'] as String): (p['name'] as String)};
  }

  /// Subscribe to provider-wide and/or per-symbol mode.
  /// At least one of [symbols] or [providers] must be non-empty.
  Future<bool> subscribe(List<String> symbols,
      {List<String>? providers}) async {
    final body = {
      'symbols': symbols,
      if (providers != null) 'providers': providers
    };
    final r = await http.post(
      Uri.parse('$base/ibkr/news/subscribe'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    return r.statusCode < 300;
  }

  Future<bool> unsubscribe(List<String> symbols) async {
    final r = await http.post(
      Uri.parse('$base/ibkr/news/unsubscribe'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'symbols': symbols}),
    );
    return r.statusCode < 300;
  }

  /// Unsubscribe providers
  Future<bool> unsubscribeProviders(List<String> providers) async {
    final r = await http.post(
      Uri.parse('$base/ibkr/news/unsubscribe'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'providers': providers}),
    );
    return r.statusCode < 300;
  }

  /// One-shot quote (for Quick Buy button)
  Future<Map<String, dynamic>> quote(String symbol) async {
    final r = await http.get(Uri.parse('$base/ibkr/quote?symbol=$symbol'));
    if (r.statusCode >= 300) {
      throw Exception('quote failed ${r.body}');
    }
    return json.decode(r.body) as Map<String, dynamic>;
  }

  Stream<IbNewsItem> stream() {
    final es = html.EventSource('$base/ibkr/news/stream');
    final ctrl = StreamController<IbNewsItem>();
    es.addEventListener('news', (html.Event e) {
      final de = e as html.MessageEvent;
      final data = json.decode(de.data as String) as Map<String, dynamic>;
      ctrl.add(IbNewsItem.fromJson(data));
    });
    es.onError.listen((_) {
      // Optionally handle/retry. For now we just close.
      // ctrl.addError('SSE error');
    });
    // When the stream is cancelled, close the EventSource
    ctrl.onCancel = () => es.close();
    return ctrl.stream;
  }

  Future<Map<String, dynamic>> placeBracket({
    required String symbol,
    required String side, // BUY / SELL
    required double qty,
    required String entryType, // MKT / LMT
    double? limitPrice,
    required double takeProfit, // absolute price
    required double stopLoss, // absolute price
    String tif = 'DAY',
  }) async {
    final body = {
      'symbol': symbol,
      'side': side,
      'qty': qty,
      'entryType': entryType,
      if (limitPrice != null) 'limitPrice': limitPrice,
      'takeProfit': takeProfit,
      'stopLoss': stopLoss,
      'tif': tif,
    };
    final r = await http.post(
      Uri.parse('$base/ibkr/orders/bracket'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (r.statusCode >= 300) {
      throw Exception('bracket failed ${r.body}');
    }
    return json.decode(r.body) as Map<String, dynamic>;
  }
}
