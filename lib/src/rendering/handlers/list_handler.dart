import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import '../../css/html_style.dart';
import '../element_handler.dart';
import '../html_build_result.dart';
import '../html_render_context.dart';

/// Renders `<ul>`/`<ol>` and their `<li>` items with markers (bullets or
/// numbers). Nested lists are handled recursively because each `<li>`'s content
/// is built through the normal pipeline.
class ListHandler extends HtmlElementHandler {
  const ListHandler();

  @override
  Set<String> get tags => const {'ul', 'ol', 'li'};

  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) {
    final tag = (element.localName ?? '').toLowerCase();
    if (tag == 'li') {
      // A stray <li> outside a list: render as a single bulleted block.
      return [
        BlockResult(
          context.builder.decorate(
            _row(
              '•',
              context.builder.flow(
                context.buildChildren(element),
                context.style,
              ),
              context,
            ),
            context.style,
          ),
        ),
      ];
    }

    final ordered = tag == 'ol';
    final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;
    final unorderedType = context.style.listStyleType ?? 'disc';
    final orderedType = _orderedType(
      context.style.listStyleType,
      element.attributes['type'],
    );

    final rows = <Widget>[];
    final inlineItems = <Widget>[];
    final floated = <({Widget widget, String? side})>[];
    void flushInlineItems() {
      if (inlineItems.isEmpty) return;
      rows.add(
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.start,
          children: inlineItems.toList(),
        ),
      );
      inlineItems.clear();
    }

    void flushFloated() {
      if (floated.isEmpty) return;
      final alignment = floated.every((item) => item.side == 'right')
          ? WrapAlignment.end
          : WrapAlignment.start;
      rows.add(
        Wrap(
          alignment: alignment,
          runAlignment: alignment,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [for (final item in floated) item.widget],
        ),
      );
      floated.clear();
    }

    var index = start;
    for (final node in element.nodes) {
      if (node is dom.Text) {
        if (RegExp(r'^[\t\n\f\r ]*$').hasMatch(node.text)) continue;
        flushInlineItems();
        flushFloated();
        rows.add(
          context.builder.flow(
            context.builder.buildNodes([node], context.childInherited),
            context.style,
          ),
        );
        continue;
      }
      if (node is! dom.Element) continue;
      final localName = (node.localName ?? '').toLowerCase();
      if (localName != 'li') {
        // Browsers render non-<li> children (a directly-nested list, or a stray
        // <div>/<p> from a generator) as normal blocks — never drop them.
        final childCtx = context.builder.contextFor(
          node,
          context.childInherited,
        );
        if (childCtx.style.display == CssDisplay.none) continue;
        flushInlineItems();
        flushFloated();
        if (localName == 'ul' || localName == 'ol') {
          for (final r in build(node, childCtx)) {
            if (r is BlockResult) rows.add(r.widget);
          }
        } else {
          rows.add(context.builder.buildBlock(node, childCtx));
        }
        continue;
      }
      final liCtx = context.builder.contextFor(node, context.childInherited);
      if (liCtx.style.display == CssDisplay.none) continue;
      final liContent = context.builder.flow(
        context.builder.buildChildNodes(node, liCtx.childInherited),
        liCtx.style,
      );

      final overrideValue = int.tryParse(node.attributes['value'] ?? '');
      if (overrideValue != null) index = overrideValue;

      final liListStyle = liCtx.style.listStyleType;
      final marker = ordered
          ? () {
              final t = liListStyle != null
                  ? _orderedType(liListStyle, null)
                  : orderedType;
              return t == 'none' ? '' : '${_ordinal(index, t)}.';
            }()
          : _bullet(liListStyle ?? unorderedType);
      final float = liCtx.style.float;
      if (float != null && marker.isEmpty) {
        flushInlineItems();
        floated.add((
          widget: context.builder.decorate(
            liContent,
            liCtx.style,
            inline: true,
          ),
          side: float,
        ));
        index++;
        continue;
      }
      if (marker.isEmpty && liCtx.style.display == CssDisplay.inlineBlock) {
        inlineItems.add(
          context.builder.decorate(liContent, liCtx.style, inline: true),
        );
        index++;
        continue;
      }

      flushInlineItems();
      flushFloated();
      // An "image list" uses a background-image as the bullet (the star on the
      // left, with padding-left making room): decorate the item with its own
      // box so the background sprite and padding render, instead of a text
      // marker.
      if (liCtx.style.backgroundImage != null) {
        rows.add(context.builder.decorate(liContent, liCtx.style));
      } else if (_hasBoxStyle(liCtx.style)) {
        // Preserve the item's own box (margin/padding/background/border) that
        // emails use for spacing and cards, instead of dropping it.
        rows.add(
          context.builder.decorate(_row(marker, liContent, liCtx), liCtx.style),
        );
      } else {
        rows.add(_row(marker, liContent, liCtx));
      }
      index++;
    }
    flushInlineItems();
    flushFloated();

    final list = rows.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          );
    return [BlockResult(context.builder.decorate(list, context.style))];
  }

  Widget _row(String marker, Widget content, HtmlRenderContext context) {
    if (marker.isEmpty) return content;
    final markerStyle = context.style.toTextStyle();
    // The default CSS marker position is outside the item's content box. It
    // must not steal text width or add spacing below an explicitly sized line.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        content,
        Positioned(
          left: 0,
          top: 0,
          child: FractionalTranslation(
            translation: const Offset(-1, 0),
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(marker, style: markerStyle),
            ),
          ),
        ),
      ],
    );
  }

  /// Maps a CSS `list-style-type` (or the legacy HTML `type` attribute) to the
  /// ordinal token used by [_ordinal]: `1`/`a`/`A`/`i`/`I`, or `none`.
  String _orderedType(String? cssListStyle, String? attrType) {
    switch (cssListStyle) {
      case 'none':
        return 'none';
      case 'decimal':
        return '1';
      case 'lower-alpha':
      case 'lower-latin':
        return 'a';
      case 'upper-alpha':
      case 'upper-latin':
        return 'A';
      case 'lower-roman':
        return 'i';
      case 'upper-roman':
        return 'I';
    }
    return attrType ?? '1';
  }

  bool _hasBoxStyle(HtmlStyle s) =>
      s.margin != null ||
      s.padding != null ||
      s.backgroundColor != null ||
      s.borders != null;

  String _bullet(String type) {
    switch (type) {
      case 'none':
        return '';
      case 'circle':
        return '◦';
      case 'square':
        return '▪';
      case 'disc':
      default:
        return '•';
    }
  }

  String _ordinal(int index, String type) {
    switch (type) {
      case 'a':
        return _alpha(index, lower: true);
      case 'A':
        return _alpha(index, lower: false);
      case 'i':
        return _roman(index).toLowerCase();
      case 'I':
        return _roman(index);
      default:
        return '$index';
    }
  }

  String _alpha(int n, {required bool lower}) {
    if (n <= 0) return '$n';
    final buffer = StringBuffer();
    var value = n;
    while (value > 0) {
      value--;
      buffer.write(String.fromCharCode((lower ? 97 : 65) + value % 26));
      value ~/= 26;
    }
    return buffer.toString().split('').reversed.join();
  }

  String _roman(int n) {
    if (n <= 0 || n >= 4000) return '$n';
    const numerals = [
      [1000, 'M'],
      [900, 'CM'],
      [500, 'D'],
      [400, 'CD'],
      [100, 'C'],
      [90, 'XC'],
      [50, 'L'],
      [40, 'XL'],
      [10, 'X'],
      [9, 'IX'],
      [5, 'V'],
      [4, 'IV'],
      [1, 'I'],
    ];
    final buffer = StringBuffer();
    var value = n;
    for (final entry in numerals) {
      final amount = entry[0] as int;
      final symbol = entry[1] as String;
      while (value >= amount) {
        buffer.write(symbol);
        value -= amount;
      }
    }
    return buffer.toString();
  }
}
