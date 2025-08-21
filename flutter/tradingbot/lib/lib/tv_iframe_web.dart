import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:ui_web' as ui; // web-only
import 'package:web/web.dart' as web;

// Reuse the same DOM nodes so the chart instance isn't recreated on rebuilds.
final Map<String, web.HTMLDivElement> _roots = {};
final Map<String, web.HTMLIFrameElement> _iframes = {};
final Set<String> _registered = {};

Widget buildTradingViewIframe(String symbol) {
  // IMPORTANT: viewType must be stable across rebuilds *and* symbol changes
  // within the same panel. Use a constant key for the panel/widget instance.
  // If you have multiple charts at once, pass in a unique key from the caller.
  final viewType = 'tv-panel'; // or inject one via constructor

  // Register once
  if (!_registered.contains(viewType)) {
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
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'clipboard-read; clipboard-write; fullscreen';

      root.append(ifr);
      _roots[viewType] = root;
      _iframes[viewType] = ifr;
      return root;
    });
    _registered.add(viewType);
  }

  // Update the existing iframe URL instead of creating a new one.
  // If the element hasn’t been created yet, this will be applied on first mount.
  final ifr = _iframes[viewType];
  if (ifr != null) {
    final newSrc = _tvEmbedUrl(symbol);
    if (ifr.src != newSrc) ifr.src = newSrc;
  }

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
