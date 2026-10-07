import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class CompanionView extends StatelessWidget {
  final Uri url;
  const CompanionView({super.key, required this.url});

  static final _registered = <String>{};

  @override
  Widget build(BuildContext context) {
    final type = 'gamenight-companion-$url';
    if (_registered.add(type)) {
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        return web.HTMLIFrameElement()
          ..src = url.toString()
          ..style.border = 'none'
          ..style.width = '100%'
          ..style.height = '100%';
      });
    }
    return HtmlElementView(key: ValueKey(type), viewType: type);
  }
}
