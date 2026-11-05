import 'package:flutter/material.dart';

import 'demo/email_demo_widget.dart';

void main() => runApp(const FlutterHtmlDemoApp());

class FlutterHtmlDemoApp extends StatefulWidget {
  const FlutterHtmlDemoApp({super.key});

  @override
  State<FlutterHtmlDemoApp> createState() => _FlutterHtmlDemoAppState();
}

class _FlutterHtmlDemoAppState extends State<FlutterHtmlDemoApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_native_html',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: EmailDemoWidget(
        onBrightnessChanged: (brightness) => setState(() {
          _themeMode = brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light;
        }),
      ),
    );
  }
}
