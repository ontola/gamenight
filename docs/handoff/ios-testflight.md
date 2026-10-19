# Handoff: TestFlight-setup voor de GameNight iOS-app

## Doel

De GameNight player-app (Flutter, `ontola/gamenight`, map `mobile/`) moet bij elke push naar `main` automatisch als iOS-build in TestFlight verschijnen. De CI-kant is al klaar; wat ontbreekt is de eenmalige setup in het Apple-account en drie GitHub-secrets.

## Wat er al is (niet aanpassen tenzij het faalt)

- `.github/workflows/mobile.yml`, job `ios` (runner `macos-latest`, alleen op `main` en `workflow_dispatch`).
  - Zonder secrets: `flutter build ios --release --no-codesign` (alleen compilecheck).
  - Met secrets: `mobile/ios/testflight.py prepare` maakt via de App Store Connect API per run een nieuw Apple Distribution-certificaat en een `IOS_APP_STORE`-profiel ("GameNight CI <run id>"), registreert de bundle ID als die nog niet bestaat, schrijft `ios/Flutter/Signing.xcconfig` en `ExportOptions.plist`, dan `flutter build ipa`, upload met `xcrun altool --upload-app`, en `testflight.py cleanup` trekt certificaat en profiel weer in.
- Bundle ID: `io.ontola.gamenight`. Buildnummer = `github.run_number` (zelfde als de Android-APK). Versie komt uit `mobile/pubspec.yaml` (`0.1.0`).
- `Info.plist` heeft `ITSAppUsesNonExemptEncryption = false`, dus geen exportcompliance-vraag per build.
- Uitleg staat ook in `mobile/README.md`, sectie "iOS and TestFlight".

## Taken

1. **Bundle ID registreren** (als die nog niet bestaat): developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → + → App IDs → App → description `GameNight`, explicit bundle ID `io.ontola.gamenight`. Geen extra capabilities nodig.
2. **App-record aanmaken** in App Store Connect → Apps → + → New App: platform iOS, naam `GameNight` (of een vrije variant als die bezet is), primaire taal Engels, bundle ID `io.ontola.gamenight`, SKU `gamenight`, volledige toegang. De API kan dit record niet zelf aanmaken, dus dit moet handmatig.
3. **API-sleutel maken**: App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → + . Naam `GameNight CI`, rol **Admin** (nodig om certificaten en profielen aan te maken). Download het `.p8`-bestand (kan maar één keer). Noteer de **Key ID** en de **Issuer ID** (staat boven de lijst).
4. **GitHub-secrets zetten** in `ontola/gamenight` (Settings → Secrets and variables → Actions → New repository secret), of met de CLI:
   - `APP_STORE_CONNECT_KEY_ID` = de Key ID
   - `APP_STORE_CONNECT_ISSUER_ID` = de Issuer ID
   - `APP_STORE_CONNECT_PRIVATE_KEY` = de volledige inhoud van het `.p8`-bestand, inclusief de `-----BEGIN PRIVATE KEY-----`- en `END`-regels

   ```sh
   gh secret set APP_STORE_CONNECT_KEY_ID -R ontola/gamenight --body "<KEY_ID>"
   gh secret set APP_STORE_CONNECT_ISSUER_ID -R ontola/gamenight --body "<ISSUER_ID>"
   gh secret set APP_STORE_CONNECT_PRIVATE_KEY -R ontola/gamenight < AuthKey_<KEY_ID>.p8
   ```
   Zet de `.p8` daarna nergens anders neer (niet committen, niet in chat plakken).
5. **Build starten**: Actions → "Mobile app" → Run workflow op `main` (of `gh workflow run mobile.yml -R ontola/gamenight --ref main`). Kijk naar de job `ios`.
6. **Interne testgroep**: App Store Connect → de app → TestFlight → Internal Testing → + → groep `GameNight`, zet "Enable automatic distribution" aan en voeg Joep (joep@ontola.io) toe. Na verwerking (meestal 5 tot 30 minuten) staat de build in de TestFlight-app op de iPhone.

## Bekende risico's en wat te doen

- **"There is a problem with the request entity ... maximum number of certificates"** bij `prepare`: het team heeft al te veel Apple Distribution-certificaten. Trek een ongebruikt certificaat in onder Certificates, of een achtergebleven exemplaar van een eerdere afgebroken CI-run.
- **401/403 van de API**: sleutel heeft niet de rol Admin, of `APP_STORE_CONNECT_PRIVATE_KEY` mist de BEGIN/END-regels of regeleindes.
- **Upload faalt met "No suitable application records were found"**: stap 2 (app-record) ontbreekt of de bundle ID wijkt af.
- **Upload faalt omdat buildnummer al bestaat**: start de workflow opnieuw (nieuw run number).
- **Signing-fout tijdens `flutter build ipa`** (bijv. pods die een profiel krijgen, of `security import` die de p12 weigert): het signing-mechanisme zit in `mobile/ios/testflight.py` en `mobile/ios/Flutter/Release.xcconfig` (die `#include? "Signing.xcconfig"` doet, zodat alleen het Runner-target gesigneerd wordt). Fix daar, push direct naar `main` (dit project gebruikt geen PR's).
- Na een afgebroken run kan een certificaat blijven staan; de cleanup-stap draait ook bij annuleren, maar controleer bij twijfel de lijst met certificaten.

## Niet in scope

- Universal links (sign-in-link uit de e-mail opent nu Safari, de code plakken in de app werkt wel). Kan later met Associated Domains en een `apple-app-site-association` op gamenight.ontola.io.
- App Store-publicatie; alleen TestFlight.

## Klaar wanneer

De `ios`-job van "Mobile app" is groen op `main` met de stap "Upload to TestFlight", en de build is te installeren via de TestFlight-app.
