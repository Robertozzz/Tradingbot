// lib/app_events.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:tradingbot/lib/api.dart';

/// Lightweight global bus for IBKR order/trade state changes.
class OrderEvents {
  OrderEvents._();
  static final OrderEvents instance = OrderEvents._();

  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _ctrl.stream;

  void emit(Map<String, dynamic> event) {
    if (!_ctrl.isClosed) _ctrl.add(event);
  }

  // --- Global SSE wiring (single subscription + auto-reconnect) ---
  StreamSubscription<SSEModel>? _sseSub;
  Timer? _reconnectTimer;
  bool _started = false;
  int _retries = 0;

  /// Call once on app start (e.g., in your root widget initState).
  void ensureStarted() {
    if (_started) return;
    _started = true;
    _connect();
  }

  void _connect() {
    // Cancel any previous sub just in case
    _sseSub?.cancel();
    _sseSub = SSEClient.subscribeToSSE(
      url: '${Api.baseUrl}/ibkr/orders/stream',
      method: SSERequestType.GET,
      header: const {'Accept': 'text/event-stream'},
    ).listen((evt) {
      final data = evt.data;
      if (data == null || data.isEmpty) return;
      try {
        final m = Map<String, dynamic>.from(jsonDecode(data) as Map);
        emit(m); // fan-out to the whole app
      } catch (_) {
        // ignore malformed events
      }
    }, onError: (_) {
      _scheduleReconnect();
    }, onDone: () {
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    final ms = (math.min(30, 1 << _retries)) * 500; // 0.5s,1s,2s,... up to 15s
    _reconnectTimer = Timer(Duration(milliseconds: ms), () {
      _reconnectTimer = null;
      _retries = math.min(_retries + 1, 10);
      _connect();
    });
  }

  void dispose() {
    _ctrl.close();
    _sseSub?.cancel();
    _reconnectTimer?.cancel();
  }
}
