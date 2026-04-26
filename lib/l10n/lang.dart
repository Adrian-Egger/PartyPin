import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global language notifier — wrap MaterialApp with ValueListenableBuilder on this.
final langNotifier = ValueNotifier<String>('de');

/// Lang.t('key') — returns translated string for current language.
class Lang {
  static String get code => langNotifier.value;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    langNotifier.value = prefs.getString('language') ?? 'de';
  }

  static Future<void> set(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', code);
    langNotifier.value = code;
  }

  static String t(String key) =>
      _all[code]?[key] ?? _all['de']?[key] ?? key;

  static String tLang(String lang, String key) =>
      _all[lang]?[key] ?? _all['de']?[key] ?? key;

  static const _all = {'de': _de, 'en': _en};

  // ─── German ────────────────────────────────────────────────────────────────
  static const _de = <String, String>{
    // Common
    'ok': 'OK',
    'cancel': 'Abbrechen',
    'save': 'Speichern',
    'close': 'Schließen',
    'remove': 'Entfernen',
    'delete': 'Löschen',
    'skip': 'Überspringen',
    'error': 'Fehler',
    'loading': 'Lädt…',
    'searching': 'Suche…',
    'yes': 'Ja',
    'no': 'Nein',

    // Navigation
    'nav_chat': 'Chat',
    'nav_feedback': 'Feedback',
    'nav_friends': 'Freunde',
    'nav_map': 'Map',
    'nav_new': 'Neu',
    'nav_event': 'Event',
    'nav_bar_feedback': 'Feedback',
    'nav_my_bar': 'Meine Bar',

    // Selection Screen
    'selection_title': 'Willkommen',
    'selection_heading': 'Sprache, Land & Stadt',
    'selection_language': 'Sprache',
    'selection_country': 'Land',
    'selection_city': 'Stadt',
    'selection_city_hint': 'z. B. Vienna / Linz / Graz',
    'selection_city_missing': 'Bitte eine Stadt eingeben',
    'selection_city_not_found': 'Stadt nicht gefunden',
    'selection_map_info': 'Die Karte startet in deiner gewählten Stadt.',
    'selection_go': 'Zur Karte',
    'selection_address': 'Adresse (optional)',
    'selection_address_hint': 'z. B. Mariahilfer Str. 15',
    'selection_address_not_found': 'Adresse nicht gefunden – bitte genauer angeben oder weglassen',
    'selection_address_info': 'Optional · Mit deiner genauen Adresse wird der Party-Radius direkt von deinem Standort berechnet – präziser als nur die Stadt.',

    // Notification Settings Screen
    'notif_title':           'Benachrichtigungen',
    'notif_section_activity':'Aktivitäten',
    'notif_chat_title':      'Chatnachrichten',
    'notif_chat_sub':        'Wenn dir jemand eine Nachricht schickt',
    'notif_friends_title':   'Freundschaftsanfragen',
    'notif_friends_sub':     'Wenn dich jemand adden möchte',
    'notif_section_going_out':'Ausgehen',
    'notif_parties_title':   'Partys in deiner Nähe',
    'notif_parties_sub':     'Donnerstag & Freitag: Tipps für Partys in deiner Stadt',
    'notif_bars_title':      'Bar-Empfehlungen',
    'notif_bars_sub':        'Wenn keine Partys in deiner Nähe sind – Bars als Alternative',
    'notif_location_hint':   'Basiert auf der Stadt oder Adresse, die du unter Sprache & Standort eingegeben hast.',

    // Friends Screen
    'friends_header': 'Freunde',
    'friends_search_hint': 'Username suchen oder hinzufügen…',
    'friends_section_requests': 'Anfragen',
    'friends_section_results': 'Suchergebnisse',
    'friends_section_my_friends': 'Meine Freunde',
    'friends_add': 'Add+',
    'friends_pending': 'Ausstehend',
    'friends_accept': 'Annehmen',
    'friends_decline': 'Ablehnen',
    'friends_remove': 'Entfernen',
    'friends_block': 'Blockieren',
    'friends_unblock': 'Entblocken',
    'friends_report': 'Melden',
    'friends_blocked_by_me': 'Von dir blockiert',
    'friends_blocked': 'Blockiert',
    'friends_empty': 'Noch keine Freunde — such nach Usernamen oben',
    'friends_no_results': 'Kein User gefunden',
    'friends_no_match': 'Kein Freund gefunden',
    'friends_request_sent': 'Anfrage gesendet',
    'friends_request_exists': 'Anfrage existiert bereits.',
    'friends_already_friends': 'Ihr seid bereits Freunde.',
    'friends_accepted': 'Anfrage angenommen',
    'friends_declined': 'Anfrage abgelehnt',
    'friends_removed': 'Entfernt',
    'friends_blocked_ok': 'Blockiert',
    'friends_unblocked_ok': 'Entblockt',
    'friends_reported_ok': 'Gemeldet',
    'friends_self_add': 'Du kannst dich nicht selbst adden.',
    'friends_you_blocked': 'Du hast den User blockiert.',
    'friends_they_blocked': 'Der User hat dich blockiert.',
    'friends_not_found': 'User nicht gefunden',
    'friends_no_user': 'Kein aktueller Benutzer.',
    'friends_confirm_remove_title': 'Freund entfernen',
    'friends_confirm_remove_body': 'wirklich entfernen?',
    'friends_confirm_block_title': 'Blockieren?',
    'friends_confirm_block_body': 'blockieren?',
    'friends_report_title': 'Grund melden',
    'friends_report_details_title': 'Details (optional)',
    'friends_report_details_hint': 'Kurz erklären…',
    'friends_add_suffix': 'hinzufügen',

    // Report reasons
    'report_hate': 'Hate Speech',
    'report_harassment': 'Belästigung',
    'report_nudity': 'Nacktheit/Sexuell',
    'report_violence': 'Gewalt',
    'report_spam': 'Spam',
    'report_other': 'Sonstiges',

    // Feedback Screen
    'feedback_header': 'Feedback',

    // Party Map
    'map_title': 'PartyPin',
    'map_reload': 'Neu laden',
    'map_filter': 'Filter',
    'map_profile': 'Profil',

    // New Party
    'new_party_header': 'Neue Party',

    // Notifications
    'notif_friend_request_title': 'Neue Freundschaftsanfrage',
    'notif_friend_request_body': 'möchte dich adden',

    // Menu
    'menu_header': 'Menü',
    'menu_party_map': 'Party Karte',
    'menu_approved_parties': 'Zugelassene Partys',
    'menu_language_location': 'Sprache & Ort',
    'menu_coming_soon': 'Coming Soon',
    'menu_legal': 'Rechtliches',
    'menu_logout': 'Abmelden',
    'cs_subtitle': 'Was als nächstes kommt',
    'cs_feedback_note': 'Deine Ideen zählen! Was du uns im Feedback schreibst, fließt direkt in die Entwicklung ein.',
    'cs_f1': 'Push-Benachrichtigungen',
    'cs_f2': 'Verbesserter Chat & Direktnachrichten',
    'cs_f3': 'Freunde-System ausbauen',
    'cs_f4': 'Party-Filter & Suche auf der Karte',
    'cs_f5': 'Party-Bewertungen & Erfahrungsberichte',
    'cs_f6': 'Party-Stories & Fotos',
    'cs_f7': 'Verifizierte Veranstalter',
    'cs_f8': 'Eure Feedback-Wünsche',

    // Profile
    'profile_header': 'Profil',
    'profile_photo': 'Profilbild auswählen',
    'profile_photo_soon': 'Profilbild: Coming soon',
    'profile_updated': 'Profilbild aktualisiert.',
    'profile_section_account': 'Account',
    'profile_username_label': 'Username',
    'profile_username_not_set': 'Nicht gesetzt',
    'profile_username_hint': 'Neuer Username',
    'profile_username_empty': 'Username darf nicht leer sein.',
    'profile_username_taken': 'Dieser Username ist bereits vergeben.',
    'profile_username_saved': 'Username erfolgreich geändert.',
    'profile_password_label': 'Passwort',
    'profile_password_current': 'Aktuelles Passwort',
    'profile_password_new': 'Neues Passwort',
    'profile_password_empty': 'Neues Passwort darf nicht leer sein.',
    'profile_password_wrong': 'Aktuelles Passwort ist falsch.',
    'profile_password_saved': 'Passwort erfolgreich geändert.',
    'profile_bio_label': 'Bio',
    'profile_bio_none': 'Noch keine Bio',
    'profile_bio_hint': 'Kurze Beschreibung...',
    'profile_bio_saved': 'Bio gespeichert.',
    'profile_doc_not_found': 'Dokument nicht gefunden. Bitte neu einloggen.',
    'profile_doc_not_found_short': 'Dokument nicht gefunden.',
    'profile_upload_failed': 'Upload fehlgeschlagen',
    'profile_cam_restricted': 'Kamera-Zugriff ist durch eine Gerätebeschränkung gesperrt.',
    'profile_cam_unavailable': 'Kamera nicht verfügbar.',
    'profile_firebase_fail': 'Firebase Login fehlgeschlagen',
    'profile_avatar_title': 'Profilbild',
    'profile_avatar_gallery': 'Aus Galerie wählen',
    'profile_avatar_camera': 'Foto aufnehmen',
    'profile_avatar_view': 'Profilbild ansehen',
    'profile_logout_title': 'Logout bestätigen',
    'profile_logout_msg': 'Willst du dich wirklich ausloggen?',
    'profile_logout_btn': 'Abmelden',
    'profile_delete_title': 'Account löschen',
    'profile_delete_msg': 'Bist du sicher, dass du deinen Account löschen willst?',
    'profile_delete_title2': 'Letzte Warnung',
    'profile_delete_msg2': 'Dieser Vorgang ist endgültig und alle Daten werden gelöscht. Willst du wirklich fortfahren?',
    'profile_delete_confirm': 'Ja, löschen',
    'profile_delete_btn': 'Account löschen',
    'perm_camera': 'Kamera',
    'perm_photos': 'Fotos',
    'perm_access_denied': '-Zugriff nicht erlaubt',
    'perm_ios_instruction': 'Öffne die Einstellungen und aktiviere:\n\nEinstellungen → Party Pin → ',
    'perm_android_instruction': 'Bitte erlaube den Zugriff in den App-Einstellungen.',
    'perm_open_settings': 'Einstellungen öffnen',

    // New Party
    'new_party_edit': 'Party bearbeiten',

    // Bar screens
    'bar_feedback_header': 'Bar-Feedback',
    'bar_event_create': 'Event erstellen',
    'bar_event_edit': 'Event bearbeiten',

    // Other screens
    'exclude_friends_header': 'Freunde ausschließen',
    'access_parties_header': 'Partys',
    'map_picker_header': 'Standort wählen',
    'terms_header': 'Nutzungsbedingungen',

    // Login & Account
    'login_title': 'Anmeldung',
    'login_subtitle': 'Melde dich mit deinem Privat- oder Unternehmensaccount an.',
    'create_account_title': 'Account erstellen',
    'login_username': 'Benutzername',
    'login_username_hint': 'Dein Login-Name',
    'login_password': 'Passwort',
    'login_btn': 'Anmelden',
    'login_no_account': 'Noch keinen Account? Jetzt registrieren',
    'login_account_type': 'Account-Typ',
    'login_type_private': 'Privat',
    'login_type_company': 'Unternehmen',
    'login_as_company': 'Du meldest dich als Unternehmen an.',
    'login_as_private': 'Du meldest dich als Privatperson an.',
    'login_err_empty': 'Bitte Benutzername und Passwort eingeben.',
    'login_err_not_found': 'Benutzername nicht gefunden.',
    'login_err_wrong_pw': 'Falsches Passwort.',
    'login_err_not_company': 'Dieser Account ist kein Unternehmens-Account.',
    'login_err_is_company': 'Dieser Account ist ein Unternehmens-Account. Bitte als Unternehmen einloggen.',
    'login_err_generic': 'Fehler beim Login',

    // Registration
    'reg_title_company': 'Unternehmens-Antrag',
    'reg_subtitle_company': 'Stelle hier einen Antrag für einen offiziellen PartyPin-Unternehmens-Account.',
    'reg_subtitle_private': 'Wähle, ob du ein Privatkonto oder einen Unternehmens-Account erstellen möchtest.',
    'reg_type_company_hint': 'Du stellst einen Antrag für einen Unternehmens-Account (z. B. Bar, Lokal, Veranstalter).',
    'reg_type_private_hint': 'Du erstellst ein Privatkonto.',
    'reg_bar_name': 'Name des Unternehmens / Lokals',
    'reg_bar_name_hint': 'z. B. Mustermann Club',
    'reg_first_name': 'Vorname',
    'reg_first_name_hint': 'z. B. Max',
    'reg_last_name': 'Nachname',
    'reg_last_name_hint': 'z. B. Mustermann',
    'reg_username_hint': '3–20 Zeichen, a–z, 0–9, _.-',
    'reg_password_hint': 'mind. 6 Zeichen',
    'reg_pw_hide': 'Verbergen',
    'reg_pw_show': 'Anzeigen',
    'reg_business_email': 'Geschäfts-E-Mail',
    'reg_phone': 'Telefonnummer',
    'reg_availability': 'Erreichbar (Telefon / E-Mail)',
    'reg_availability_hint': 'z. B. Mo–Fr 14–18 Uhr oder „Bitte nur per Mail"',
    'reg_btn_apply': 'Antrag erstellen',
    'reg_bar_info': 'Mit Ihrem Antrag wird ein Unternehmens-Account beantragt. Das PartyPin-Team prüft Ihre Angaben und meldet sich innerhalb Ihrer angegebenen Erreichbarkeitszeiten🕜.',
    'reg_have_account': 'Ich habe bereits einen Account',
    'reg_birthdate': 'Geburtsdatum',
    'reg_day': 'Tag',
    'reg_month': 'Monat',
    'reg_year': 'Jahr',
    'reg_real_name_title': 'Echten Namen verwenden',
    'reg_real_name_body': 'Bitte gib deinen echten Vor- & Nachnamen an. Hosts prüfen Anfragen – mit echtem Namen wirst du eher zugelassen und bekommst die beste Experience.',
    'reg_dont_show_again': 'Nicht mehr anzeigen',
    'reg_understood': 'Verstanden',
    'reg_username_lowercase': 'Usernames dürfen nur Kleinbuchstaben enthalten.',
    'reg_err_username_taken': 'Dieser Benutzername ist bereits vergeben.',
    'reg_err_age': 'Du musst mindestens 12 Jahre alt sein.',
    'reg_err_save': 'Fehler beim Speichern',
    'reg_dialog_title': 'Antrag eingereicht',
    'reg_dialog_body': 'Dein Antrag für einen Unternehmens-Account wurde an das PartyPin-Team gesendet.\n\nWir prüfen deine Angaben und melden uns innerhalb deiner angegebenen Erreichbarkeitszeiten telefonisch oder per E-Mail, sobald dein Account erstellt und freigeschaltet wurde.',

    // Validators
    'val_required': 'Pflichtfeld',
    'val_too_short': 'Zu kurz',
    'val_lowercase_only': 'Nur Kleinbuchstaben erlaubt',
    'val_username_format': '3–20 Zeichen, a–z, 0–9, _ . -',
    'val_username_taken': 'Bereits vergeben',
    'val_min_6_chars': 'Mind. 6 Zeichen',
    'val_invalid_email': 'Ungültige E-Mail',

    // Password strength
    'pw_very_weak': 'sehr schwach',
    'pw_weak': 'schwach',
    'pw_ok': 'ok',
    'pw_good': 'gut',
    'pw_strong': 'stark',
    'pw_strength_label': 'Passwort',

    // Errors
    'err_generic': 'Ein Fehler ist aufgetreten.',
    'err_city_not_found': 'Stadt nicht gefunden',
  };

  // ─── English ───────────────────────────────────────────────────────────────
  static const _en = <String, String>{
    // Common
    'ok': 'OK',
    'cancel': 'Cancel',
    'save': 'Save',
    'close': 'Close',
    'remove': 'Remove',
    'delete': 'Delete',
    'skip': 'Skip',
    'error': 'Error',
    'loading': 'Loading…',
    'searching': 'Searching…',
    'yes': 'Yes',
    'no': 'No',

    // Navigation
    'nav_chat': 'Chat',
    'nav_feedback': 'Feedback',
    'nav_friends': 'Friends',
    'nav_map': 'Map',
    'nav_new': 'New',
    'nav_event': 'Event',
    'nav_bar_feedback': 'Feedback',
    'nav_my_bar': 'My Bar',

    // Selection Screen
    'selection_title': 'Welcome',
    'selection_heading': 'Language, Country & City',
    'selection_language': 'Language',
    'selection_country': 'Country',
    'selection_city': 'City',
    'selection_city_hint': 'e.g. Vienna / Linz / Graz',
    'selection_city_missing': 'Please enter a city',
    'selection_city_not_found': 'City not found',
    'selection_map_info': 'The map starts in your selected city.',
    'selection_go': 'Go to Map',
    'selection_address': 'Address (optional)',
    'selection_address_hint': 'e.g. 15 Baker St',
    'selection_address_not_found': 'Address not found – please be more specific or leave it empty',
    'selection_address_info': 'Optional · With your precise address the party radius is calculated from your exact location – more accurate than just the city.',

    // Notification Settings Screen
    'notif_title':           'Notifications',
    'notif_section_activity':'Activity',
    'notif_chat_title':      'Chat Messages',
    'notif_chat_sub':        'When someone sends you a message',
    'notif_friends_title':   'Friend Requests',
    'notif_friends_sub':     'When someone wants to add you',
    'notif_section_going_out':'Going Out',
    'notif_parties_title':   'Parties Near You',
    'notif_parties_sub':     'Thursday & Friday: party tips for your entered city',
    'notif_bars_title':      'Bar Suggestions',
    'notif_bars_sub':        'When no parties are nearby – bars as an alternative',
    'notif_location_hint':   'Based on the city or address you entered in Language & Location.',

    // Friends Screen
    'friends_header': 'Friends',
    'friends_search_hint': 'Search or add username…',
    'friends_section_requests': 'Requests',
    'friends_section_results': 'Search Results',
    'friends_section_my_friends': 'My Friends',
    'friends_add': 'Add+',
    'friends_pending': 'Pending',
    'friends_accept': 'Accept',
    'friends_decline': 'Decline',
    'friends_remove': 'Remove',
    'friends_block': 'Block',
    'friends_unblock': 'Unblock',
    'friends_report': 'Report',
    'friends_blocked_by_me': 'Blocked by you',
    'friends_blocked': 'Blocked',
    'friends_empty': 'No friends yet — search for usernames above',
    'friends_no_results': 'No users found',
    'friends_no_match': 'No friend found',
    'friends_request_sent': 'Request sent',
    'friends_request_exists': 'Request already exists.',
    'friends_already_friends': 'You are already friends.',
    'friends_accepted': 'Request accepted',
    'friends_declined': 'Request declined',
    'friends_removed': 'Removed',
    'friends_blocked_ok': 'Blocked',
    'friends_unblocked_ok': 'Unblocked',
    'friends_reported_ok': 'Reported',
    'friends_self_add': 'You cannot add yourself.',
    'friends_you_blocked': 'You have blocked this user.',
    'friends_they_blocked': 'This user has blocked you.',
    'friends_not_found': 'User not found',
    'friends_no_user': 'No current user.',
    'friends_confirm_remove_title': 'Remove Friend',
    'friends_confirm_remove_body': 'really remove?',
    'friends_confirm_block_title': 'Block?',
    'friends_confirm_block_body': 'block?',
    'friends_report_title': 'Report Reason',
    'friends_report_details_title': 'Details (optional)',
    'friends_report_details_hint': 'Briefly explain…',
    'friends_add_suffix': 'add',

    // Report reasons
    'report_hate': 'Hate Speech',
    'report_harassment': 'Harassment',
    'report_nudity': 'Nudity/Sexual',
    'report_violence': 'Violence',
    'report_spam': 'Spam',
    'report_other': 'Other',

    // Feedback Screen
    'feedback_header': 'Feedback',

    // Party Map
    'map_title': 'PartyPin',
    'map_reload': 'Reload',
    'map_filter': 'Filter',
    'map_profile': 'Profile',

    // New Party
    'new_party_header': 'New Party',

    // Notifications
    'notif_friend_request_title': 'New Friend Request',
    'notif_friend_request_body': 'wants to add you',

    // Menu
    'menu_header': 'Menu',
    'menu_party_map': 'Party Map',
    'menu_approved_parties': 'Approved Parties',
    'menu_language_location': 'Language & Location',
    'menu_coming_soon': 'Coming Soon',
    'menu_legal': 'Legal',
    'menu_logout': 'Log out',
    'cs_subtitle': "What's coming next",
    'cs_feedback_note': 'Your ideas matter! Everything you write in the feedback goes directly into development.',
    'cs_f1': 'Push notifications',
    'cs_f2': 'Improved chat & direct messages',
    'cs_f3': 'Expanded friends system',
    'cs_f4': 'Party filters & search on the map',
    'cs_f5': 'Party ratings & reviews',
    'cs_f6': 'Party stories & photos',
    'cs_f7': 'Verified organizers',
    'cs_f8': 'Your feedback requests',

    // Profile
    'profile_header': 'Profile',
    'profile_photo': 'Select profile picture',
    'profile_photo_soon': 'Profile picture: Coming soon',
    'profile_updated': 'Profile picture updated.',
    'profile_section_account': 'Account',
    'profile_username_label': 'Username',
    'profile_username_not_set': 'Not set',
    'profile_username_hint': 'New username',
    'profile_username_empty': 'Username cannot be empty.',
    'profile_username_taken': 'This username is already taken.',
    'profile_username_saved': 'Username successfully changed.',
    'profile_password_label': 'Password',
    'profile_password_current': 'Current password',
    'profile_password_new': 'New password',
    'profile_password_empty': 'New password cannot be empty.',
    'profile_password_wrong': 'Current password is incorrect.',
    'profile_password_saved': 'Password successfully changed.',
    'profile_bio_label': 'Bio',
    'profile_bio_none': 'No bio yet',
    'profile_bio_hint': 'Short description...',
    'profile_bio_saved': 'Bio saved.',
    'profile_doc_not_found': 'Document not found. Please log in again.',
    'profile_doc_not_found_short': 'Document not found.',
    'profile_upload_failed': 'Upload failed',
    'profile_cam_restricted': 'Camera access is restricted by a device policy.',
    'profile_cam_unavailable': 'Camera unavailable.',
    'profile_firebase_fail': 'Firebase login failed',
    'profile_avatar_title': 'Profile Picture',
    'profile_avatar_gallery': 'Choose from Gallery',
    'profile_avatar_camera': 'Take Photo',
    'profile_avatar_view': 'View Profile Picture',
    'profile_logout_title': 'Confirm Logout',
    'profile_logout_msg': 'Are you sure you want to log out?',
    'profile_logout_btn': 'Log out',
    'profile_delete_title': 'Delete Account',
    'profile_delete_msg': 'Are you sure you want to delete your account?',
    'profile_delete_title2': 'Final Warning',
    'profile_delete_msg2': 'This action is permanent and all data will be deleted. Do you really want to continue?',
    'profile_delete_confirm': 'Yes, delete',
    'profile_delete_btn': 'Delete Account',
    'perm_camera': 'Camera',
    'perm_photos': 'Photos',
    'perm_access_denied': ' Access Not Allowed',
    'perm_ios_instruction': 'Open Settings and enable:\n\nSettings → Party Pin → ',
    'perm_android_instruction': 'Please allow access in the app settings.',
    'perm_open_settings': 'Open Settings',

    // New Party
    'new_party_edit': 'Edit Party',

    // Bar screens
    'bar_feedback_header': 'Bar Feedback',
    'bar_event_create': 'Create Event',
    'bar_event_edit': 'Edit Event',

    // Other screens
    'exclude_friends_header': 'Exclude Friends',
    'access_parties_header': 'Parties',
    'map_picker_header': 'Select Location',
    'terms_header': 'Terms of Use',

    // Login & Account
    'login_title': 'Sign in',
    'login_subtitle': 'Sign in with your personal or business account.',
    'create_account_title': 'Create Account',
    'login_username': 'Username',
    'login_username_hint': 'Your login name',
    'login_password': 'Password',
    'login_btn': 'Sign in',
    'login_no_account': 'No account yet? Register now',
    'login_account_type': 'Account type',
    'login_type_private': 'Personal',
    'login_type_company': 'Business',
    'login_as_company': 'You are signing in as a business.',
    'login_as_private': 'You are signing in as a private user.',
    'login_err_empty': 'Please enter username and password.',
    'login_err_not_found': 'Username not found.',
    'login_err_wrong_pw': 'Wrong password.',
    'login_err_not_company': 'This account is not a business account.',
    'login_err_is_company': 'This is a business account. Please sign in as a business.',
    'login_err_generic': 'Login error',

    // Registration
    'reg_title_company': 'Business Application',
    'reg_subtitle_company': 'Apply here for an official PartyPin business account.',
    'reg_subtitle_private': 'Choose whether to create a personal or business account.',
    'reg_type_company_hint': 'You are applying for a business account (e.g. bar, venue, organiser).',
    'reg_type_private_hint': 'You are creating a personal account.',
    'reg_bar_name': 'Business / Venue name',
    'reg_bar_name_hint': 'e.g. Mustermann Club',
    'reg_first_name': 'First name',
    'reg_first_name_hint': 'e.g. Max',
    'reg_last_name': 'Last name',
    'reg_last_name_hint': 'e.g. Mustermann',
    'reg_username_hint': '3–20 chars, a–z, 0–9, _.-',
    'reg_password_hint': 'min. 6 characters',
    'reg_pw_hide': 'Hide',
    'reg_pw_show': 'Show',
    'reg_business_email': 'Business e-mail',
    'reg_phone': 'Phone number',
    'reg_availability': 'Reachable (phone / e-mail)',
    'reg_availability_hint': 'e.g. Mon–Fri 2–6 pm or "E-mail only"',
    'reg_btn_apply': 'Submit application',
    'reg_bar_info': 'Your application will be reviewed by the PartyPin team. We will contact you within your stated availability by phone or e-mail once your account has been created.',
    'reg_have_account': 'I already have an account',
    'reg_birthdate': 'Date of birth',
    'reg_day': 'Day',
    'reg_month': 'Month',
    'reg_year': 'Year',
    'reg_real_name_title': 'Use your real name',
    'reg_real_name_body': 'Please enter your real first and last name. Hosts review requests — using your real name increases your chances of being accepted.',
    'reg_dont_show_again': 'Don\'t show again',
    'reg_understood': 'Got it',
    'reg_username_lowercase': 'Usernames may only contain lowercase letters.',
    'reg_err_username_taken': 'This username is already taken.',
    'reg_err_age': 'You must be at least 12 years old.',
    'reg_err_save': 'Error saving',
    'reg_dialog_title': 'Application submitted',
    'reg_dialog_body': 'Your application for a business account has been sent to the PartyPin team.\n\nWe will review your details and contact you within your stated availability by phone or e-mail once your account is ready.',

    // Validators
    'val_required': 'Required',
    'val_too_short': 'Too short',
    'val_lowercase_only': 'Lowercase only',
    'val_username_format': '3–20 chars, a–z, 0–9, _ . -',
    'val_username_taken': 'Already taken',
    'val_min_6_chars': 'Min. 6 characters',
    'val_invalid_email': 'Invalid e-mail',

    // Password strength
    'pw_very_weak': 'very weak',
    'pw_weak': 'weak',
    'pw_ok': 'ok',
    'pw_good': 'good',
    'pw_strong': 'strong',
    'pw_strength_label': 'Password',

    // Errors
    'err_generic': 'An error occurred.',
    'err_city_not_found': 'City not found',
  };
}

// ─── Language toggle widget (DE / EN flag buttons) ─────────────────────────
class LangToggleWidget extends StatelessWidget {
  const LangToggleWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (_, lang, __) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FlagBtn(code: 'de', emoji: '🇩🇪', current: lang),
          const SizedBox(width: 10),
          _FlagBtn(code: 'en', emoji: '🇬🇧', current: lang),
        ],
      ),
    );
  }
}

class _FlagBtn extends StatelessWidget {
  final String code;
  final String emoji;
  final String current;

  const _FlagBtn({required this.code, required this.emoji, required this.current});

  @override
  Widget build(BuildContext context) {
    final isActive = current == code;
    return GestureDetector(
      onTap: () => Lang.set(code),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? const Color(0x26FF3B30) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? const Color(0xFFFF3B30) : const Color(0x3DFFFFFF),
            width: 1.5,
          ),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 22)),
      ),
    );
  }
}
