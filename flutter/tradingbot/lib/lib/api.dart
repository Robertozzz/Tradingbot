import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;

class Api {
  static String baseUrl = '';

  static Uri _uri(String path) {
    if (kIsWeb) return Uri.parse(path.startsWith('/') ? path : '/$path');
    final base = baseUrl.isEmpty ? 'http://127.0.0.1' : baseUrl;
    return Uri.parse(base + (path.startsWith('/') ? path : '/$path'));
  }

  static Future<Map<String, dynamic>> _getObj(String path) async {
    final r = await http.get(_uri(path));
    if (r.statusCode != 200) throw Exception('GET $path -> ${r.statusCode}');
    final d = jsonDecode(r.body);
    if (d is! Map<String, dynamic>) throw Exception('Expected object');
    return d;
  }

  static Future<List<dynamic>> _getList(String path) async {
    final r = await http.get(_uri(path));
    if (r.statusCode != 200) throw Exception('GET $path -> ${r.statusCode}');
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
}
