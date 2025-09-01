// lib/ai_placeholder.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Lightweight facade; later you can grow this into full pipelines.
class AIPipeline {
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
}
