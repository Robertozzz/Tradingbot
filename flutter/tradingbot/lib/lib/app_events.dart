import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'api.dart';

/// Global order/status bus with auto-reconnect and health pings.
class OrderEvents {
  OrderEvents._();
  static final OrderEvents instance = OrderEvents._();

  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _ctrl.stream;

  final ValueNotifier<bool> onlineVN = ValueNotifier<bool>(false);
  bool get online => onlineVN.value;

  StreamSubscription<SSEModel>? _sse;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  void ensureStarted() {
    _startSse();
    _startPing();
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
      try {
        final m = await Api.ibkrPing();
        final c = (m['connected'] == true);
        if (onlineVN.value != c) onlineVN.value = c;
      } catch (_) {
        if (onlineVN.value) onlineVN.value = false;
      }
    });
  }

  void _startSse() {
    _sse?.cancel();
    _sse = SSEClient.subscribeToSSE(
      url: '${Api.baseUrl}/ibkr/orders/stream',
      method: SSERequestType.GET,
      header: const {'Accept': 'text/event-stream'},
    ).listen((evt) {
      // Connected & receiving -> online
      if (!onlineVN.value) onlineVN.value = true;
      final data = evt.data;
      if (data == null || data.isEmpty) return;
      try {
        final m = Map<String, dynamic>.from(jsonDecode(data) as Map);
        _ctrl.add(m);
      } catch (_) {}
    }, onError: (_) {
      // drop to offline and schedule reconnect
      if (onlineVN.value) onlineVN.value = false;
      _scheduleReconnect();
    }, onDone: () {
      if (onlineVN.value) onlineVN.value = false;
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _startSse);
  }

  Future<void> dispose() async {
    await _sse?.cancel();
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _ctrl.close();
  }
}
