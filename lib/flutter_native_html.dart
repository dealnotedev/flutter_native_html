/// A native, no-WebView HTML renderer for email bodies.
///
/// Public API surface. Import this single file to use the widget and to build
/// custom configuration or element handlers:
///
/// ```dart
/// HtmlEmailView(
///   html: emailBody,
///   config: HtmlRenderConfig(
///     onLinkTap: (url, _) => launchUrl(Uri.parse(url)),
///     imageResolver: const DefaultHtmlImageResolver(allowRemoteImages: false),
///   ),
/// )
/// ```
library;

// Widget
export 'src/widget/html_email_view.dart';

// Configuration & policies
export 'src/config/html_render_config.dart';
export 'src/config/html_image_resolver.dart';
export 'src/parsing/html_sanitizer.dart';
export 'src/parsing/html_email_parser.dart';
export 'src/analysis/html_document_insets.dart';

// Extension points (custom rendering)
export 'src/rendering/element_handler.dart';
export 'src/rendering/html_build_result.dart';
export 'src/rendering/html_render_context.dart';
export 'src/rendering/html_tree_builder.dart';

// Style model (for custom handlers)
export 'src/css/html_style.dart';
export 'src/css/css_length.dart';
