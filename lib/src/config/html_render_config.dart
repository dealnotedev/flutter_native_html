import 'package:flutter/widgets.dart';

import '../parsing/html_sanitizer.dart';
import '../rendering/element_handler.dart';
import 'html_image_resolver.dart';

/// Called when the user taps an `<a href>`. The widget never navigates on its
/// own — the host app decides what to do with the URL.
typedef HtmlLinkTapCallback =
    void Function(String url, Map<String, String> attributes);

/// Called when the user taps an `<img>`.
typedef HtmlImageTapCallback =
    void Function(String src, Map<String, String> attributes);

/// Builds the placeholder shown in place of a remote image that was blocked for
/// privacy. Return your own "tap to load images" affordance here.
typedef HtmlBlockedImageBuilder =
    Widget Function(
      BuildContext context,
      String src,
      Map<String, String> attributes,
    );

const Object _unsetConfigValue = Object();

/// Immutable configuration for [HtmlEmailView].
///
/// Holds the rendering policy (image loading, link handling), styling defaults,
/// the sanitizer, and any custom element handlers. Construct once and reuse.
@immutable
class HtmlRenderConfig {
  const HtmlRenderConfig({
    this.imageResolver = const DefaultHtmlImageResolver(),
    this.sanitizer = const HtmlSanitizer(),
    this.handlers = const [],
    this.onLinkTap,
    this.onImageTap,
    this.blockedImageBuilder,
    this.baseFontSize = 14.0,
    this.defaultColor,
    this.defaultFontFamily,
    this.linkColor,
    this.autoLinkify = true,
    this.autoLinkColor,
    this.maxImageWidth,
    this.imageMaxHeight,
    this.defaultTableCellSpacing = 0,
    this.fitToWidth = false,
    this.fitToWidthMinScale = 0.5,
    this.maxHtmlCharacters = 2 * 1024 * 1024,
    this.maxDomNodes = 50000,
    this.maxCssCharacters = 512 * 1024,
    this.maxCssRules = 10000,
    this.enableTextSelection = true,
  }) : assert(
         fitToWidthMinScale > 0 && fitToWidthMinScale <= 1,
         'fitToWidthMinScale must be greater than 0 and at most 1',
       ),
       assert(baseFontSize > 0 && baseFontSize < double.infinity),
       assert(
         defaultTableCellSpacing >= 0 &&
             defaultTableCellSpacing < double.infinity,
       ),
       assert(
         maxImageWidth == null ||
             (maxImageWidth > 0 && maxImageWidth < double.infinity),
       ),
       assert(
         imageMaxHeight == null ||
             (imageMaxHeight > 0 && imageMaxHeight < double.infinity),
       ),
       assert(maxHtmlCharacters > 0),
       assert(maxDomNodes > 0),
       assert(maxCssCharacters > 0),
       assert(maxCssRules > 0);

  /// Resolves `<img src>` to an image (or blocks it). Defaults to the
  /// privacy-first resolver that suppresses remote images.
  final HtmlImageResolver imageResolver;

  /// Strips unsafe/unsupported markup before rendering.
  final HtmlSanitizer sanitizer;

  /// Custom handlers; take precedence over built-ins for the same tag.
  final List<HtmlElementHandler> handlers;

  final HtmlLinkTapCallback? onLinkTap;
  final HtmlImageTapCallback? onImageTap;
  final HtmlBlockedImageBuilder? blockedImageBuilder;

  /// Root font size (logical px) used as the basis for `em`/`%` and headings.
  final double baseFontSize;

  /// Default text color. When null it is taken from the ambient
  /// [DefaultTextStyle]/theme at build time.
  final Color? defaultColor;

  /// Default font family applied to the root when CSS doesn't specify one.
  final String? defaultFontFamily;

  /// Overrides the default link color (the UA blue) when set.
  final Color? linkColor;

  /// Auto-detects bare email addresses and URLs in text and turns them into
  /// tappable links (like Gmail). Matches on the host via [onLinkTap].
  final bool autoLinkify;

  /// Color for auto-detected links (see [autoLinkify]). When null (the
  /// default), auto-links keep the surrounding text's appearance and are merely
  /// tappable — matching how the bare address looked in the source. Set a color
  /// to render them Gmail-style (colored + underlined).
  final Color? autoLinkColor;

  /// Hard cap on rendered image width in logical px (in addition to the
  /// available container width). Null = only bounded by the container.
  final double? maxImageWidth;

  /// Optional cap on rendered image height in logical px.
  final double? imageMaxHeight;

  /// Spacing for tables without CSS border-spacing or a cellspacing hint.
  /// The email reset is zero; use 2 for a browser/Gmail host's default.
  final double defaultTableCellSpacing;

