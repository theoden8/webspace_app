import 'package:flutter/widgets.dart';

/// Endonyms (native names) for every shipped UI locale, shown in the
/// app-language picker. Keys are the same tag form as [tagForLocale].
/// A locale missing here falls back to its BCP-47 tag in the picker.
const Map<String, String> kLanguageNativeNames = {
  'en': 'English',
  'fr': 'Français',
  'it': 'Italiano',
  'es': 'Español',
  'de': 'Deutsch',
  'uk': 'Українська',
  'ja': '日本語',
  'pl': 'Polski',
  'nl': 'Nederlands',
  'cs': 'Čeština',
  'ko': '한국어',
  'zh': '中文',
  'zh_Hant': '繁體中文',
  'sv': 'Svenska',
  'da': 'Dansk',
  'nb': 'Norsk bokmål',
  'fi': 'Suomi',
  'et': 'Eesti',
  'lv': 'Latviešu',
  'lt': 'Lietuvių',
  'hu': 'Magyar',
  'ro': 'Română',
  'bg': 'Български',
  'sl': 'Slovenščina',
  'pt': 'Português',
  'pt_BR': 'Português (Brasil)',
  'el': 'Ελληνικά',
  'la': 'Latina',
  'he': 'עברית',
  'ar': 'العربية',
  'fa': 'فارسی',
  'tr': 'Türkçe',
  'hi': 'हिन्दी',
  'bn': 'বাংলা',
  'ta': 'தமிழ்',
  'te': 'తెలుగు',
  'mr': 'मराठी',
  'gu': 'ગુજરાતી',
  'kn': 'ಕನ್ನಡ',
  'ml': 'മലയാളം',
  'pa': 'ਪੰਜਾਬੀ',
  'ur': 'اردو',
  'ne': 'नेपाली',
  'si': 'සිංහල',
  'th': 'ไทย',
  'ms': 'Bahasa Melayu',
  'sk': 'Slovenčina',
  'hr': 'Hrvatski',
  'is': 'Íslenska',
  'ga': 'Gaeilge',
  'mt': 'Malti',
  'ca': 'Català',
  'eu': 'Euskara',
  'gl': 'Galego',
  'cy': 'Cymraeg',
  'sr': 'Српски',
  'bs': 'Bosanski',
  'mk': 'Македонски',
  'sq': 'Shqip',
  'id': 'Bahasa Indonesia',
  'fil': 'Filipino',
  'km': 'ខ្មែរ',
  'mn': 'Монгол',
  'ka': 'ქართული',
  'hy': 'Հայերեն',
  'sw': 'Kiswahili',
  'af': 'Afrikaans',
  'am': 'አማርኛ',
};

/// Stable string form of a [Locale] used as the persisted override value and
/// the native-names map key: `language`, `language_SCRIPT`, or
/// `language_COUNTRY` (e.g. `pt_BR`, `zh_Hant`).
String tagForLocale(Locale locale) {
  if (locale.scriptCode != null && locale.scriptCode!.isNotEmpty) {
    return '${locale.languageCode}_${locale.scriptCode}';
  }
  if (locale.countryCode != null && locale.countryCode!.isNotEmpty) {
    return '${locale.languageCode}_${locale.countryCode}';
  }
  return locale.languageCode;
}

/// Parse a persisted override tag back into a [Locale]. Empty string means
/// "follow the system locale" and returns null.
Locale? localeFromTag(String tag) {
  if (tag.isEmpty) return null;
  final parts = tag.split('_');
  if (parts.length == 1) return Locale(parts[0]);
  final second = parts[1];
  // A 4-letter capitalized subtag is a script (Hant/Hans/Latn); else country.
  if (second.length == 4) {
    return Locale.fromSubtags(languageCode: parts[0], scriptCode: second);
  }
  return Locale(parts[0], second);
}

/// Display label for a locale tag in the picker.
String languageLabelForTag(String tag) => kLanguageNativeNames[tag] ?? tag;
