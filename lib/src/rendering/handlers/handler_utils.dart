import 'package:html/dom.dart' as dom;

/// Returns an element's attributes as a plain `String`-keyed map (the html
/// package keys them by `Object` to allow namespaced attributes).
Map<String, String> attributesOf(dom.Element element) {
  final result = <String, String>{};
  element.attributes.forEach((key, value) {
    result[key.toString()] = value;
  });
  return result;
}
