import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tradingbot/app_events.dart';

class IbkrStatusChip extends StatefulWidget {
  const IbkrStatusChip({super.key});

  @override
  State<IbkrStatusChip> createState() => _IbkrStatusChipState();
}

class _IbkrStatusChipState extends State<IbkrStatusChip> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: OrderEvents.instance.onlineVN,
      builder: (_, online, __) {
        return ValueListenableBuilder<DateTime?>(
          valueListenable: OrderEvents.instance.lastUpdateVN,
          builder: (_, ts, __) {
            final fmt = (ts == null) ? '—' : DateFormat('HH:mm:ss').format(ts);
            final color =
                online ? const Color(0xFF4CC38A) : const Color(0xFFEF4444);
            final label = online ? 'IBKR Online' : 'IBKR Offline';
            return Chip(
              visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
              avatar: CircleAvatar(backgroundColor: color, radius: 5),
              label: Text('$label • $fmt'),
            );
          },
        );
      },
    );
  }
}
