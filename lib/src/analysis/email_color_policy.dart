import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:html/dom.dart' as dom;

import '../config/html_render_config.dart';
import '../css/html_style.dart';
import '../css/style_resolver.dart';
import '../parsing/html_email_parser.dart';

/// A shared decision for rendering and pre-layout analysis at the same width.
class EmailColorPolicy {
  const EmailColorPolicy(this.brightness, {this.adapt = false});

  final Brightness brightness;
  final bool adapt;
  Color get canvas => brightness == Brightness.dark
      ? const Color(0xff181818)
      : const Color(0xffffffff);
  Color get text => brightness == Brightness.dark
      ? const Color(0xffeeeeee)
      : const Color(0xff000000);
}

EmailColorPolicy resolveEmailColorPolicy(
  ParsedEmail document, {
  required double width,
  required HtmlRenderConfig config,
  Brightness brightness = Brightness.light,
}) {
  final preferred = switch (config.colorMode) {
    HtmlEmailColorMode.original => Brightness.light,
    HtmlEmailColorMode.dark => Brightness.dark,
    HtmlEmailColorMode.auto => config.brightness ?? brightness,
  };
  if (preferred == Brightness.light) {
    return const EmailColorPolicy(Brightness.light);
  }

  final base = HtmlStyle(
    fontSize: config.baseFontSize,
    color: const Color(0xff000000),
  );
  final resolver = StyleResolver(
    stylesheet: document.stylesheet,
    rootStyle: base,
    availableWidth: width,
    brightness: Brightness.dark,
  );
  final scheme =
      (resolver.colorSchemeFor(document.root) ?? document.colorScheme ?? '')
          .toLowerCase()
          .split(RegExp(r'\s+'));
  if (scheme.contains('dark')) return const EmailColorPolicy(Brightness.dark);
  var simple = config.handlers.isEmpty;
  var hasText = false;
  final html = document.root.parent;
  if (html != null && document.stylesheet.hasDarkStylesFor(html, width)) {
    return const EmailColorPolicy(Brightness.dark);
  }
  if (html != null && !_simpleStyle(resolver.resolve(html, base))) {
    simple = false;
  }
  final pending = <(dom.Element, HtmlStyle)>[(document.root, base)];
  while (pending.isNotEmpty) {
    final (element, inherited) = pending.removeLast();
    final style = resolver.resolve(element, inherited.inheritedOnly());
    // Visibility itself may be the theme switch (light/dark logo variants).
    if (document.stylesheet.hasDarkStylesFor(element, width)) {
      return const EmailColorPolicy(Brightness.dark);
    }
    if (style.display == CssDisplay.none || style.visibilityHidden == true) {
      continue;
    }
    if (!_simpleStyle(style) ||
        const {'table', 'img', 'picture'}.contains(element.localName)) {
      simple = false;
    }
    for (final child in element.nodes) {
      if (child is dom.Element) {
        pending.add((child, style));
      } else if (child is dom.Text && child.data.trim().isNotEmpty) {
        hasText = true;
      }
    }
  }
  final force = config.colorMode == HtmlEmailColorMode.dark;
  final onlyLight = scheme.contains('only') && scheme.contains('light');
  if (force || (simple && hasText && !onlyLight)) {
    return const EmailColorPolicy(Brightness.dark, adapt: true);
  }
  return const EmailColorPolicy(Brightness.light);
}

bool _simpleStyle(HtmlStyle style) {
  final background = style.backgroundColor;
  return style.backgroundImage == null &&
      (background == null ||
          background.a == 0 ||
          HSLColor.fromColor(background).saturation < 0.15) &&
      style.width == null &&
      style.minWidth == null &&
      style.maxWidth == null &&
      style.height == null &&
      style.minHeight == null &&
      style.maxHeight == null &&
      style.float == null &&
      style.display != CssDisplay.flex;
}
