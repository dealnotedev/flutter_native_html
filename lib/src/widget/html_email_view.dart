import 'package:flutter/material.dart';

import '../config/html_render_config.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import '../parsing/html_email_parser.dart';
import '../rendering/html_tree_builder.dart';
import 'fit_to_width.dart';

/// A native (no-WebView) widget that renders an HTML email body.
///
/// Pipeline: parse + sanitize → resolve CSS (inline + `<style>`) → build a
/// Flutter widget tree of paragraphs, lists, tables and inline images. Remote
/// images are blocked by default; links are surfaced through
/// [HtmlRenderConfig.onLinkTap] rather than opened automatically.
///
/// Place it inside a width-bounded parent (e.g. a `ListView`, `Padding`, or
/// `SizedBox`); it sizes its height to content.
class HtmlEmailView extends StatefulWidget {
  const HtmlEmailView({
    super.key,
    required this.html,
    this.config = const HtmlRenderConfig(),
  }) : document = null;

  /// Renders an already parsed/sanitized document. Useful when the host caches
  /// preparation outside frequent widget rebuilds.
  ///
  /// Parsing limits and sanitization are applied by [HtmlEmailParser], not
  /// repeated from [config]. Treat the document DOM as immutable after parsing;
  /// prepare a new document when changing content or its sanitization policy.
  const HtmlEmailView.document({
    super.key,
    required this.document,
    this.config = const HtmlRenderConfig(),
  }) : html = '';

  /// The raw HTML email body.
  final String html;
  final ParsedEmail? document;

  /// Rendering configuration (image policy, link handling, styling, custom
  /// handlers). Defaults to the privacy-first configuration.
  final HtmlRenderConfig config;

  @override
  State<HtmlEmailView> createState() => _HtmlEmailViewState();
}

class _HtmlEmailViewState extends State<HtmlEmailView> {
  ParsedEmail? _parsed;
  String? _parsedSource;
  HtmlTreeBuilder? _builder;
  Widget? _rendered;
  double? _renderedWidth;
  HtmlRenderConfig? _renderedConfig;
  Color? _renderedRootColor;
  String? _renderedFontFamily;
  bool _contentRejected = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Custom handlers can depend on any inherited widget through buildContext,
    // even when the resolved root text colour and config remain unchanged.
    _disposeBuilder();
  }

  @override
  void didUpdateWidget(covariant HtmlEmailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        !identical(oldWidget.document, widget.document) ||
        oldWidget.config.sanitizer != widget.config.sanitizer ||
        oldWidget.config.maxHtmlCharacters != widget.config.maxHtmlCharacters ||
        oldWidget.config.maxDomNodes != widget.config.maxDomNodes ||
        oldWidget.config.maxCssCharacters != widget.config.maxCssCharacters ||
        oldWidget.config.maxCssRules != widget.config.maxCssRules) {
      _parsed = null; // re-parse on next build
      _disposeBuilder();
    }
  }

  @override
  void dispose() {
    _disposeBuilder();
    super.dispose();
  }

  void _disposeBuilder() {
    final builder = _builder;
    if (builder != null) {
      for (final recognizer in builder.recognizers) {
        recognizer.dispose();
      }
      _builder = null;
    }
    _rendered = null;
    _renderedWidth = null;
    _renderedConfig = null;
  }

  ParsedEmail _ensureParsed() {
    final prepared = widget.document;
    if (prepared != null) {
      _contentRejected = false;
      return prepared;
    }
    if (_parsed == null || _parsedSource != widget.html) {
      _contentRejected = widget.html.length > widget.config.maxHtmlCharacters;
      final parser = HtmlEmailParser(
        sanitizer: widget.config.sanitizer,
        maxHtmlCharacters: widget.config.maxHtmlCharacters,
        maxDomNodes: widget.config.maxDomNodes,
        maxCssCharacters: widget.config.maxCssCharacters,
        maxCssRules: widget.config.maxCssRules,
      );
      try {
        _parsed = parser.parse(_contentRejected ? '' : widget.html);
      } on HtmlContentLimitException {
        _contentRejected = true;
        _parsed = HtmlEmailParser(
          sanitizer: widget.config.sanitizer,
          maxDomNodes: 100,
        ).parse('');
      }
      _parsedSource = widget.html;
    }
    return _parsed!;
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _ensureParsed();
    final config = widget.config;

    if (_contentRejected) {
      return Semantics(
        liveRegion: true,
        child: const Text('Email content is too large to render.'),
      );
    }

    final ambient = DefaultTextStyle.of(context).style;
    final rootFontFamily = config.defaultFontFamily ?? ambient.fontFamily;
    final rootStyle = HtmlStyle(
      textDirection: Directionality.of(context),
      fontSize: config.baseFontSize,
      color:
          config.defaultColor ??
          ambient.color ??
          Theme.of(context).textTheme.bodyMedium?.color ??
          const Color(0xFF000000),
      fontFamilies: rootFontFamily != null ? [rootFontFamily] : null,
      lineHeight: 1.35,
    );

    // Resolve against the actual available width so responsive emails adapt:
    // `@media (max-width: N)` rules apply when the layout is narrower than N.
    return LayoutBuilder(
      builder: (_, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        if (_rendered != null &&
            _renderedWidth == width &&
            identical(_renderedConfig, config) &&
            _renderedRootColor == rootStyle.color &&
            _renderedFontFamily == rootFontFamily) {
          return _rendered!;
        }
        final resolver = StyleResolver(
          stylesheet: parsed.stylesheet,
          rootStyle: rootStyle,
          availableWidth: width,
        );

        // Rebuild the tree; release recognizers from the previous build first.
        _disposeBuilder();
        final builder = HtmlTreeBuilder(
          config: config,
          buildContext: context,
          rootStyle: rootStyle,
          resolver: resolver,
        );
        _builder = builder;

        final root = builder.buildRoot(parsed.root);
        // On a narrow viewport, present an oversized (non-responsive) email
        // whole by scaling it to fit, like a mobile mail client. Responsive
        // emails resolve their widths to percentages and normally stay at
        // scale 1; genuinely oversized minimum layouts are shrunk.
        Widget rendered = !config.fitToWidth
            ? root
            : FitToWidth(
                declaredWidthHint: builder.maxDeclaredFixedWidth,
                minScale: config.fitToWidthMinScale,
                child: root,
              );
        if (config.enableTextSelection) {
          rendered = SelectionArea(child: rendered);
        }
        _rendered = rendered;
        _renderedWidth = width;
        _renderedConfig = config;
        _renderedRootColor = rootStyle.color;
        _renderedFontFamily = rootFontFamily;
        return rendered;
      },
    );
  }
}
