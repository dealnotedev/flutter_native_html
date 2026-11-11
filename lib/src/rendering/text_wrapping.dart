import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum TextWrapping { breakAll, anywhere }

/// Keeps the computed wrapping policy on the text run through link and
/// whitespace processing. A paragraph can contain several different policies.
class WrappingTextSpan extends TextSpan {
  const WrappingTextSpan({
    required this.wrapping,
    super.text,
    super.children,
    super.style,
    super.recognizer,
    super.mouseCursor,
    super.onEnter,
    super.onExit,
    super.semanticsLabel,
    super.locale,
    super.spellOut,
  });

  final TextWrapping? wrapping;
}

TextSpan copyTextSpan(
  TextSpan span, {
  String? text,
  List<InlineSpan>? children,
  GestureRecognizer? recognizer,
  MouseCursor? cursor,
  String? semanticsLabel,
}) {
  return WrappingTextSpan(
    wrapping: span is WrappingTextSpan ? span.wrapping : null,
    text: text ?? span.text,
    children: children ?? span.children,
    style: span.style,
    recognizer: recognizer ?? span.recognizer,
    mouseCursor: cursor ?? span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: semanticsLabel ?? span.semanticsLabel,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

const softBreak = '\u200b';
final _nonBreaking = RegExp(r'[\s\u200b\u2060\ufeff]');
// Flutter already applies its Unicode line breaking, including in CJK text.
// Add opportunities inside alphabetic words whose letters do not join across
// clusters. Inserting format controls into joining scripts changes shaping.
final _nonJoiningLetter = RegExp(
  r'^[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}\p{Nd}]',
  unicode: true,
);

class ParagraphWrap {
  ParagraphWrap(TextSpan source) : text = source {
    final layoutBreaks = <int>[];
    final intrinsicBreaks = <int>[];
    var offset = 0;
    String? previous;
    TextWrapping? previousWrapping;
    var authoredSoftBreak = false;
    source.visitChildren((span) {
      if (span is! TextSpan) {
        offset++; // A WidgetSpan occupies one placeholder code unit.
        previous = null;
        previousWrapping = null;
        return true;
      }
      final run = span.text!;
      authoredSoftBreak |= run.contains(softBreak);
      final wrapping = span is WrappingTextSpan ? span.wrapping : null;
      if (wrapping == null) {
        offset += run.length;
        previous = null;
      } else {
        for (final cluster in run.characters) {
          final before = previous;
          if (before != null &&
              !_nonBreaking.hasMatch(before) &&
              !_nonBreaking.hasMatch(cluster)) {
            final visual =
                wrapping == TextWrapping.breakAll &&
                previousWrapping == TextWrapping.breakAll &&
                _nonJoiningLetter.hasMatch(before) &&
                _nonJoiningLetter.hasMatch(cluster);
            if (visual) layoutBreaks.add(offset);
            intrinsicBreaks.add(offset);
          }
          previous = cluster;
          previousWrapping = wrapping;
          offset += cluster.length;
        }
      }
      return true;
    });
    // Preserve authored word separators in selection. This paragraph already
    // has explicit opportunities for the engine to use.
    if (authoredSoftBreak) layoutBreaks.clear();
    if (layoutBreaks.isNotEmpty) {
      text = insertSoftBreaks(source, layoutBreaks, preserveSemantics: true);
      hasVisualBreaks = true;
    }
    var inserted = 0;
    for (final offset in intrinsicBreaks) {
      if (inserted < layoutBreaks.length && layoutBreaks[inserted] == offset) {
        inserted++;
      }
      minContentBreaks.add(offset + inserted);
    }
  }

  TextSpan text;
  bool hasVisualBreaks = false;
  final minContentBreaks = <int>[];
}

/// Applies offsets to the span tree without rebuilding any inline widgets or
/// changing the gesture recognizers on links.
TextSpan insertSoftBreaks(
  TextSpan root,
  List<int> offsets, {
  bool preserveSemantics = false,
  String separator = softBreak,
}) {
  var offset = 0;
  var index = 0;
  InlineSpan visit(InlineSpan span) {
    if (index == offsets.length) return span;
    if (span is! TextSpan) {
      offset++;
      return span;
    }
    final text = span.text;
    String? replacement;
    if (text != null) {
      final end = offset + text.length;
      if (offsets[index] < end) {
        final buffer = StringBuffer();
        var start = 0;
        while (index < offsets.length && offsets[index] < end) {
          final local = offsets[index++] - offset;
          buffer
            ..write(text.substring(start, local))
            ..write(separator);
          start = local;
        }
        replacement = (buffer..write(text.substring(start))).toString();
      }
      offset = end;
    }
    final children = span.children?.map(visit).toList(growable: false);
    return copyTextSpan(
      span,
      text: replacement,
      children: children,
      semanticsLabel: preserveSemantics && replacement != null
          ? span.semanticsLabel ?? text
          : null,
    );
  }

  return visit(root) as TextSpan;
}

/// Keeps layout-only soft breaks out of selection and clipboard text.
class SoftBreakSelection extends StatefulWidget {
  const SoftBreakSelection({super.key, required this.child});

  final Widget child;

  @override
  State<SoftBreakSelection> createState() => _SoftBreakSelectionState();
}

class _SoftBreakSelectionState extends State<SoftBreakSelection> {
  final _delegate = _SoftBreakSelectionDelegate();

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) == null) return widget.child;
    return SelectionContainer(delegate: _delegate, child: widget.child);
  }

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }
}

class _SoftBreakSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final content = super.getSelectedContent();
    return content == null
        ? null
        : SelectedContent(
            plainText: content.plainText.replaceAll(softBreak, ''),
          );
  }
}
