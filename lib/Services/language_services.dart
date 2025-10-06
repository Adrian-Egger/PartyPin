class LanguageService {
  static String currentLanguage = 'de'; // Standard: Deutsch

  static Map<String, Map<String, String>> texts = {
    'de': {
      'menu_title': 'Menü',
      'party_map': 'Party Karte',
      'change_language': 'Sprache & Ort',
    },
    'en': {
      'menu_title': 'Menu',
      'party_map': 'Party Map',
      'change_language': 'Language & Location',
    },
  };

  static String getText(String key, String lang) {
    return texts[lang]?[key] ?? key;
  }

  static void setLanguage(String lang) {
    currentLanguage = lang;
  }
}