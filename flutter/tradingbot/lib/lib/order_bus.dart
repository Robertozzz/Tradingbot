import 'dart:async';
import 'dart:convert';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter/foundation.dart';
import 'package:tradingbot/lib/api.dart';

/// Singleton that listens to /ibkr/orders/stream once and emits a tick
/// every time any trade/order update arrives (status, fill, cancel, etc).
class OrderBus {
  OrderBus._();
  static final OrderBus instance = OrderBus._();

  /// Increments on every trade event so listeners can refresh cheaply.
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  StreamSubscription<SSEModel>? _sub;

  void start() {
    if (_sub != null) return; // already running
    _sub = SSEClient.subscribeToSSE(
      url: '${Api.baseUrl}/ibkr/orders/stream',
      method: SSERequestType.GET,
      header: const {'Accept': 'text/event-stream'},
    ).listen((evt) {
      // Only count real trade events
      final ev = (evt.event ?? '').toLowerCase();
      if (ev != 'trade') return;
      // Optional: sanity check the payload parses
      try {
        final data = evt.data;
        if (data != null && data.isNotEmpty) {
          jsonDecode(data); // ensure well-formed
        }
      } catch (_) {
        // ignore malformed rows, but still tick
      }
      tick.value = tick.value + 1;
    }, onError: (_) {
      // Network hiccups are fine; the next start() call will resubscribe.
      stop();
      // Optionally auto-retry with a tiny delay:
      Future.delayed(const Duration(seconds: 2), () {
        if (_sub == null) start();
      });
    });
  }

  void stop() {
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
  }
}
