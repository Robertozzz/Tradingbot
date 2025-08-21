import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:ui_web' as ui; // web-only
import 'package:web/web.dart' as web;

// Simple in-memory cache so each symbol reuses the same DOM subtree.

Widget buildTradingViewIframe(String symbol) {
  // Use a stable viewType per widget instance by hashing the symbol
  final viewType = 'tv-${symbol.hashCode}';

  // Only register once per viewType
  // ignore: undefined_prefixed_name
  ui.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final root = web.HTMLDivElement();
    root.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('background-color', 'transparent')
      ..setProperty('overflow', 'hidden')
      ..setProperty('overscroll-behavior', 'contain');

    final ifr = web.HTMLIFrameElement()
      ..src = _tvEmbedUrl(symbol)
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..allow = 'clipboard-read; clipboard-write; fullscreen';

    root.append(ifr);
    return root;
  });

  // Ensure Flutter overlays don’t steal pointer signals
  return PointerInterceptor(child: HtmlElementView(viewType: viewType));
}

String _tvEmbedUrl(String symbol) {
  final enc = Uri.encodeComponent(symbol);
  final params = {
    'symbol': enc,
    'interval': 'D',
    'theme': 'dark',
    'style': '1',
    'hide_legend': '0',
    'hide_side_toolbar': '0',
    'allow_symbol_change': '0',
    'autosize': '1',
    'locale': 'en',
    'toolbar_bg': 'rgba(14,21,38,1)',
  };
  final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
  return 'https://s.tradingview.com/widgetembed/?$query';
}
