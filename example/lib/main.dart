import 'package:flutter/material.dart';

import 'demo/email_demo_widget.dart';

void main() => runApp(const FlutterHtmlDemoApp());

class FlutterHtmlDemoApp extends StatelessWidget {
  const FlutterHtmlDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_native_html',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
      ),
      home: const EmailDemoWidget(),
    );
  }
}
