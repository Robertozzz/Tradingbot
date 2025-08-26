// lib/app_events.dart
import 'dart:async';

/// Lightweight global bus for IBKR order/trade state changes.
class OrderEvents {
  OrderEvents._();
  static final OrderEvents instance = OrderEvents._();

  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _ctrl.stream;

  void emit(Map<String, dynamic> event) {
    if (!_ctrl.isClosed) _ctrl.add(event);
  }

  void dispose() {
    _ctrl.close();
  }
}
