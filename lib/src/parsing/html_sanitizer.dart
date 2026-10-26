import 'package:html/dom.dart' as dom;

/// Removes anything unsafe or unsupported from a parsed email DOM before it is
/// rendered.
///
/// Email bodies must not execute script or load active content, so this strips:
/// dangerous elements (`<script>`, `<iframe>`, forms, plugins, …), every
/// `on*` event-handler attribute, and `javascript:`/`vbscript:` URLs.
///
/// The default tag/attribute policy is exposed through constructor parameters
/// so callers can tighten or relax it and pass the sanitizer via
/// `HtmlRenderConfig.sanitizer`.
class HtmlSanitizer {
  const HtmlSanitizer({
    this.forbiddenTags = defaultForbiddenTags,
    this.allowDataUriImages = true,
    this.allowedLinkSchemes = const {'http', 'https', 'mailto', 'tel', 'sms'},
  });

  /// Tags removed entirely (element + subtree).
  final Set<String> forbiddenTags;

  /// Whether `data:` URLs are permitted on `<img src>` (inline images). They
  /// are always blocked on links/other attributes.
  final bool allowDataUriImages;
  final Set<String> allowedLinkSchemes;

  static const Set<String> defaultForbiddenTags = {
    'script',
    'noscript',
    'iframe',
    'frame',
    'frameset',
    'object',
    'embed',
    'applet',
    'param',
    'form',
    'input',
    'button',
    'select',
    'option',
    'optgroup',
    'textarea',
    'fieldset',
    'legend',
    'audio',
    'video',
    'source',
    'track',
    'canvas',
    'svg',
    'math',
    'base',
    'meta',
    'link',
    'title',
    'style',
    'head',
    'map',
    'area',
  };

  static final RegExp _eventAttr = RegExp(r'^on', caseSensitive: false);
  static final RegExp _dangerousScheme = RegExp(
    r'^\s*(javascript|vbscript|data)\s*:',
    caseSensitive: false,
  );
  static final RegExp _scheme = RegExp(
    r'^\s*([a-z][a-z0-9+.-]*)\s*:',
    caseSensitive: false,
  );
  static const Set<String> _urlAttributes = {
    'href',
    'src',
    'background',
    'action',
    'cite',
    'poster',
    'formaction',
  };

  /// Sanitizes [root] in place and returns it for chaining.
  dom.Element sanitize(dom.Element root) {
    _walk(root);
    return root;
  }

  void _walk(dom.Element element) {
    // Iterate over a copy because we mutate the children list.
    for (final child in List<dom.Node>.of(element.nodes)) {
      if (child is dom.Element) {
        final tag = (child.localName ?? '').toLowerCase();
        if (forbiddenTags.contains(tag)) {
          child.remove();
          continue;
        }
        _cleanAttributes(child, tag);
        _walk(child);
      }
    }
  }

  void _cleanAttributes(dom.Element element, String tag) {
    final toRemove = <Object>[];
    element.attributes.forEach((key, value) {
      final name = key.toString().toLowerCase();
      if (_eventAttr.hasMatch(name)) {
        toRemove.add(key);
        return;
      }
      if (_urlAttributes.contains(name) && _isDangerousUrl(name, value, tag)) {
        toRemove.add(key);
      }
    });
    for (final key in toRemove) {
      element.attributes.remove(key);
    }
  }

  bool _isDangerousUrl(String attr, String value, String tag) {
    // Browsers strip ASCII whitespace and control chars from anywhere in a URL
    // before resolving it, so `java&#9;script:` (decoded to `java\tscript:`)
    // becomes `javascript:` and executes. Normalize the same way before scheme
    // detection so obfuscated schemes can't slip through as "relative URLs".
    final normalized = value.replaceAll(RegExp(r'[\x00-\x20]'), '');
    final scheme = _scheme.firstMatch(normalized)?.group(1)?.toLowerCase();
    if (scheme == null) {
      // No parseable scheme. A colon before the first path separator means the
      // value is an absolute URL with an unrecognizable (obfuscated) scheme —
      // reject it. Otherwise it's a genuine relative URL and is safe.
      final colon = normalized.indexOf(':');
      if (colon < 0) return false;
      final sep = normalized.indexOf(RegExp(r'[/?#]'));
      return sep < 0 || colon < sep;
    }
    // Allow inline data: images on <img src> when configured.
    if (scheme == 'data' &&
        allowDataUriImages &&
        tag == 'img' &&
        attr == 'src') {
      return false;
    }
    if (_dangerousScheme.hasMatch(normalized)) return true;
    if (tag == 'img' && attr == 'src') {
      return scheme != 'http' && scheme != 'https' && scheme != 'cid';
    }
    return !allowedLinkSchemes.contains(scheme);
  }
}