  /// Scales the whole email down to fit a narrow viewport, the way a mobile mail
  /// client (or a mobile browser's viewport) presents an oversized email: the
  /// layout is computed at its natural width, then the result is shrunk to fit.
  ///
  /// Responsive emails (those that adapt via `@media`, `width:100%`, etc.) reach
  /// the viewport width on their own and are left at scale 1; only content that
  /// stays wider than the viewport (fixed-width/legacy layouts) is scaled down,
  /// so it's shown whole instead of clipped on the right. Off by default
  /// (default rendering overflows like a desktop browser).
  final bool fitToWidth;

  /// Lower bound for the [fitToWidth] scale. Wider content is re-laid out at a
  /// narrower logical width once this floor is reached, keeping the painted
  /// result inside the viewport without making text unreadably small.
  final double fitToWidthMinScale;

  /// Hard limit applied before parsing untrusted HTML on the UI isolate.
  final int maxHtmlCharacters;
  final int maxDomNodes;
  final int maxCssCharacters;
  final int maxCssRules;

  /// Enables native text selection/copy across the rendered message.
  final bool enableTextSelection;

  HtmlRenderConfig copyWith({
    HtmlImageResolver? imageResolver,
    HtmlSanitizer? sanitizer,
    List<HtmlElementHandler>? handlers,
    Object? onLinkTap = _unsetConfigValue,
    Object? onImageTap = _unsetConfigValue,
    Object? blockedImageBuilder = _unsetConfigValue,
    double? baseFontSize,
    Object? defaultColor = _unsetConfigValue,
    Object? defaultFontFamily = _unsetConfigValue,
    Object? linkColor = _unsetConfigValue,
    bool? autoLinkify,
    Object? autoLinkColor = _unsetConfigValue,
    Object? maxImageWidth = _unsetConfigValue,
    Object? imageMaxHeight = _unsetConfigValue,
    double? defaultTableCellSpacing,
    bool? fitToWidth,
    double? fitToWidthMinScale,
    int? maxHtmlCharacters,
    int? maxDomNodes,
    int? maxCssCharacters,
    int? maxCssRules,
    bool? enableTextSelection,
  }) {
    return HtmlRenderConfig(
      imageResolver: imageResolver ?? this.imageResolver,
      sanitizer: sanitizer ?? this.sanitizer,
      handlers: handlers ?? this.handlers,
      onLinkTap: identical(onLinkTap, _unsetConfigValue)
          ? this.onLinkTap
          : onLinkTap as HtmlLinkTapCallback?,
      onImageTap: identical(onImageTap, _unsetConfigValue)
          ? this.onImageTap
          : onImageTap as HtmlImageTapCallback?,
      blockedImageBuilder: identical(blockedImageBuilder, _unsetConfigValue)
          ? this.blockedImageBuilder
          : blockedImageBuilder as HtmlBlockedImageBuilder?,
      baseFontSize: baseFontSize ?? this.baseFontSize,
      defaultColor: identical(defaultColor, _unsetConfigValue)
          ? this.defaultColor
          : defaultColor as Color?,
      defaultFontFamily: identical(defaultFontFamily, _unsetConfigValue)
          ? this.defaultFontFamily
          : defaultFontFamily as String?,
      linkColor: identical(linkColor, _unsetConfigValue)
          ? this.linkColor
          : linkColor as Color?,
      autoLinkify: autoLinkify ?? this.autoLinkify,
      autoLinkColor: identical(autoLinkColor, _unsetConfigValue)
          ? this.autoLinkColor
          : autoLinkColor as Color?,
      maxImageWidth: identical(maxImageWidth, _unsetConfigValue)
          ? this.maxImageWidth
          : maxImageWidth as double?,
      imageMaxHeight: identical(imageMaxHeight, _unsetConfigValue)
          ? this.imageMaxHeight
          : imageMaxHeight as double?,
      defaultTableCellSpacing:
          defaultTableCellSpacing ?? this.defaultTableCellSpacing,
      fitToWidth: fitToWidth ?? this.fitToWidth,
      fitToWidthMinScale: fitToWidthMinScale ?? this.fitToWidthMinScale,
      maxHtmlCharacters: maxHtmlCharacters ?? this.maxHtmlCharacters,
      maxDomNodes: maxDomNodes ?? this.maxDomNodes,
      maxCssCharacters: maxCssCharacters ?? this.maxCssCharacters,
      maxCssRules: maxCssRules ?? this.maxCssRules,
      enableTextSelection: enableTextSelection ?? this.enableTextSelection,
    );
  }
}
