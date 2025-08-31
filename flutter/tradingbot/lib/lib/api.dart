import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class Api {
  static String baseUrl = '';

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

  static Future<Map<String, dynamic>> _getObj(String path) async {
    final r = await http.get(_uri(path));
    if (r.statusCode != 200) {
      throw Exception(
          'GET $path -> ${r.statusCode} ${r.reasonPhrase ?? ''} ${r.body}');
    }
    final d = jsonDecode(r.body);
    if (d is! Map<String, dynamic>) throw Exception('Expected object');
    return d;
  }

  static Future<List<dynamic>> _getList(String path) async {
    final r = await http.get(_uri(path));
    if (r.statusCode != 200) {
      throw Exception(
          'GET $path -> ${r.statusCode} ${r.reasonPhrase ?? ''} ${r.body}');
    }
    final d = jsonDecode(r.body);
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
      _getObj('/ibkr/accounts');
  static Future<List<dynamic>> ibkrPositions() => _getList('/ibkr/positions');
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
      _getList('/ibkr/orders/open');
  static Future<List<dynamic>> ibkrOrdersHistory({int limit = 200}) =>
      _getList('/ibkr/orders/history?${Uri(queryParameters: {
            'limit': '$limit'
          }).query}');
  static Future<Map<String, dynamic>> ibkrPing() => _getObj('/ibkr/ping');
  static Future<Map<String, dynamic>> ibkrPnlSingle(int conId) => _getObj(
      '/ibkr/pnl/single?${Uri(queryParameters: {'conId': '$conId'}).query}');

  static Future<Map<String, dynamic>> ibkrPnlSummary() =>
      _getObj('/ibkr/pnl/summary');

  static Future<Map<String, dynamic>> ibkrPortfolioSpark(
          {String duration = '1 D', String barSize = '5 mins'}) =>
      _getObj('/ibkr/portfolio/spark?${Uri(queryParameters: {
            'duration': duration,
            'barSize': barSize
          }).query}');

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
