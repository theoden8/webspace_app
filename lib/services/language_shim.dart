import 'package:webspace/services/page_js.dart';

/// The language-override shim for [language] (`'en'`, `'fr-FR'`).
String buildLanguageShim(String language) =>
    PageJs.language.withConfig({'language': language});
