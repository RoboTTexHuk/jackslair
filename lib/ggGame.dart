import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'main.dart';

class UnityWebGLApp extends StatelessWidget {
  const UnityWebGLApp({super.key, required this.server});
  final UnityAssetServer server;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unity WebGL (assets)',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: UnityWebGLPage(server: server),
    );
  }
}

class UnityWebGLPage extends StatefulWidget {
  const UnityWebGLPage({super.key, required this.server});
  final UnityAssetServer server;

  @override
  State<UnityWebGLPage> createState() => _UnityWebGLPageState();
}

class _UnityWebGLPageState extends State<UnityWebGLPage> {
  InAppWebViewController? controller;
  double progress = 0;

  @override
  void dispose() {
    widget.server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unityUrl =
    WebUri('http://localhost:${widget.server.port}/unity/index.html');

    return Scaffold(

      body: InAppWebView(
        initialUrlRequest: URLRequest(url: unityUrl),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          useHybridComposition: true,
        ),
        onWebViewCreated: (ctrl) => controller = ctrl,
        onProgressChanged: (_, value) =>
            setState(() => progress = value / 100),
        onConsoleMessage: (_, msg) => debugPrint('WebView console: $msg'),
        onLoadError: (_, url, code, msg) =>
            debugPrint('Load error [$code] $msg for $url'),
      ),
    );
  }
}


