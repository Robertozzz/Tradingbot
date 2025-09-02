// lib/ai_placeholder.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Lightweight facade; later you can grow this into full pipelines.
class AIPipeline {
  /// Fetch current AI settings (to know if keys exist).
  static Future<Map<String, dynamic>> settings() async {
    final r = await http.get(Uri.parse('/api/openai/settings'));
    if (r.statusCode != 200) {
      throw Exception('Settings fetch failed: HTTP ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Ask backend to run a tiny OpenAI test (returns reply text).
  static Future<String> ping([String prompt = 'ping']) async {
    final r = await http.post(
      Uri.parse('/api/openai/test'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'prompt': prompt}),
    );
    if (r.statusCode != 200) {
      throw Exception('Ping failed: HTTP ${r.statusCode}');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['reply'] ?? '').toString();
  }

  /// Real ask used by News page. Prevents call when key is missing.
  static Future<String> ask(String prompt) async {
    final s = await settings();
    final hasKey = (s['has_openai_api_key'] as bool?) ?? false;
    if (!hasKey) {
      throw Exception('OpenAI key not set');
    }
    // Re-use /api/openai/test for now, but it returns a real answer (see openai.py diff).
    final r = await http.post(
      Uri.parse('/api/openai/test'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'prompt': prompt}),
    );
    if (r.statusCode != 200) {
      throw Exception('Ask failed: HTTP ${r.statusCode}');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['reply'] ?? '').toString();
  }
}
