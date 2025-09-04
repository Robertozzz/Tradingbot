import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class Api {
  static String baseUrl = '';
  // -------- simple in-memory last-known caches (for instant UI) ------------
  static Map<String, dynamic>? lastBootstrap;
  static Map<String, dynamic>? lastAccounts;
  static List<dynamic>? lastPositions;
  static List<dynamic>? lastOpenOrders;
  static Map<String, dynamic>? lastPnlSummary;
  static final Map<String, _Memo> _memo = {};
  static const _memoTtl = Duration(seconds: 5);

  static Uri _uri(String path) {
    final p = path.startsWith('/') ? path : '/$path';
    if (baseUrl.isEmpty) {
      // Relative (works when your Flutter Web/app is reverse-proxied with the API)
      return Uri.parse(p);
    }
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$root$p');
  }

  // Bootstrap snapshot from backend engine (offline-friendly)
  static Future<Map<String, dynamic>> bootstrap({bool refresh = false}) async {
    if (!refresh && lastBootstrap != null) return lastBootstrap!;
    final d = await _getObj('/api/bootstrap');
    lastBootstrap = d;
    // opportunistically seed other caches if present
    if (d['accounts'] is Map<String, dynamic>) {
      lastAccounts = Map<String, dynamic>.from(d['accounts']);
    }
    if (d['positions'] is List) {
      lastPositions = List<dynamic>.from(d['positions']);
    }
    return d;
  }

  static String _memoKey(String path) => 'GET $path';

  /// Absolute URL for SSE endpoints when a package needs a string.
  static String sseUrl(String path) {
    final p = path.startsWith('/') ? path : '/$path';
    if (baseUrl.isEmpty) return p; // relative
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$root$p';
  }

  /// IBKR tick-by-tick SSE (bid/ask, last, midpoint).
  /// Use with your SSE client (e.g. EventSource) in the UI.
  /// Example: EventSource(Api.ibkrTicksStreamUrl(conId: 12345, types: 'bidask,last'))
  static String ibkrTicksStreamUrl(
      {required int conId, String types = 'bidask,last'}) {
    final qp = Uri(queryParameters: {'conId': '$conId', 'types': types}).query;
    return sseUrl('/ibkr/ticks/stream?$qp');
  }

  static Future<Map<String, dynamic>> _getObj(String path) async {
    // tiny 5s memo for hot endpoints to prevent stampedes
    final k = _memoKey(path);
    final now = DateTime.now();
    final hit = _memo[k];
    if (hit != null && now.isBefore(hit.expires)) {
      final d = jsonDecode(hit.body);
      if (d is Map<String, dynamic>) return d;
    }
    final r =
        await http.get(_uri(path), headers: {'Accept': 'application/json'});
    if (r.statusCode != 200) {
      throw Exception(
          'GET $path -> ${r.statusCode} ${r.reasonPhrase ?? ''} ${r.body}');
    }
    final d = jsonDecode(r.body);
    _memo[k] = _Memo(r.body, now.add(_memoTtl));
    if (d is! Map<String, dynamic>) throw Exception('Expected object');
    return d;
  }

  static Future<List<dynamic>> _getList(String path) async {
    final k = _memoKey(path);
    final now = DateTime.now();
    final hit = _memo[k];
    if (hit != null && now.isBefore(hit.expires)) {
      final d = jsonDecode(hit.body);
      if (d is List) return d;
    }
    final r =
        await http.get(_uri(path), headers: {'Accept': 'application/json'});
    if (r.statusCode != 200) {
      throw Exception(
          'GET $path -> ${r.statusCode} ${r.reasonPhrase ?? ''} ${r.body}');
    }
    final d = jsonDecode(r.body);
    _memo[k] = _Memo(r.body, now.add(_memoTtl));
    if (d is! List) throw Exception('Expected list');
    return d;
  }

  // --- Demo assets endpoint used by AssetsPage ---
  static Future<Map<String, dynamic>> assets() => _getObj('/api/assets');

  // --- Dashboard summary endpoint ---
  static Future<Map<String, dynamic>> summary() =>
      _getObj('/api/portfolio/summary');

  // --- IBKR endpoints ---
  static Future<Map<String, dynamic>> ibkrAccounts() =>
      _getObj('/ibkr/accounts').then((m) {
        lastAccounts = m;
        return m;
      });
  static Future<List<dynamic>> ibkrPositions() => _getList('/ibkr/positions');
  static Future<List<dynamic>> ibkrPositionsCached() async {
    // return cached immediately if seeded, then refresh in background
    if (lastPositions != null) {
      // fire-and-forget refresh
      unawaited(
        ibkrPositions()
            // make this chain Future<void> so onError handler can be void
            .then<void>((list) {
          lastPositions = list;
        }).catchError((_) {
          // ignore errors; keep existing cache
        }),
      );
      return lastPositions!;
    }
    final list = await ibkrPositions();
    lastPositions = list;
    return list;
  }

  static Future<List<dynamic>> ibkrSearch(String q) =>
      _getList('/ibkr/search?${Uri(queryParameters: {'q': q}).query}');

  static Future<Map<String, dynamic>> ibkrQuote({
    String? symbol,
    int? conId,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
  }) async {
    final params = <String, String>{};
    if (symbol != null && symbol.isNotEmpty) params['symbol'] = symbol;
    if (conId != null) params['conId'] = '$conId';
    params['secType'] = secType;
    params['exchange'] = exchange;
    params['currency'] = currency;
    final q = Uri(queryParameters: params).query;
    return _getObj('/ibkr/quote?$q');
  }

  static Future<Map<String, dynamic>> ibkrHistory({
    String? symbol,
    int? conId,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
    String duration = '1 D',
    String barSize = '5 mins',
    String what = 'TRADES',
    bool useRTH = true,
  }) async {
    final params = <String, String>{
      'duration': duration,
      'barSize': barSize,
      'what': what,
      'useRTH': useRTH.toString(),
      'secType': secType,
      'exchange': exchange,
      'currency': currency,
    };
    if (symbol != null && symbol.isNotEmpty) params['symbol'] = symbol;
    if (conId != null) params['conId'] = '$conId';
    final q = Uri(queryParameters: params).query;
    return _getObj('/ibkr/history?$q');
  }

  static Future<Map<String, dynamic>> ibkrPlaceBracket({
    String? symbol,
    int? conId,
    required String side,
    required String entryType, // 'MKT' | 'LMT'
    required double qty,
    double? limitPrice,
    required double takeProfit,
    required double stopLoss,
    String tif = 'DAY',
  }) async {
    final body = <String, dynamic>{
      if (symbol != null) 'symbol': symbol,
      if (conId != null) 'conId': conId,
      'side': side,
      'entryType': entryType,
      'qty': qty,
      if (limitPrice != null) 'limitPrice': limitPrice,
      'takeProfit': takeProfit,
      'stopLoss': stopLoss,
      'tif': tif,
    };
    final r = await http.post(_uri('/ibkr/orders/bracket'),
        headers: {'Content-Type': 'application/json'}, body: json.encode(body));
    if (r.statusCode >= 300) {
      throw Exception('bracket failed ${r.body}');
    }
    return json.decode(r.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> ibkrOpenOrders() =>
      _getList('/ibkr/orders/open').then((l) {
        lastOpenOrders = l;
        return l;
      });
  static Future<List<dynamic>> ibkrOrdersHistory({int limit = 200}) =>
      _getList('/ibkr/orders/history?${Uri(queryParameters: {
            'limit': '$limit'
          }).query}');
  static Future<Map<String, dynamic>> ibkrPing() => _getObj('/ibkr/ping');
  static Future<Map<String, dynamic>> ibkrPnlSingle(int conId) => _getObj(
      '/ibkr/pnl/single?${Uri(queryParameters: {'conId': '$conId'}).query}');

  static Future<Map<String, dynamic>> ibkrPnlSummary() =>
      _getObj('/ibkr/pnl/summary').then((m) {
        lastPnlSummary = m;
        return m;
      });

  static Future<Map<String, dynamic>> ibkrPortfolioSpark(
          {String duration = '1 D', String barSize = '5 mins'}) =>
      _getObj('/ibkr/portfolio/spark?${Uri(queryParameters: {
            'duration': duration,
            'barSize': barSize
          }).query}');

  /// Fetch server-side pretty names as a normalized Map<String,String>.
  /// Server may return "CID:123"/"SYM:AAPL" or raw "123"/"AAPL"; we normalize to strings.
  static Future<Map<String, String>> ibkrNames() async {
    final d = await _getObj('/ibkr/names');
    return d.map((k, v) => MapEntry(k.toString(), (v ?? '').toString()));
  }

  /// Upsert one or more pretty names on the server.
  /// Example body: { "CID:123": "Alphabet Inc", "SYM:AAPL": "Apple Inc" }
  static Future<Map<String, dynamic>> ibkrSetNames(Map<String, String> names) =>
      postJson('/ibkr/names', names);

  // --- Generic JSON POST helper ---
  static Future<Map<String, dynamic>> postJson(
      String path, Map<String, dynamic> body) async {
    final r = await http.post(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(
          'POST $path -> ${r.statusCode} ${r.reasonPhrase ?? ''} ${r.body}');
    }
    final d = jsonDecode(r.body);
    if (d is! Map<String, dynamic>) throw Exception('Expected object');
    return d;
  }

  static Future<List<Map<String, dynamic>>> ibkrVerifySymbols(
      List<String> symbols,
      {String secType = 'STK',
      String currency = 'USD',
      String? exchange}) async {
    final body = {
      'symbols': symbols,
      'secType': secType,
      'currency': currency,
      if (exchange != null) 'exchange': exchange,
    };
    final r = await postJson('/ibkr/verify', body);
    final list = (r['verified'] as List?) ?? const [];
    return list
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
        .toList();
  }

