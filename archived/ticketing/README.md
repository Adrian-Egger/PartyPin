# archived/ticketing/

Dieses Verzeichnis enthält den **archivierten Ticketing-/Stripe-Stack** von PartyPin.
Der Code ist **bewusst nicht gelöscht** — er kann später als Grundlage für eine
optionale Ticketing-V2 dienen.

> Stand: leer initialisiert am 2026-05-13. Die Verschiebung der Dateien geschieht
> erst nach Bestätigung des Inventarberichts.

---

## Zweck des Archivs

PartyPin entfernt die Ticketing-/Payment-Funktion und positioniert sich neu als
**Discovery- + Social- + Live-Map-App**. Der Ticketing-Code wird hier abgelegt,
nicht gelöscht, damit:

1. eine spätere Wiedereinführung möglich ist, ohne aus Git-History zu rekonstruieren,
2. der Hauptcode klar zeigt, was die App ist (kein „ausgeschalteter Commerce-Pfad"),
3. Audits/Reviews sehen können, was bewusst archiviert wurde.

## Deaktivierte Features

| Feature | Frontend-Touchpoint | Backend |
|---|---|---|
| Ticket-Kauf (Stripe Payment Sheet, Apple Pay, Google Pay) | `ticket_purchase_section.dart` | `functions/stripe/tickets.js` + `webhook.js` |
| Ticket-Scanner (QR-Code, Host-only) | `ticket_scanner_screen.dart` | `functions/stripe/scan.js` |
| Host-Onboarding (Stripe Connect Express) | `stripe_onboarding_screen.dart` | `functions/stripe/onboarding.js` |
| "Meine Tickets"-Übersicht (gekaufte Tickets + QR) | `my_tickets_screen.dart` | — (liest `tickets/`-Collection) |
| Ticket-Verkauf-Konfiguration in Party-Erstellung | `new_party.dart` (Sektion `_ticketSection`) | — (schreibt Felder auf Party-Doc) |
| Stripe Deep-Link-Handler (Onboarding-Return) | `Services/deep_link_handler.dart` (Hosts `stripe-return`/`stripe-refresh`) | — |

**Marker im Code:** Jeder verbleibende Aufrufpunkt erhält den Kommentar
`// FEATURE_DISABLED_TICKETING — see archived/ticketing/README.md`.

## Wie wird Ticketing später wieder aktiviert?

1. Patches aus `patches/` zurück anwenden (`git apply archived/ticketing/patches/*.patch`).
2. Dateien aus `lib/` und `functions/` zurück an ihre Originalpfade verschieben.
3. Dependencies in `pubspec.yaml` und `functions/package.json` wieder hinzufügen
   (siehe Abschnitt „Dependencies").
4. Firestore-Rules für `/tickets/{ticketId}` und `users/{uid}/stripe/*` wieder
   aktivieren (sind in `firestore.rules` als `DISABLED-TICKETING` markiert).
5. Menü-Einträge „Meine Tickets" und „Stripe Anmeldung" in `menu_screen.dart`
   wieder einkommentieren.

## Betroffene Dependencies

### `pubspec.yaml` (Flutter)

| Paket | Status | Notiz |
|---|---|---|
| `flutter_stripe: ^11.1.0` | **entfernbar** | Nur in `stripe_service.dart` + `ticket_purchase_section.dart` |
| `qr_flutter: ^4.1.0` | **entfernbar** | Nur in `ticket_purchase_section.dart` + `my_tickets_screen.dart` |
| `qr_code_scanner` (vendored unter `./vendor/qr_code_scanner`) | **entfernbar** | Nur in `ticket_scanner_screen.dart` — der gesamte `vendor/qr_code_scanner/`-Ordner kann mitarchiviert werden |

### `functions/package.json` (Node)

| Paket | Status | Notiz |
|---|---|---|
| `stripe: ^17.5.0` | **entfernbar** | Nur in `functions/stripe/*` |
| `qrcode: ^1.5.4` | **entfernbar** | Nur in `functions/stripe/*` (QR-Code im Ticket-Email-Anhang) |
| `nodemailer: ^6.9.16` | **bleibt vorerst** | Wird auch von Email-Verifizierung verwendet (siehe Risiko unten) |

## Verschobene Dateien

> Wird beim eigentlichen Move-Schritt befüllt. Hier kommt eine Tabelle:
> `Original-Pfad → archived/ticketing/...`

### Geplante Moves (Frontend)

| Original | Ziel |
|---|---|
| `lib/Services/stripe_service.dart` | `archived/ticketing/lib/Services/stripe_service.dart` |
| `lib/Screens/party/ticket_purchase_section.dart` | `archived/ticketing/lib/Screens/party/ticket_purchase_section.dart` |
| `lib/Screens/party/ticket_scanner_screen.dart` | `archived/ticketing/lib/Screens/party/ticket_scanner_screen.dart` |
| `lib/Screens/profile/my_tickets_screen.dart` | `archived/ticketing/lib/Screens/profile/my_tickets_screen.dart` |
| `lib/Screens/profile/stripe_onboarding_screen.dart` | `archived/ticketing/lib/Screens/profile/stripe_onboarding_screen.dart` |
| `vendor/qr_code_scanner/` | `archived/ticketing/vendor/qr_code_scanner/` |

### Geplante Moves (Backend)

| Original | Ziel |
|---|---|
| `functions/stripe/client.js` | `archived/ticketing/functions/stripe/client.js` |
| `functions/stripe/onboarding.js` | `archived/ticketing/functions/stripe/onboarding.js` |
| `functions/stripe/tickets.js` | `archived/ticketing/functions/stripe/tickets.js` |
| `functions/stripe/scan.js` | `archived/ticketing/functions/stripe/scan.js` |
| `functions/stripe/webhook.js` | `archived/ticketing/functions/stripe/webhook.js` |
| `functions/stripe/utils.js` | `archived/ticketing/functions/stripe/utils.js` |
| `functions/stripe/emailVerify.js` | **BLEIBT** — wird zu `functions/email/verify.js` umgezogen (dual-use, siehe Risiken) |

### Geplante Edits (NICHT verschoben, nur bearbeitet)

| Datei | Was wird entfernt |
|---|---|
| `lib/main.dart` | `StripeService.init()` + Import |
| `lib/Services/deep_link_handler.dart` | Stripe-Onboarding-Return-Handler (Hosts `stripe-return`/`stripe-refresh`), Aufruf von `StripeService.refreshHostStatus()` |
| `lib/Screens/party/new_party.dart` | Komplette Ticket-Sektion + Stripe-Status-Check (siehe Sonderabschnitt) |
| `lib/Screens/party/party_bottom_sheet.dart` | Import + Block für `TicketPurchaseSection` und `TicketScannerScreen` |
| `lib/Screens/home/menu_screen.dart` | Section „Tickets" mit `MyTicketsScreen`- und `StripeOnboardingScreen`-Tiles |
| `lib/Screens/profile/profil_settings_screen.dart` | `StripeService.requestEmailVerification`-Aufrufe (Email-Verify-Flow wandert in eigenen Service) |
| `lib/Screens/admin/admin_user_detail_screen.dart` | Stripe-Karte (`_StripeCard`), Stripe-Stream, „Stripe-Dashboard öffnen", `ticketsEnabled`-KV-Zeile |
| `functions/index.js` | Exports für `createStripeOnboardingLink`, `refreshStripeAccountStatus`, `createTicketPaymentIntent`, `stripeWebhook`, `validateAndUseTicket` |
| `firestore.rules` | `/tickets/{ticketId}` und `users/{uid}/stripe/*` als DISABLED markieren (nicht löschen) |

## Patches

Jeder nicht-triviale Edit erzeugt einen `.patch` unter `patches/`, damit
die Entfernung exakt rückgängig gemacht werden kann:

```
patches/
  001-main-remove-stripe-init.patch
  002-deep-link-remove-stripe-return.patch
  003-new-party-remove-ticket-section.patch
  004-party-bottom-sheet-remove-ticket-blocks.patch
  005-menu-screen-remove-tickets-section.patch
  006-profil-settings-decouple-email-verify.patch
  007-admin-user-detail-remove-stripe-card.patch
  008-functions-index-remove-stripe-exports.patch
  009-firestore-rules-disable-tickets.patch
  010-pubspec-remove-stripe-qr-deps.patch
  011-package-json-remove-stripe-qrcode-deps.patch
```

## Daten

- **Tickets-Collection (`tickets/`):** wird **nicht migriert, nicht angefasst**.
  Firestore-Rule für Read/Write wird hart auf `false` gesetzt (`DISABLED-TICKETING`).
- **`users/{uid}/stripe/account`-Subdocs:** bleiben unangetastet. Rule bleibt
  client-blockiert wie vorher.
- **Party-Doc-Felder (`ticketsEnabled`, `ticketPriceCents`, `ticketsAvailable`,
  `ticketsSold`):** bleiben in bestehenden Doks erhalten, neuer Party-Code
  schreibt sie nicht mehr. Lesepfade ignorieren sie.
