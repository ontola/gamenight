import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme.dart';

class CompanionView extends StatefulWidget {
  final Uri url;
  const CompanionView({super.key, required this.url});

  @override
  State<CompanionView> createState() => _CompanionViewState();
}

class _CompanionViewState extends State<CompanionView> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(GnColors.bg)
    ..loadRequest(widget.url);

  @override
  void didUpdateWidget(CompanionView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _controller.loadRequest(widget.url);
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