// ---- Extra optional endpoints for the debug bundle ----
// Contract detail for a conId or symbol/secType/exchange/currency.
  static Future<Map<String, dynamic>> ibkrContract({
    int? conId,
    String? symbol,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
  }) async {
    final params = <String, String>{
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      'secType': secType,
      'exchange': exchange,
      'currency': currency,
    };
    return _getObj('/ibkr/contract?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Full contract details (minTick, multiplier, trading hours, etc.)
  static Future<Map<String, dynamic>> ibkrContractDetails({
    int? conId,
    String? symbol,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
  }) async {
    final params = <String, String>{
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      'secType': secType,
      'exchange': exchange,
      'currency': currency,
    };
    return _getObj(
        '/ibkr/contract/details?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Full quote (NBBO components, rtVolume, vwap, shortable tier/fee if exposed)
  static Future<Map<String, dynamic>> ibkrQuoteFull({
    String? symbol,
    int? conId,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
  }) async {
    final params = <String, String>{
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      if (conId != null) 'conId': '$conId',
      'secType': secType,
      'exchange': exchange,
      'currency': currency,
    };
    return _getObj('/ibkr/quote/full?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Level 2 / Market depth
  static Future<List<dynamic>> ibkrL2(
      {required int conId, int depth = 10}) async {
    final params = <String, String>{'conId': '$conId', 'depth': '$depth'};
    return _getList('/ibkr/marketdepth?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Live bars stream snapshot (server provides polling/sse -> we expose GET list)
  static Future<List<dynamic>> ibkrLiveBars(
      {required int conId, String barSize = '5 secs'}) async {
    final params = <String, String>{'conId': '$conId', 'barSize': barSize};
    return _getList('/ibkr/livebars?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Option chain metadata for an underlying
  static Future<Map<String, dynamic>> ibkrOptionChain(
      {required int underConId}) async {
    final params = <String, String>{'underConId': '$underConId'};
    return _getObj('/ibkr/options/chain?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Open interest history (futures/options)
  static Future<List<dynamic>> ibkrOpenInterest(
      {required int conId, String duration = '1 M'}) async {
    final params = <String, String>{'conId': '$conId', 'duration': duration};
    return _getList('/ibkr/openinterest?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Corporate actions (splits, etc.)
  static Future<List<dynamic>> ibkrCorpActions(
      {required int conId, int years = 5}) async {
    final params = <String, String>{'conId': '$conId', 'years': '$years'};
    return _getList('/ibkr/corpactions?${Uri(queryParameters: params).query}');
  }

  // ── NEW: News headlines / stories
  static Future<List<dynamic>> ibkrNews(
      {required int conId, int limit = 50}) async {
    final params = <String, String>{'conId': '$conId', 'limit': '$limit'};
    return _getList('/ibkr/news?${Uri(queryParameters: params).query}');
  }

  static Future<Map<String, dynamic>> ibkrNewsStory(
      {required String id}) async {
    final params = <String, String>{'id': id};
    return _getObj('/ibkr/news/story?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Earnings / calendar for symbol
  static Future<Map<String, dynamic>> ibkrEarnings({required int conId}) async {
    final params = <String, String>{'conId': '$conId'};
    return _getObj('/ibkr/earnings?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Dividend accruals specific to instrument
  static Future<Map<String, dynamic>> ibkrDividendAccruals(
      {required int conId}) async {
    final params = <String, String>{'conId': '$conId'};
    return _getObj(
        '/ibkr/dividends/accruals?${Uri(queryParameters: params).query}');
  }

  // ── NEW: What-if / margin preview
  static Future<Map<String, dynamic>> ibkrWhatIf({
    required int conId,
    required String side,
    required String type,
    required double qty,
    double? limitPrice,
  }) async {
    final body = <String, dynamic>{
      'conId': conId,
      'side': side,
      'type': type,
      'qty': qty,
      if (limitPrice != null) 'limitPrice': limitPrice,
    };
    return postJson('/ibkr/whatif', body);
  }

  // ── NEW: Shortability & borrow rate snapshot
  static Future<Map<String, dynamic>> ibkrShortability(
      {required int conId}) async {
    final params = <String, String>{'conId': '$conId'};
    return _getObj('/ibkr/shortability?${Uri(queryParameters: params).query}');
  }

  // ── NEW: Realized P&L for a symbol (window)
  static Future<List<dynamic>> ibkrRealizedPnl(
      {required int conId, int days = 365}) async {
    final params = <String, String>{'conId': '$conId', 'days': '$days'};
    return _getList('/ibkr/realizedpnl?${Uri(queryParameters: params).query}');
  }

// Executions/fills (recent). Filter by conId/symbol server-side if possible.
  static Future<List<dynamic>> ibkrExecutions(
      {int? days = 7, int? conId, String? symbol}) async {
    final params = <String, String>{
      if (days != null) 'days': '$days',
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
    };
    return _getList('/ibkr/executions?${Uri(queryParameters: params).query}');
  }

// Transaction history (deposits/withdrawals/dividends/fees...) – account-level.
  static Future<List<dynamic>> ibkrTransactions(
      {int? days = 90, String? type}) async {
    final params = <String, String>{
      if (days != null) 'days': '$days',
      if (type != null && type.isNotEmpty)
        'type': type, // e.g. 'DIVIDEND','FEE'
    };
    return _getList('/ibkr/transactions?${Uri(queryParameters: params).query}');
  }

// Corporate actions / dividends for a given instrument (if your backend supports it).
  static Future<List<dynamic>> ibkrDividends(
      {int? conId, String? symbol, int? years = 3}) async {
    final params = <String, String>{
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      if (years != null) 'years': '$years',
    };
    return _getList('/ibkr/dividends?${Uri(queryParameters: params).query}');
  }

// Tax lots / average price lots for a position (when available).
  static Future<List<dynamic>> ibkrTaxLots({required int conId}) async {
    return _getList(
        '/ibkr/taxlots?${Uri(queryParameters: {'conId': '$conId'}).query}');
  }

// Option greeks / model (no-op for non-derivatives).
  static Future<Map<String, dynamic>> ibkrGreeks({required int conId}) async {
    return _getObj(
        '/ibkr/greeks?${Uri(queryParameters: {'conId': '$conId'}).query}');
  }

// Fundamentals (snapshot/ratios/financials…). Report can be 'snapshot' | 'ratios' | 'financials'.
  static Future<Map<String, dynamic>> ibkrFundamentals({
    int? conId,
    String? symbol,
    String report = 'snapshot',
  }) async {
    final params = <String, String>{
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      'report': report,
    };
    return _getObj('/ibkr/fundamentals?${Uri(queryParameters: params).query}');
  }

// Executions vs. orders history separation (optional, if you want raw fills in addition to executions).
  static Future<List<dynamic>> ibkrFills(
      {int? days = 7, int? conId, String? symbol}) async {
    final params = <String, String>{
      if (days != null) 'days': '$days',
      if (conId != null) 'conId': '$conId',
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
    };
    return _getList('/ibkr/fills?${Uri(queryParameters: params).query}');
  }

  static Future<Map<String, dynamic>> ibkrPlaceOrder({
    String? symbol,
    int? conId,
    String secType = 'STK',
    String exchange = 'SMART',
    String currency = 'USD',
    required String side, // BUY/SELL
    required String type, // MKT/LMT
    required num qty,
    num? limitPrice,
    String tif = 'DAY',
  }) async {
    final payload = <String, dynamic>{
      if (symbol != null && symbol.isNotEmpty) 'symbol': symbol,
      if (conId != null) 'conId': conId,
      'secType': secType,
      'exchange': exchange,
      'currency': currency,
      'side': side,
      'type': type,
      'qty': qty,
      if (limitPrice != null) 'limitPrice': limitPrice,
      'tif': tif,
    };
    final r = await http.post(
      _uri('/ibkr/orders/place'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (r.statusCode != 200) {
      throw Exception('POST /ibkr/orders/place -> ${r.statusCode} ${r.body}');
    }
    final d = jsonDecode(r.body);
    return d is Map<String, dynamic> ? d : {'ok': true};
  }

  static Future<void> ibkrCancelOrder(int orderId) async {
    final r = await http.post(_uri('/ibkr/orders/cancel'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'orderId': orderId}));
    if (r.statusCode != 200) throw Exception('cancel -> ${r.statusCode}');
  }

  static Future<Map<String, dynamic>> ibkrReplaceOrder(
      Map<String, dynamic> payload) async {
    final r = await http.post(_uri('/ibkr/orders/replace'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload));
    if (r.statusCode != 200) {
      throw Exception('replace -> ${r.statusCode} ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}

class _Memo {
  final String body;
  final DateTime expires;
  _Memo(this.body, this.expires);
}

// App-wide background refresher so data stays current even if user doesn't navigate.
class AppRefresher {
  static Timer? _t;
  static void start() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        final m = await Api.ibkrAccounts();
        Api.lastAccounts = m;
      } catch (_) {}
      try {
        final l = await Api.ibkrPositions();
        Api.lastPositions = l;
      } catch (_) {}
      try {
        final l = await Api.ibkrOpenOrders();
        Api.lastOpenOrders = l;
      } catch (_) {}
      try {
        final m = await Api.ibkrPnlSummary();
        Api.lastPnlSummary = m;
      } catch (_) {}
    });
  }

  static void stop() {
    _t?.cancel();
    _t = null;
  }
}
