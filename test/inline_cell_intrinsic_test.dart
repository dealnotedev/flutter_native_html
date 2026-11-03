import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_native_html/flutter_native_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;

class _Calls {
  int count = 0;
}

class _Probe extends SingleChildRenderObjectWidget {
  const _Probe({required this.calls, required super.child, super.key});
  final _Calls calls;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderProbe(calls);
}

class _RenderProbe extends RenderProxyBox {
  _RenderProbe(this.calls);
  final _Calls calls;
  @override
  double computeMaxIntrinsicWidth(double height) {
    calls.count++;
    return super.computeMaxIntrinsicWidth(height);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    calls.count++;
    return super.computeMinIntrinsicWidth(height);
  }
}

class _Handler extends HtmlElementHandler {
  const _Handler(this.calls, this.probeKey, {this.layoutBuilder = false});
  final _Calls calls;
  final Key probeKey;
  final bool layoutBuilder;
  @override
  Set<String> get tags => {'probe'};
  @override
  List<HtmlBuildResult> build(dom.Element element, HtmlRenderContext context) =>
      [
        InlineResult(
          WidgetSpan(
            child: layoutBuilder
                ? LayoutBuilder(
                    builder: (_, _) =>
                        SizedBox(key: probeKey, width: 24, height: 24),
                  )
                : _Probe(
                    key: probeKey,
                    calls: calls,
                    child: const SizedBox(width: 24, height: 24),
                  ),
          ),
        ),
      ];
}

void main() {
  for (final depth in [1, 16]) {
    testWidgets(
      'inline cell content avoids intrinsic leaf probes at depth $depth',
      (tester) async {
        final calls = _Calls();
        final key = UniqueKey();
        final prefix = List.filled(
          depth,
          '<table><tr><td style="display:inline-block">',
        ).join();
        final suffix = List.filled(depth, '</td></tr></table>').join();
        final html = '$prefix<probe></probe>$suffix';
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 390,
              child: SingleChildScrollView(
                child: HtmlEmailView(
                  html: html,
                  config: HtmlRenderConfig(
                    enableTextSelection: false,
                    handlers: [_Handler(calls, key)],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byKey(key)), const Size(24, 24));
        expect(
          calls.count,
          0,
          reason: 'A shrink-wrapping inline run can lay out its child directly',
        );
      },
    );
  }
  testWidgets('auto inline cell accepts an inline LayoutBuilder handler', (
    tester,
  ) async {
    final key = UniqueKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          child: SingleChildScrollView(
            child: HtmlEmailView(
              html:
                  '<table><tr><td style="display:inline-block"><probe></probe></td></tr></table>',
              config: HtmlRenderConfig(
                enableTextSelection: false,
                handlers: [_Handler(_Calls(), key, layoutBuilder: true)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(key)), const Size(24, 24));
  });
}
