import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'api.dart';

/// App-wide event bus: loads a bootstrap snapshot and then tails SSE updates.
/// First paint is instant (cached from server), then live updates stream in.
class OrderEvents {
  OrderEvents._();
  static final OrderEvents instance = OrderEvents._();

  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _ctrl.stream;

  final ValueNotifier<bool> onlineVN = ValueNotifier<bool>(false);
  bool get online => onlineVN.value;
  final ValueNotifier<DateTime?> lastUpdateVN = ValueNotifier<DateTime?>(null);
  final ValueNotifier<Map<String, dynamic>> snapshotVN =
      ValueNotifier<Map<String, dynamic>>(<String, dynamic>{});

  StreamSubscription<SSEModel>? _sse;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _started = false;

  void ensureStarted() {
    if (_started) return;
    _started = true;
    _loadBootstrap();
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

  Future<void> _loadBootstrap() async {
    try {
      final uri = Uri.parse('${Api.baseUrl}/api/bootstrap');
      final r = await http.get(uri, headers: {
        'Accept': 'application/json',
      });
      if (r.statusCode == 200) {
        final Map<String, dynamic> m =
            jsonDecode(r.body) as Map<String, dynamic>;
        snapshotVN.value = m;
        _ctrl.add({'t': 'snapshot', 'data': m});
        lastUpdateVN.value = DateTime.now();
      }
      // 304 is fine (cached by browser/proxy); no body.
    } catch (_) {
      // ignore; UI will still attach to SSE and show when data arrives
    }
  }

  void _startSse() {
    _sse?.cancel();
    _sse = SSEClient.subscribeToSSE(
      url: '${Api.baseUrl}/sse/updates',
      method: SSERequestType.GET,
      header: const {'Accept': 'text/event-stream'},
    ).listen((evt) {
      // Any event implies connectivity to our backend (not necessarily IBKR)
      if (!onlineVN.value) onlineVN.value = true;
      final data = evt.data;
      if (data == null || data.isEmpty) return;
      try {
        if (evt.event == 'hb') {
          // heartbeat – do nothing
          return;
        }
        if (evt.event == 'snapshot') {
          final Map<String, dynamic> snap =
              (jsonDecode(data) as Map).cast<String, dynamic>();
          snapshotVN.value = snap;
          _ctrl.add({'t': 'snapshot', 'data': snap});
          lastUpdateVN.value = DateTime.now();
          return;
        }
        // Generic/typed events if you later add them (e.g., t=positions, t=pnl)
        final m = Map<String, dynamic>.from(jsonDecode(data) as Map);
        _ctrl.add(m);
        lastUpdateVN.value = DateTime.now();
      } catch (_) {
        // swallow malformed line; continue
      }
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
