# Arco — checklista ręcznej konfiguracji

Wszystko w tym pliku to robota, którą człowiek musi wykonać poza repozytorium: konta do założenia,
identyfikatory do zarejestrowania, sekrety do wklejenia. Przy każdym punkcie jest napisane, **kiedy go
potrzebujesz**, więc możesz grać ze znajomymi długo przed tym, zanim tkniesz sklep z aplikacjami.

Legenda: **[play]** potrzebne, żeby grać z innymi ludźmi przez internet · **[store]** potrzebne do publikacji ·
**[money]** potrzebne dopiero wtedy, gdy coś sprzedajesz.

## Stan rzeczy

| sekcja | stan |
|---|---|
| 1. Serwer online | **zrobione** — https://arco.fly.dev, Frankfurt, na wolumenie, migawki włączone |
| 2-5, 8. Konta deweloperskie i logowanie | nie zaczęte; aplikacja działa bez nich |
| 6, 7. Wpis w sklepie, ikona | nie zaczęte |
| 9, 10. Odblokowanie i reklamy | nie zaczęte; oba zbudowane i wyłączone. **9 wymaga wcześniej skończonej 8** — patrz 9.0 |
| 12.1 Kopie zapasowe | **częściowo zrobione** — Fly utworzył wolumen z zaplanowanymi migawkami; odtworzenie nigdy nie było przećwiczone |
| 12.2 Monitoring, 12.4 Strona wsparcia, 12.5 Kategoria wiekowa | nie zaczęte |
| 12.6 Kod poza laptopem | **zrobione** — github.com/tymonq19/ARCO |

**Nic poniżej nie blokuje grania.** Serwer stoi, więc duel między dwoma telefonami działa już dziś. Wszystko,
co zostało, dotyczy publikacji, sprzedaży albo tego, żeby później czegoś nie stracić.

---

## Co robić dalej, po kolei

Kolejność nie jest dowolna. Każdy punkt jest tu dlatego, że albo blokuje następne, albo trwa
dłużej, niż się wydaje.

1. **Wgraj kompilację 1.0.0+6 Transporterem** i przeklikaj ją z TestFlight na prawdziwym
   telefonie. Serwer jest już na wersji protokołu 3, więc starsze kompilacje z TestFlight nie
   wyślą wyniku ani nie zagrają w duel, dopóki tester nie zaktualizuje aplikacji — patrz 12.3a.
2. **Ustaw repozytorium na prywatne** na GitHubie. Settings → General → na samym dole Danger
   zone → Change repository visibility.
3. **Sekcja 2, konto Apple Developer.** Nic ze sklepu, logowania ani sprzedaży nie ruszy bez
   niego, a weryfikacja tożsamości po stronie Apple potrafi zająć kilka dni.
4. **Sekcja 8, logowanie.** To już nie jest ozdoba: od teraz konto jest wymagane przy zakupie,
   więc bez tej sekcji nie ma sensu włączać sprzedaży — powód jest w 9.0. Pamiętaj o 8.2:
   projekt nie zawiera pliku uprawnień, więc Sign in with Apple nie zadziała, dopóki nie dodasz
   uprawnienia w Xcode i w App ID.
5. **Sekcja 9, sprzedaż.** Zacznij od umowy Paid Applications, podatków i danych bankowych w
   App Store Connect, bo to jest najdłuższy element całej listy i możesz go załatwić równolegle
   ze wszystkim innym. Produkt, klucz `.p8`, RevenueCat i sekrety serwera są potem szybkie.
6. **Sekcja 10, reklamy.** Całą ścieżkę możesz przejść dziś, bez konta AdMob, na testowych
   jednostkach Google — patrz 10.1. Konto zakładaj, kiedy chcesz prawdziwego przychodu. Jeden
   krok jest obowiązkowy dla Europy: opublikowany komunikat zgody z 10.6, inaczej europejscy
   gracze nigdy nie zobaczą przycisku reklamy.
7. **Sekcje 6 i 7, wpis w sklepie.** Opis, zrzuty ekranu, ikona. Robota na wieczór, ale bez niej
   nie ma publikacji.
8. **Sekcja 12, utrzymanie.** Najpilniejsze jest 12.1: migawki wolumenu są włączone, ale
   odtworzenia bazy nigdy nie przećwiczyłeś, a kopia, której nie odtworzyłeś, nie jest jeszcze
   kopią. Dalej monitoring, regulamin i adres wsparcia oraz klasyfikacja wiekowa.

Nic z powyższego nie blokuje grania. Serwer żyje, duel między dwoma telefonami działa dziś.
Wszystko, co zostało, dotyczy publikowania, sprzedawania albo nietracenia rzeczy później.

---

## 1. Postaw serwer w internecie — [play] — ZROBIONE

Duele i globalna tablica wyników rozmawiają z twoim własnym serwerem. Dopóki nie jest osiągalny z internetu,
gra działa tylko na twojej maszynie.

**To jest już zrobione.** Co teraz istnieje:

| | |
|---|---|
| adres | `https://arco.fly.dev` |
| region | `fra` (Frankfurt) — Fly nie ma regionu w Warszawie; ten jest najbliższy, około 20 ms od Warszawy |
| maszyna | jedna, `auto_stop_machines = "off"`, żeby pokoje dueli trzymane w pamięci nigdy nie przepadły |
| wolumen | `arco_data`, 1 GB, zaszyfrowany, zamontowany w `/app/data`, zaplanowane migawki z 5-dniową retencją |
| sprawdzone | `/api/health` odpowiada, zapisana powtórka solo została przyjęta i trafiła na listę, zmanipulowany wynik został odrzucony, a duel przeszedł po dwóch WebSocketach |

Konfiguracja siedzi w `fly.toml` i jest zacommitowana. Po zmianie w kodzie wdróż ponownie przez `fly deploy` z
katalogu głównego repozytorium. Kroki poniżej zostają jako zapis tego, jak to zrobiono i co powtórzyć, jeśli
kiedyś będziesz zmieniać hosting.

1. Zainstaluj narzędzie wiersza poleceń Fly.io i zaloguj się. Karta jest wymagana nawet na planie w darmowej skali.
2. Z katalogu głównego repozytorium utwórz aplikację. Dockerfile jest już poprawny, więc zaakceptuj go, gdy zapyta.
   ```bash
   fly launch --name arco --no-deploy
   ```
   Jeśli nazwa jest zajęta, wybierz inną i zapamiętaj ją; staje się `https://<name>.fly.dev`.
3. Utwórz wolumen na bazę danych, w tym samym regionie co aplikacja:
   ```bash
   fly volumes create arco_data --size 1
   ```
   Sprawdź, czy `fly.toml` montuje ten wolumen w `/app/data` i czy `DB_PATH` wskazuje do jego wnętrza.
4. Wdróż i sprawdź:
   ```bash
   fly deploy
   curl https://<your-app>.fly.dev/api/health
   ```
   Chcesz zobaczyć `{"ok":true,...}`. Ścieżka to `/api/health`, nie `/health`.
5. Zbuduj aplikację pod ten adres:
   ```bash
   flutter run --dart-define=SERVER_URL=https://<your-app>.fly.dev
   ```
   Adres można też zmienić w trakcie działania w Ustawieniach, w sekcji Zaawansowane, co jest wygodne przy testach.

Koszt przy tej skali to kilka dolarów miesięcznie. Zadziała każdy hosting, który uruchamia kontener; Railway i
Render potrzebują tych samych dwóch rzeczy: instancji działającej bez przerwy i trwałego wolumenu.

### Zmienne środowiskowe, które czyta serwer

| zmienna | domyślnie | znaczenie |
|---|---|---|
| `PORT` | 8080 | port nasłuchu |
| `DB_PATH` | `data/arco.db` | plik SQLite, musi leżeć na zamontowanym wolumenie |
| `VERIFY_REPLAYS` | `strict` | zostaw strict; `off` wyłącza weryfikację tablicy wyników |
| `LOG_LEVEL` | `info` | `debug`, kiedy dopiero wszystko ustawiasz |
| `ACCOUNTS_ENABLED` | `off` | `on` włącza logowanie Apple i Google |
| `APPLE_CLIENT_IDS` | nieustawione | rozdzielone przecinkami, patrz sekcja 3 |
| `GOOGLE_CLIENT_IDS` | nieustawione | rozdzielone przecinkami, patrz sekcja 4 |
| `PURCHASES_ENABLED` | `off` | `on` włącza jednorazowe odblokowanie, patrz sekcja 9 — [money] |
| `REVENUECAT_WEBHOOK_SECRET` | nieustawione | **sekret**, patrz sekcja 9 — [money] |
| `REVENUECAT_API_KEY` | nieustawione | **sekret**, patrz sekcja 9 — [money] |
| `PURCHASES_SANDBOX` | `off` | `on` nadaje premium z zakupów w sandboksie; tylko staging — [money] |

Ustawiasz je przez `fly secrets set NAME=value`. Przy `ACCOUNTS_ENABLED=on` i bez client id serwer odmawia
startu, i to celowo: bez id, względem którego sprawdza tokeny, token wystawiony dla dowolnej innej aplikacji
zostałby przyjęty. To samo dotyczy `PURCHASES_ENABLED=on` bez obu sekretów RevenueCat: bez sekretu webhooka
każdy mógłby zgłosić zakup, a bez klucza API serwer nie może sam go ponownie zweryfikować.

---

## 2. Konto Apple Developer — [store], a na prawdziwym iPhonie także [play]

Członkostwo kosztuje 99 USD rocznie, a weryfikacja tożsamości może zająć kilka dni, więc zacznij wcześnie.

1. Zarejestruj się na developer.apple.com.
2. W Certificates, Identifiers and Profiles zarejestruj App ID z bundle identifier
   **`com.jtadevs.arco`**. Musi zgadzać się z projektem dokładnie.
3. Włącz dla tego App ID uprawnienie **Sign in with Apple**.
4. W Xcode otwórz `ios/Runner.xcworkspace`, wybierz target Runner, Signing and Capabilities, wskaż swój
   team i dodaj uprawnienie **Sign in with Apple** również tam, żeby trafiło ono do kompilacji.
5. Do testów na własnym iPhonie wystarczy darmowy personal team; płatne członkostwo jest do dystrybucji.

---

## 3. Sign in with Apple — [store]

1. App ID z sekcji 2 z włączonym uprawnieniem to główny client id. Jest nim twój bundle identifier,
   `com.jtadevs.arco`.
2. Tylko jeśli wydajesz też kompilację web: utwórz **Services ID**, włącz na nim Sign in with Apple i dodaj
   swoją domenę web oraz return URL. Jego identyfikator to drugi client id.
3. Wrzuć na serwer każdy id, którego używasz:
   ```bash
   fly secrets set APPLE_CLIENT_IDS=com.jtadevs.arco
   fly secrets set ACCOUNTS_ENABLED=on
   ```
4. Potem sprawdź `GET /api/health`. Jego pole `accounts` musi zawierać `apple`. Aplikacja pokazuje tylko te
   przyciski, które ogłasza to pole, więc pusta lista oznacza, że nie pokaże żadnego.

---

## 4. Google Sign-In — [store]

1. Utwórz projekt w konsoli Google Cloud i skonfiguruj OAuth consent screen [ekran zgody]. Aplikacja używana
   przez kogokolwiek poza twoim własnym kontem wymaga jego opublikowania, a ta weryfikacja zajmuje czas.
2. Utwórz client id OAuth:
   - **iOS**, z bundle id `com.jtadevs.arco`,
   - **Android**, z pakietem `com.jtadevs.arco` i odciskiem SHA-1 twojego klucza podpisującego,
   - **Web**, tylko jeśli wydajesz kompilację web.
3. Podaj serwerowi każdy id, który może pojawić się w tokenie:
   ```bash
   fly secrets set GOOGLE_CLIENT_IDS=<ios id>,<android id>
   ```
4. Strona klienta potrzebuje jeszcze plików konfiguracyjnych i URL scheme; dokładne klucze są wypisane w
   sekcji 8, wypełnionej na podstawie implementacji.

Pamiętaj o zasadzie Apple: aplikacja iOS, która oferuje logowanie Google, musi oferować też Sign in with Apple.
Oba są zbudowane, więc po prostu nie włączaj samego Google.

---

## 5. Podpisywanie na Androidzie — [store]

1. Utwórz upload keystore i trzymaj go tam, gdzie go nie zgubisz. Jego utrata oznacza, że nie zaktualizujesz
   własnej aplikacji.
2. Wskaż go w `android/key.properties` i upewnij się, że ten plik nie jest commitowany.
3. Weź SHA-1 klucza upload oraz klucza app signing Google Play i wstaw oba do klienta OAuth Android z sekcji 4.
   Zapomnienie o drugim to typowy powód, dla którego logowanie działa w testach i pada na produkcji.

---

## 6. Wpisy w sklepach — [store]

Oba sklepy potrzebują tego samego materiału, więc przygotuj go raz:

- Nazwa **Arco**, krótki podtytuł i opis — najpierw po angielsku, potem po polsku.
- Ikona 1024 na 1024, bez przezroczystości i bez zaokrąglonych narożników.
- Zrzuty ekranu z wymaganych rozmiarów urządzeń. Cztery motywy dają ci wizualnie różne kadry za darmo.
- Polityka prywatności pod publicznym URL. Trzymaj ją uczciwą i krótką: gra przechowuje nick, wyniki,
  przybliżony kraj z locale urządzenia oraz — tylko jeśli gracz się zaloguje — nieprzejrzysty identyfikator od
  Apple albo Google. Nie przechowuje adresu e-mail ani prawdziwego imienia.
- Ankieta age rating [klasyfikacja wiekowa]. Nie ma treści budzących zastrzeżenia, ale tablicę wyników online
  z nickami wybieranymi przez graczy warto zadeklarować, a filtr nicków to twoja odpowiedź na pytanie dalsze.
- Export compliance: aplikacja używa tylko standardowego HTTPS, czyli zwykłe wyłączenie.

---

## 7. Ikona i launch screen — [store]

Projekt nadal zawiera zastępczą ikonę Fluttera. Podmień zestawy ikon w `ios/Runner/Assets.xcassets`
i `android/app/src/main/res` oraz launch screen w `ios/Runner/Base.lproj`. Pierwsze zimne uruchomienie pokazuje
launch screen, więc zwykłe ciemne tło z logotypem czyta się lepiej niż białe mignięcie.

---

## 8. Konfiguracja logowania po stronie platform — [store]

Wszystko poniżej to praca po stronie platform, której żaden kod Dart nie zrobi za ciebie. Dopóki nie jest
zrobiona, przyciski logowania albo się nie pokazują (bo `GET /api/health` nic nie ogłasza), albo padają po
tapnięciu. W obu przypadkach aplikacja degraduje się po cichu i zostaje w pełni grywalna, więc nic z tego nie
blokuje wydania kompilacji bez kont.

Paczki są już w `pubspec.yaml`: `sign_in_with_apple: ^8.1.0` i `google_sign_in: ^7.2.0`.

### 8.1 Wartości compile-time, które czyta aplikacja

To publiczne identyfikatory, nie sekrety, i serwer nigdy im nie ufa — sprawdza `aud` tokenu względem własnych
`APPLE_CLIENT_IDS` / `GOOGLE_CLIENT_IDS`. Patrz `lib/app/account_config.dart`.

| `--dart-define` | potrzebne dla | wartość |
|---|---|---|
| `GOOGLE_CLIENT_ID` | iOS / macOS | client id OAuth **iOS**, `…apps.googleusercontent.com`. Opcjonalne, jeśli zamiast tego wstawisz `GIDClientID` do `Info.plist` (8.3). |
| `GOOGLE_SERVER_CLIENT_ID` | **Android** | client id OAuth **Web** z tego samego projektu. Bez niego Android nie zwraca żadnego `idToken`, a aplikacja zgłasza „that sign-in returned nothing to verify”. Ten id jest `aud`, który nosi token, więc to jego musi zawierać `GOOGLE_CLIENT_IDS` dla Androida. |
| `APPLE_SERVICE_ID` | tylko Android | **Services ID** Apple dla flow web. Bez niego (i bez następnego) przycisk Apple nie jest oferowany na Androidzie. |
| `APPLE_REDIRECT_URI` | tylko Android | Return URL zarejestrowany na tym Services ID, np. `https://arco.example.com/callbacks/sign_in_with_apple`. |

Przykładowa kompilacja release:

```bash
flutter build ipa --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=GOOGLE_CLIENT_ID=123-ios.apps.googleusercontent.com
flutter build appbundle --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=123-web.apps.googleusercontent.com
```

### 8.2 iOS — Sign in with Apple

1. App ID `com.jtadevs.arco` potrzebuje uprawnienia **Sign in with Apple** (sekcja 2).
2. W Xcode: target Runner → Signing and Capabilities → **+ Capability** → Sign in with Apple. To wpisuje
   `com.apple.developer.applesignin = ["Default"]` do `ios/Runner/Runner.entitlements` i wiąże uprawnienie
   z twoim provisioning profile. Repozytorium celowo nie zawiera tego uprawnienia: kompilacja podpisana
   App ID bez tego uprawnienia nie daje się zainstalować.
3. Nic więcej. Żadnego klucza w `Info.plist`, żadnego URL scheme, a `aud` tokenu to bundle id — czyli
   `APPLE_CLIENT_IDS=com.jtadevs.arco` na serwerze.
4. Wymaga iOS 13 albo nowszego. Projekt celuje już w 13.0, a poniżej tego aplikacja ukrywa przycisk.

### 8.3 iOS — Google Sign-In

1. Utwórz klienta OAuth **iOS** (sekcja 4) i pobierz jego `GoogleService-Info.plist` — albo po prostu przepisz
   z niego dwie wartości.
2. Dodaj do `ios/Runner/Info.plist`:
   ```xml
   <key>GIDClientID</key>
   <string>123-ios.apps.googleusercontent.com</string>
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleTypeRole</key><string>Editor</string>
       <key>CFBundleURLSchemes</key>
       <array><string>com.googleusercontent.apps.123-ios</string></array>
     </dict>
   </array>
   ```
   URL scheme to **odwrócona** forma client id, dokładnie taka, jaką pokazuje konsola. Bez niego sheet
   Google się otwiera i nigdy nie wraca.
3. `GIDClientID` i `--dart-define=GOOGLE_CLIENT_ID` robią to samo; przekazany define wygrywa. Użyj jednego.
4. Nie potrzeba żadnego uprawnienia ani grupy keychain sharing.

### 8.4 Android — Google Sign-In

1. Utwórz klienta OAuth **Android** z pakietem `com.jtadevs.arco` i SHA-1 *obu* kluczy: twojego upload
   i app signing Play (sekcja 5).
2. Utwórz też klienta OAuth **Web** i przekaż go jako `--dart-define=GOOGLE_SERVER_CLIENT_ID`. Android bierze
   swój `idToken` z tego id.
3. `google_sign_in` 7.x używa Credential Manager, więc **nie** ma żadnego `google-services.json` ani pluginu
   Gradle `com.google.gms.google-services` do dodania. `android/app/build.gradle.kts` nie potrzebuje nowego
   wpisu; manifest i zależności samej paczki scala Flutter.
4. `minSdk` musi być 21 albo wyżej, co `flutter.minSdkVersion` już spełnia.

### 8.5 Android — Sign in with Apple (opcjonalnie)

Na Androidzie nie ma natywnego logowania Apple; paczka otwiera webowy flow Apple w Chrome Custom Tab.

1. Utwórz w Apple **Services ID**, włącz na nim Sign in with Apple i zarejestruj Return URL, który
   kontrolujesz.
2. Ten URL musi być prawdziwym endpointem: dostaje `POST` od Apple i musi przekierować z powrotem do aplikacji
   przez `intent://callback?...#Intent;package=com.jtadevs.arco;scheme=signinwithapple;end`. README paczki ma
   ten dwulinijkowy handler.
3. Dodaj do `android/app/src/main/AndroidManifest.xml` intent filter opisany w dokumentacji paczki (scheme
   `signinwithapple`, host `callback`).
4. Przekaż `APPLE_SERVICE_ID` i `APPLE_REDIRECT_URI` oraz dodaj Services ID do `APPLE_CLIENT_IDS` na serwerze
   — `aud` webowego flow to Services ID, nie bundle id.
5. Spokojnie można to wszystko pominąć: aplikacja oferuje wtedy na Androidzie tylko Google, na co zasada Apple
   pozwala, bo dotyczy tylko tego, co oferuje iOS.

### 8.6 Po stronie serwera

```bash
fly secrets set ACCOUNTS_ENABLED=on
fly secrets set APPLE_CLIENT_IDS=com.jtadevs.arco
fly secrets set GOOGLE_CLIENT_IDS=123-ios.apps.googleusercontent.com,123-web.apps.googleusercontent.com
```

Dostawca bez client id nie jest ogłaszany, więc start tylko z Apple po prostu zostawia `GOOGLE_CLIENT_IDS`
nieustawione. `GET /api/health` to jedyne źródło prawdy o tym, które przyciski pokazuje aplikacja: jeśli
`accounts` to `[]`, logowanie nie pojawia się nigdzie w aplikacji i nie ma martwych przycisków do tłumaczenia.

### 8.7 Co sprawdzić na urządzeniu

- `GET /api/health` wypisuje dostawców, których skonfigurowałeś.
- Na iOS oba przyciski pojawiają się na karcie końca gry po rekordzie osobistym, Apple pierwszy.
- Anulowanie sheeta nie robi zupełnie nic — żadnego błędu, żadnego komunikatu.
- Zalogowanie się na drugim urządzeniu mówi „Welcome back”, a tablica wyników podświetla te same przebiegi.
- Ustawienia → Konto pokazuje dostawcę i datę, a **USUŃ MOJE KONTO** wymaga dwóch tapnięć przez dwa różne
  dialogi.
- Web: nic o logowaniu się nie pokazuje, i to celowo — kompilacja przeglądarkowa nie ma keychaina, w którym
  trzymałaby poświadczenie.

---

## 9. Jednorazowe odblokowanie (RevenueCat) — [money]

Nic z tego nie jest potrzebne do wydania. Gra jest bez tego kompletna: każdą ozdobę można zdobyć za Iskry, grając,
200 dziennie, codziennie, i nic w grze nie jest za opłatą. Dopóki nie skończysz tej sekcji, serwer odpowiada
`404 purchases_disabled`, w sklepie nie ma nic do kupienia i nie ma martwego przycisku, który trzeba by tłumaczyć.

Sprzedajesz **jeden produkt, kupowany raz**: produkt niekonsumowalny, który odblokowuje każdą istniejącą ozdobę i
każdą dodaną później, i wyłącza reklamy, na zawsze. Nie ma drugiego poziomu ani paczki Iskier.

Dwie połowy muszą się zgadzać: **sklepy** decydują, ile to kosztuje, a **nasz serwer** decyduje, co to daje. Cena
nigdy nie pojawia się w naszym kodzie ani w aplikacji — aplikacja wypisuje to, co poda jej StoreKit albo Google
Play, w walucie gracza, z podatkiem jego rynku. Zmiana ceny to zmiana w App Store Connect albo w Play Console i nic
więcej. Celuj w kilkanaście złotych, bliżej dolnej połowy tego przedziału; próg cenowy wybierz w sklepie, nie tutaj.

### 9.0 Najpierw włącz konta — ta część nie jest opcjonalna

Zrób sekcję 8 (logowanie), **zanim** włączysz zakupy, i sprawdź, czy `GET /api/health` zwraca niepustą listę
`accounts`. To nie kwestia porządku, to różnica między zakupem, który da się odzyskać, i takim, którego nie da się
odzyskać.

Odblokowanie jest zapisywane przy graczu. Anonimowy gracz istnieje tylko w pęku kluczy tego telefonu, więc usunięcie
aplikacji go niszczy, a następne uruchomienie to już inna osoba. Nadanie jest kluczowane na transakcji ze sklepu, a
transakcja już zapisana przy innym graczu nie daje wywołującemu nic — celowo, bo właśnie to blokuje odblokowanie
komuś obcemu z wyciekniętego paragonu. Złóż to razem i gracz, który zapłacił, a potem zainstalował aplikację
ponownie, dostaje „nie było nic do przywrócenia”, podczas gdy baza danych wyraźnie widzi, że zapłacił. Zwrot
pieniędzy, zła opinia i kłótnia z recenzją App Store, która oczekuje, że Restore Purchases działa dla produktu
niekonsumowalnego.

Aplikacja zamyka to, prosząc o konto **przed arkuszem płatności**, więc to, co kupione, od pierwszej chwili należy do
konta, a ponowna instalacja odzyskuje je przez ponowne zalogowanie. Ale ta bramka **sama się znosi**, gdy wdrożenie
nie ogłasza żadnych dostawców logowania, bo bramka, której nikt nie przejdzie, byłaby sklepem odmawiającym przyjęcia
pieniędzy. Zatem:

| konta | zakupy | co się dzieje |
|---|---|---|
| wył. | wył. | dzisiaj. Nie ma czego sprzedawać, nie ma czego stracić. |
| **wył.** | **wł.** | **pułapka.** Pieniądze są pobierane i nie da się ich odzyskać po ponownej instalacji. Nie wydawaj tego. |
| wł. | wył. | w porządku. Gracze mogą się zalogować, żeby zachować swoją pozycję na tablicy wyników. |
| wł. | wł. | to, czego chcesz. |

Jeśli już coś sprzedałeś w układzie ze środkowego wiersza, naprawą dla tych graczy jest ręczne nadanie przy ich nowym
player id; nie ma ścieżki samoobsługowej i celowo nie ma endpointu administracyjnego.

### 9.1 Identyfikator produktu

Utwórz **ten sam identyfikator** w obu sklepach. Jest już w `server/lib/src/catalogue.dart`; jeśli zmienisz go tam,
zmień go w obu sklepach i w RevenueCat też, inaczej webhook zostanie odrzucony jako `unknown_product`.

| id produktu | typ | co daje serwer |
|---|---|---|
| `arco.unlock.full` | produkt niekonsumowalny | każda ozdoba, obecna i przyszła; brak reklam |

**Produkt niekonsumowalny**, w obu sklepach — App Store Connect nazywa to *Non-Consumable*, Play Console
*one-time product*. Kupuje się go raz, a sklepy pamiętają to na zawsze, i to właśnie czyni z **Restore purchases**
prawdziwą funkcję, a nie tłumaczenie się. Produkt konsumowalny byłby tu błędem w obie strony: można by go kupić
ponownie i nie można by go przywrócić.

Jeśli utworzyłeś w którymś sklepie stare produkty konsumowalne `arco.sparks.small|medium|large`, zostaw je w spokoju
albo oznacz jako niedostępne — nic nie zostało wydane, nikt żadnego nie ma, a serwer odrzuca webhook, który je
wymienia, zamiast cokolwiek za nie nadać.

### 9.2 App Store Connect

1. My Apps → Arco → **In-App Purchases** → utwórz jeden produkt **Non-Consumable** z identyfikatorem powyżej.
2. Nadaj mu reference name (nazwa wewnętrzna), display name (nazwa wyświetlana) i opis w każdym języku, który
   wydajesz (angielski i polski), i wybierz próg cenowy. Apple wypełni z progu każdy rynek; nie próbuj tego
   odwzorowywać w kodzie.
3. Wgraj zrzut ekranu zakupu w aplikacji i notatkę dla recenzenta. Produkt jest sprawdzany **oddzielnie od
   kompilacji** i nie da się go kupić, dopóki nie zostanie zatwierdzony.
4. Agreements, Tax, and Banking → uzupełnij umowę **Paid Applications**, formularze podatkowe i dane bankowe.
   Nic nie może być sprzedane, dopóki to nie jest zrobione, a zajmuje to dłużej niż kod.
5. Users and Access → **Integrations** → App Store Server Notifications / In-App Purchase keys: utwórz
   **In-App Purchase key** i pobierz `.p8`. RevenueCat go potrzebuje (9.4).

### 9.3 Google Play Console

1. Monetise → Products → **In-app products** → utwórz jeden produkt z tym samym identyfikatorem, z ceną oraz nazwą
   i opisem na język, i **aktywuj** go.
2. Monetise with Play → **Payments profile**: uzupełnij konto sprzedawcy, dane podatkowe i bankowe.
3. Setup → API access: połącz projekt Google Cloud, utwórz **service account** (konto usługi) z uprawnieniami
   *Financial data* i *Manage orders*, nadaj mu dostęp w Play Console i pobierz jego **klucz JSON**. RevenueCat go
   potrzebuje (9.4).
4. Aplikacja musi być choć raz wgrana na jakiś track, zanim można utworzyć produkty in-app.

### 9.4 RevenueCat

1. Utwórz projekt. Dodaj aplikację **App Store** (bundle id `com.jtadevs.arco`, wgraj klucz In-App Purchase `.p8`
   z 9.2) i aplikację **Play Store** (nazwa pakietu, wgraj JSON konta usługi z 9.3).
2. Products → zaimportuj albo dodaj `arco.unlock.full` dla obu sklepów.
3. **Entitlements** → utwórz jedno z identyfikatorem **`premium`** i przypisz do niego produkty z obu sklepów. Teraz
   to *jest* potrzebne i to jest ten akapit, który zmienił się, gdy paczki stały się jednym odblokowaniem:
   uprawnienie to sposób, w jaki RevenueCat modeluje trwałą rzecz, którą klient albo ma, albo nie, a dokładnie tym
   jest produkt niekonsumowalny. (Przy starych produktach konsumowalnych nie było nic trwałego do przypisania, i
   dlatego wcześniej było tu napisane, że uprawnienia nie są potrzebne.)

   Uprawnienie jest tym, co nadaje sens sprawdzeniu customer info przez samą aplikację, i serwer też je czyta — ale
   **nigdy jako podstawę nadania**: uprawnienie nie nosi identyfikatora transakcji ze sklepu, a identyfikator
   transakcji jest kluczem idempotencji, który blokuje ponowne odblokowanie po zwrocie pieniędzy. Jeśli RevenueCat
   raportuje uprawnienie, a serwer nie ma pasującej transakcji, serwer loguje

   ```
   RevenueCat reports the "premium" entitlement for player=… but no arco.unlock.full transaction
   ```

   co znaczy, że produkt jest przypisany do złego uprawnienia albo do żadnego, albo ktoś nadał uprawnienie ręcznie w
   panelu. To jedyne ostrzeżenie o zakupach, które wymaga człowieka w panelu.
4. **API keys** — są dwa rodzaje i nie są wymienne:

   | klucz | gdzie idzie | sekret? |
   |---|---|---|
   | **publiczny klucz SDK**, `appl_…` (iOS) | `--dart-define=REVENUECAT_IOS_KEY=…` (9.5) | nie — jest w każdej kompilacji |
   | **publiczny klucz SDK**, `goog_…` (Android) | `--dart-define=REVENUECAT_ANDROID_KEY=…` (9.5) | nie |
   | **sekretny klucz API**, `sk_…` | `REVENUECAT_API_KEY` serwera (9.6) | **tak — tylko serwer, nigdy w aplikacji** |

5. **Webhook**: Integrations → Webhooks → dodaj jeden.
   - URL: `https://<your-server>/api/purchases/webhook`
   - Wartość nagłówka Authorization: wymyśl długi losowy ciąg (`openssl rand -hex 32`) i wklej go tutaj. **Ten
     sam** ciąg wchodzi do `REVENUECAT_WEBHOOK_SECRET` serwera (9.6). Wklej go identycznie w oba miejsca;
     `Bearer <string>` też jest akceptowane, ale wybierz jedną formę i jej się trzymaj.
   - Event types: wszystkie są w porządku. Serwer nadaje na `NON_RENEWING_PURCHASE` i `INITIAL_PURCHASE`, odbiera
     na `CANCELLATION` i `REFUND`, a wszystko inne potwierdza `200`, żeby RevenueCat przestał ponawiać. Produkt
     niekonsumowalny przychodzi jako `NON_RENEWING_PURCHASE`: RevenueCat używa tego typu dla każdego zakupu, który
     nie będzie się automatycznie odnawiał.
6. Zostaw **App User IDs** w spokoju. Aplikacja ustawia app user id w RevenueCat na samo player id z Arco, i to
   właśnie pozwala webhookowi wskazać gracza bez żadnej tabeli mapowania pośrodku — i to pozwala przywracaniu
   zakupów znaleźć znów tego samego gracza.

### 9.5 Wartości kompilacyjne, które czyta aplikacja

Publiczne klucze SDK, po jednym na platformę, w `lib/app/purchase_config.dart`. To nie sekrety: publiczny klucz SDK
jest wbudowany w każdą kompilację każdej aplikacji używającej RevenueCat, może robić zakupy tylko *dla tej
aplikacji*, a nasz serwer nigdy nie wierzy w nic, co SDK z jego użyciem powie.

| `--dart-define` | potrzebne dla | wartość |
|---|---|---|
| `REVENUECAT_IOS_KEY` | iOS | **publiczny** klucz SDK iOS z RevenueCat, `appl_…` |
| `REVENUECAT_ANDROID_KEY` | Android | **publiczny** klucz SDK Android z RevenueCat, `goog_…` |

Gdy nie jest ustawiony żaden, aplikacja raportuje sklep jako niedostępny i w sklepie nie ma nic do kupienia — i
dokładnie to powinien widzieć fork bez projektu w RevenueCat.

```bash
flutter build ipa --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=REVENUECAT_IOS_KEY=appl_xxxxxxxxxxxxxxxxxxxxxxxx
flutter build appbundle --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=REVENUECAT_ANDROID_KEY=goog_xxxxxxxxxxxxxxxxxxxxxxxx
```

### 9.6 Strona serwera

```bash
fly secrets set PURCHASES_ENABLED=on
fly secrets set REVENUECAT_WEBHOOK_SECRET=<the same string you pasted into RevenueCat>
fly secrets set REVENUECAT_API_KEY=sk_xxxxxxxxxxxxxxxxxxxxxxxx
# tylko staging — nadaje premium z zakupów sandbox, żebyś mógł testować, zanim pojawią się prawdziwe pieniądze:
# fly secrets set PURCHASES_SANDBOX=on
```

Oba sekrety są wymagane przy włączonym przełączniku, a serwer bez nich **odmawia startu**. Ustawienie ich przy
wyłączonym `PURCHASES_ENABLED` startuje normalnie i loguje ostrzeżenie, bo ta kombinacja to prawie zawsze pomyłka.
Żaden z nich nigdy nie trafia do logów.

Linia startowa, której szukasz, to `purchases enabled: arco.unlock.full (entitlement "premium"), sandbox ignored`.

`GET /api/health` to jedyne źródło prawdy o *wdrożeniu*: `"purchases": true` znaczy, że może przyjmować pieniądze i
aplikacja zaoferuje odblokowanie; `false` znaczy, że nie będzie, i nie ma nikomu nic do tłumaczenia. Czy *gracz* jest
premium, mówi `GET /api/shop/inventory` (`"premium": true`), i tylko na tym aplikacja działa.

### 9.7 Zobaczyć arkusz płatności bez żadnego konta App Store (symulator)

`ios/Arco.storekit` to wersjonowana **konfiguracja StoreKit**: produkt z §9.1 jako niekonsumowalny, z ceną
zastępczą. Jest już wskazana w akcji Run współdzielonego schematu `Runner`, więc nie ma czego konfigurować —
istnieje po to, żeby arkusz, cenę i cały przepływ zakupu można było przejść na symulatorze, zanim ktokolwiek ma
produkt w App Store Connect albo sandboxowe Apple ID.

Jej cena jest **zastępcza i nie jest pokazywana przez nic poza tym plikiem**: aplikacja wypisuje to, co poda jej
StoreKit (§9.1), więc to, co widzisz na symulatorze, mówi ten plik, a to, co widzi gracz, mówi Apple.

**Działa tylko wtedy, gdy aplikację uruchamia Xcode.** Otwórz `ios/Runner.xcworkspace` i wciśnij Run. Xcode
synchronizuje konfigurację do symulatora w ramach uruchamiania (`DVTDevice
handleStoreKitConfigurationSyncForBundleID:configurationFilePath:`); `flutter run` i `flutter test` instalują i
uruchamiają przez `simctl`, który tego nie robi, więc StoreKit odpowiada na te uruchomienia **brakiem produktów** i
sklep słusznie nie ma nic do sprzedania. Jeśli po `flutter run` widzisz „nie udało się połączyć ze sklepem”, to jest
właśnie to, a nie błąd — sprawdź z Xcode.

Ponieważ produkt jest teraz niekonsumowalny, symulator pozwoli ci go też kupić **raz** i potem będzie go raportował
jako już posiadany; Debug → StoreKit → Manage Transactions w Xcode to miejsce, gdzie usuwasz transakcję, żeby kupić
go ponownie.

Zakup zrobiony w ten sposób i tak musi dotrzeć do RevenueCat, żeby stać się premium, a RevenueCat potrzebuje
prawdziwego projektu z §9.4. Więc konfiguracja StoreKit dowodzi połowy *sklepowej* na symulatorze; połowy z
nadawaniem dowodzą własne testy serwera i `integration_test/money_tour_test.dart`.

### 9.8 Co sprawdzić na urządzeniu

Użyj kompilacji z **TestFlight** i **sandboxowego** Apple ID (Settings → App Store → Sandbox Account), przeciwko
serwerowi staging z `PURCHASES_SANDBOX=on`. Zakup sandbox przeciwko serwerowi produkcyjnemu jest celowo ignorowany.

- W sklepie jest **jedna** rzecz do kupienia, z ceną w **twojej** walucie, pod panelem „zdobyte dzisiaj”.
- Kupno: pojawia się arkusz, a potem każdy wygląd w sklepie jest twój — również te, których nie kupiłeś za Iskry —
  karta to potwierdzenie bez ceny, a wiersz z reklamą znika.
- Kupno z telefonem w trybie samolotowym po arkuszu: „zapłacone, odblokowanie wkrótce”, a po powrocie jest
  odblokowane — webhook nie potrzebuje działającej aplikacji.
- Anulowanie arkusza nie mówi **zupełnie nic**.
- Przy Screen Time → Content and Privacy → In-app Purchases ustawionym na *Don't Allow* aplikacja mówi, że
  urządzenie nie zezwala na zakupy.
- **Usuń aplikację, zainstaluj ją ponownie, zaloguj się i wciśnij PRZYWRÓĆ ZAKUPY**: wszystko wraca. To
  sprawdzenie liczy się najbardziej i takiego produkt konsumowalny nigdy by nie przeszedł.
- **Ubij aplikację, włącz tryb samolotowy i otwórz ją ponownie**: wszystko jest nadal odblokowane, wyłącznie z
  zapisanego w cache'u snapshotu.
- Potem w sklepie **nie ma żadnej liczby Iskier** — pasek aplikacji mówi *Wszystko odblokowane*, panel „zdobyte dzisiaj”
  zniknął, a skończony przebieg nie pokazuje plakietki z nagrodą. Portfel pod spodem nadal jest zasilany: sprawdź
  `GET /api/shop/inventory` (albo test zwrotu pieniędzy poniżej), żeby zobaczyć, jak rośnie. Jedna zasada, celowo:
  liczba Iskier pojawia się tylko tam, gdzie można z nią coś zrobić.
- Każdy wygląd czyta się jako posiadany również w **Settings → Theme** i na ekranie powitalnym, bez plakietek z
  zamkiem gdziekolwiek.
- Zrób zwrot pieniędzy za zakup sandbox w RevenueCat (Customers → klient → transakcja → Refund) i potwierdź, że
  odblokowanie znika — **i że wygląd, który kupiłeś już wcześniej za Iskry, nadal jest twój**, nadal założony, a
  ten tylko dla premium, który miałeś na sobie, wraca do darmowego domyślnego. Saldo Iskier też wraca, z całością
  tego, co konto zarobiło, gdy było ukryte.
- `SELECT * FROM purchases` na serwerze pokazuje jeden wiersz na płatność, z `source = 'webhook'`. Rejestr, w którym
  wszystko jest `sync`, znaczy, że webhook nie dochodzi, a zepsuty webhook to zwrot pieniędzy, który nie ma gdzie
  wylądować.

### 9.9 Reklamy z nagrodą

Zaimplementowane, i osobny przełącznik: patrz §10. Są oferowane tylko graczom, którzy **nie** kupili odblokowania.

---

## 10. Reklamy z nagrodą, które płacą Iskrami (AdMob) — [money]

Nic z tego nie jest potrzebne do wydania i nic z tego nie jest potrzebne do *grania*. Dopóki nie skończysz tej
sekcji, serwer odpowiada `404 ads_disabled`, aplikacja nigdzie nie pokazuje przycisku reklamy i nie ma nikomu czego wyjaśniać.

Cały sens tego projektu polega na tym, że **telefon nigdy nie mówi, ile zapłaciła reklama**. AdMob mówi to naszemu
serwerowi bezpośrednio, z podpisem, a nasz serwer ustala kwotę z własnej tabeli. Dlatego większość tej sekcji dotyczy
doprowadzenia tego jednego wywołania zwrotnego w odpowiednie miejsce.

**Całą pętlę możesz przejść przed założeniem konta AdMob.** Google publikuje testowe jednostki reklamowe, które
każdemu wyświetlą prawdziwą reklamę z nagrodą, i są już podłączone — patrz §10.1. Zrób to najpierw; po konto wróć,
kiedy zechcesz prawdziwych przychodów.

### 10.1 Testowe reklamy, bez konta AdMob

```bash
flutter run --dart-define=ADMOB_TEST_ADS=on
```

To przełącza aplikację na **opublikowane** testowe jednostki reklamowe Google, które zawsze się wypełniają.
Identyfikatory *aplikacji* AdMob, których potrzebuje SDK, są już w repozytorium — te testowe od Google — w
`ios/Runner/Info.plist` (`GADApplicationIdentifier`) i `android/app/src/main/AndroidManifest.xml`
(`com.google.android.gms.ads.APPLICATION_ID`). Oba podmień na własne w §10.2.

Strona serwerowa i tak musi być włączona, a wywołanie zwrotne i tak musi do niej dotrzeć (§10.4). Testowe reklamy
generują prawdziwe podpisane wywołania zwrotne weryfikacji po stronie serwera, więc to sprawdza całą ścieżkę:
wczytanie, wyświetlenie, wywołanie zwrotne Google, naszą kontrolę podpisu, nasze zaksięgowanie.

`ADMOB_TEST_ADS` jest celowo przełącznikiem **na etapie kompilacji**: kompilacji release nie da się namówić na
testowe reklamy zdezaktualizowanym ustawieniem, a testowy identyfikator nie zostanie wyświetlany w wydanej aplikacji.

### 10.2 Konto i aplikacja w AdMob

1. Załóż konto AdMob na <https://apps.admob.com> i powiąż je z kontem Google, na które mają iść pieniądze.
2. **Apps → Add app**, raz na platformę (iOS i Android). Jeśli aplikacja jest już w sklepie, wybierz ją; w przeciwnym
   razie zaznacz, że nie jest jeszcze opublikowana, i powiąż ją później.
3. Skopiuj każde **App ID** (`ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY`, z **tyldą**) i wklej je w miejsce testowego
   identyfikatora Google:
   - `ios/Runner/Info.plist` → `GADApplicationIdentifier`
   - `android/app/src/main/AndroidManifest.xml` → `com.google.android.gms.ads.APPLICATION_ID`

   SDK czyta je z manifestu platformy, nie z Darta, i **wywali się przy inicjalizacji**, jeśli identyfikatora nie ma
   albo należy on do innego konta. Nie ma dla nich `--dart-define`.
4. W **App settings** każdej aplikacji wypełnij odpowiedzi o prywatność i wykorzystanie danych, o które pyta AdMob.
   Apple też wymaga, żeby odpowiedzi o prywatność w App Store Connect mówiły, że dane są zbierane na potrzeby reklamy
   zewnętrznych podmiotów — reklama z nagrodą zbiera identyfikator reklamowy i jest to informacja do ujawnienia
   niezależnie od tego, czy uważasz to za śledzenie.

### 10.3 Jednostki reklamowe

Jedna jednostka reklamowa typu **rewarded** na platformę. Nic więcej — ta aplikacja nie ma reklamy pełnoekranowej,
banera ani reklamy przy otwarciu, a `test/services/ad_pin_test.dart` wywala kompilację, jeśli któraś kiedyś zostanie
dodana bez świadomej zmiany.

1. **Ad units → Add ad unit → Rewarded**.
2. Nazwij ją tak, żebyś ją rozpoznał (`Arco rewarded — Sparks`).
3. **Reward amount** i **reward item**: wpisz cokolwiek. `10` i `sparks` czytają się najlepiej w panelu, ale serwer
   **nie czyta żadnej z tych wartości** — ile płaci reklama, określa `AdRate.sparksPerAd` w
   `server/lib/src/tokens.dart`. Liczba wpisana w formularz na stronie nie jest źródłem prawdy o ekonomii. Obie
   wartości trafiają do naszego rejestru, więc panel, który rozjechał się z kodem, widać w zapytaniu.
4. Skopiuj każde **Ad unit ID** (`ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ`, z **ukośnikiem**).

### 10.4 Adres URL weryfikacji po stronie serwera — ten ważny

W każdej jednostce reklamowej z nagrodą: **Ad unit → Server-side verification → Edit** i ustaw

```
https://<your-server>/api/ads/callback
```

To **jedyna** rzecz, która księguje Iskrę. Pomyl się i gracze oglądają reklamy za nic; zostaw puste i to samo.

- Musi być **HTTPS** i osiągalny z publicznego internetu. AdMob nie odpyta prywatnego adresu.
- Bez ukośnika na końcu, bez własnego query stringa — chyba że użyjesz opcjonalnego klucza poniżej.
- AdMob dokleja własne parametry (`ad_network`, `ad_unit`, `custom_data`, `reward_amount`, `reward_item`,
  `timestamp`, `transaction_id`, `user_id`, a potem `signature` i `key_id`).
- Ustaw to w jednostkach reklamowych **obu** platform. Pominięcie jednej oznacza, że gracze na Androidzie nie
  zarabiają nic.

Potem włącz funkcję:

```bash
fly secrets set ADS_ENABLED=on
```

To wszystko, czego potrzeba. W przeciwieństwie do zakupów **nie ma tu żadnego sekretu do skonfigurowania**:
wywołanie zwrotne uwierzytelnia własny podpis ECDSA Google nad query stringiem, sprawdzany względem kluczy, które
Google publikuje pod `https://www.gstatic.com/admob/reward/verifier-keys.json`. Twój serwer musi umieć dosięgnąć
tego adresu po HTTPS.

**Opcjonalne utwardzenie.** Jeśli chcesz, żeby adres wywołania zwrotnego dał się unieważnić:

```bash
fly secrets set ADMOB_CALLBACK_KEY=$(openssl rand -hex 24)
```

a potem ustaw URL weryfikacji po stronie serwera na `https://<your-server>/api/ads/callback?arco_key=<ta wartość>`.
Ponieważ AdMob dokleja swoje parametry *po* twoich, klucz trafia do treści, którą Google podpisuje, więc nie da się
go usunąć ani podrobić. To nie on uwierzytelnia — uwierzytelnia podpis — ale dzięki temu wyciekły adres można ubić
zmianą jednej zmiennej. **Ustaw to po obu stronach albo po żadnej:** klucz bez `arco_key` w adresie zamienia każdą
nagrodę w `401 invalid_key`, z wpisem w logu nazywającym zmienną.

`GET /api/health` jest jedynym źródłem prawdy: `"ads": true` oznacza, że wdrożenie księguje reklamy i aplikacja może
je zaproponować; `false` oznacza, że nie będzie i żaden przycisk się nie pojawi.

### 10.5 Wartości ustalane przy kompilacji, które czyta aplikacja

Identyfikatory jednostek reklamowych **nigdy** nie są w źródłach — to identyfikator konta, a prawdziwy w
repozytorium to prawdziwy, do którego forki i kompilacje CI wysyłałyby wyświetlenia.

```bash
flutter build ios --release \
  --dart-define=ADMOB_IOS_REWARDED_UNIT=ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ \
  --dart-define=ADMOB_ANDROID_REWARDED_UNIT=ca-app-pub-XXXXXXXXXXXXXXXX/WWWWWWWWWW
```

| define | wartość | co się dzieje bez niego |
|---|---|---|
| `ADMOB_IOS_REWARDED_UNIT` | identyfikator jednostki z nagrodą dla iOS | brak przycisku reklamy na iOS |
| `ADMOB_ANDROID_REWARDED_UNIT` | identyfikator jednostki z nagrodą dla Androida | brak przycisku reklamy na Androidzie |
| `ADMOB_TEST_ADS` | `on`, żeby zamiast nich użyć jednostek testowych Google | — (i **nadpisuje** dwa powyższe) |

Kompilacja bez żadnej z nich nie pokazuje przycisku reklamy w ogóle — ani wyłączonego, ani błędu. To samo dostaje
kompilacja web i każdy desktop, bo AdMob nie ma tam reklam. Trzymaj je tam, gdzie klucze RevenueCat (§9.5): w
sekrecie CI albo w lokalnym JSON-ie dla `--dart-define-from-file`, którego nie commitujesz.

### 10.6 Zgoda — dokładnie to, co człowiek musi skonfigurować

Reklamy w EOG, Wielkiej Brytanii, Szwajcarii i regulowanych stanach USA wymagają wyboru zgody, zanim można poprosić
o reklamę spersonalizowaną. Aplikacja ma już podłączony SDK **UMP** Google; czego nie zrobi za ciebie, to utworzenie
komunikatu.

1. **AdMob → Privacy & messaging → GDPR.** Utwórz **GDPR message**, wybierz języki, które wydajesz (angielski i
   polski), i wybierz opcje zgody, jakie chcesz zaoferować. Domyślne „Consent or manage options" od Google jest w
   porządku. Opublikuj go przyciskiem **Publish** — nieopublikowany komunikat oznacza, że formularz nigdy się nie
   pojawi, a `canRequestAds()` zostaje na false, więc twoi europejscy gracze po prostu nigdy nie zobaczą przycisku
   reklamy.
2. **Privacy & messaging → US states.** Utwórz i opublikuj też komunikat **US states**, jeśli obsługujesz USA.
3. W komunikacie GDPR wypisz swoich **partnerów reklamowych** (domyślny zestaw Google jest w porządku) i wklej
   **adres URL polityki prywatności**. Bez niego formularz się nie opublikuje, a ten sam adres należy wstawić w
   opisy w sklepach.
4. **IDFA / App Tracking Transparency (iOS).** Jeśli włączysz reklamy spersonalizowane, Apple wymaga monitu ATT.
   UMP Google może go pokazać za ciebie: w ustawieniach komunikatu GDPR włącz **„Also ask for ATT"** (AdMob nazywa to
   *App Tracking Transparency message*). Jeśli to włączysz, musisz też dodać do `ios/Runner/Info.plist` tekst
   `NSUserTrackingUsageDescription` wyjaśniający dlaczego — iOS pokazuje go dosłownie, a aplikacja, która pyta bez
   niego, dostaje odrzucenie. Jeśli wolisz nie pytać wcale, zostaw ATT wyłączone i wyświetlaj reklamy
   niespersonalizowane; aplikacja traktuje to jako całkowicie dobrą reklamę i przycisk działa dokładnie tak samo.
5. **Urządzenia testowe.** Formularz zgody pojawia się tylko tam, gdzie zgoda jest wymagana, więc spoza Europy nigdy
   nie zobaczysz go przypadkiem. Żeby go przetestować: **AdMob → Settings → Test devices**, dodaj swoje urządzenie po
   jego zahaszowanym identyfikatorze (jest wypisywany w logu urządzenia przy pierwszym uruchomieniu SDK), a potem
   skonstruuj `GoogleRewardedAds(debugGeographyEea: true)` w `lib/main.dart` na tę kompilację. Bez urządzenia na
   liście AdMob debugowa geografia nie robi zupełnie nic — dlatego bezpiecznie jest zostawić to w kompilacji debug, a
   nie w release.

**Co aplikacja z tym wszystkim robi, żebyś wiedział, po co to konfigurujesz:** otwarcie sklepu tylko *sprawdza*, czy
formularz jest wymagany — bez UI. Sam formularz pojawia się, kiedy gracz dotknie wiersza z reklamą, czyli w momencie,
w którym poprosił o rzecz, na którą zgoda jest potrzebna. Gracz, który odmówi, dostaje w pełni działającą grę, w
której po prostu nie ma przycisku reklamy — trwale i bez komunikatów — a wiersz mówi o tym przed wyborem. Nakładka
ekranu końca gry nigdy nie pokazuje formularza.

### 10.7 Co sprawdzić na urządzeniu

- Z `--dart-define=ADMOB_TEST_ADS=on` i `ADS_ENABLED=on`: sklep pokazuje wiersz reklamy **pomiędzy** panelem
  „zarobione dziś" a jednorazowym odblokowaniem, a przycisk pojawia się dopiero, gdy reklama się wczyta.
- Obejrzyj jedną. Saldo rośnie o `AdRate.sparksPerAd`, a komunikat podaje nowe saldo.
- `SELECT * FROM ad_rewards` na serwerze pokazuje jeden wiersz, `sparks = 10`, `refused` null i `reward_amount`
  zgodne z tym, co wpisałeś w AdMob — a co serwer zignorował.
- Obejrzyj od razu drugą: **brak przycisku** (pięciominutowy odstęp), a wiersz mówi, kiedy będzie następna.
- Obejrzyj sześć w ciągu dnia: wiersz mówi, że reklamy na dziś się skończyły, a przebieg solo wciąż płaci **pełne**
  Iskry — te dwa limity są rozdzielne.
- Skończ przebieg solo: propozycja reklamy pojawia się pod wynikiem, nad przyciskiem JESZCZE RAZ, i tylko jeśli jakaś była już
  wczytana. Zacznij przebieg: **nic** o reklamach nigdzie.
- Włącz tryb samolotowy zaraz po zamknięciu reklamy: „Iskry są właśnie doliczane", a po powrocie już są — wywołanie
  zwrotne Google nie potrzebuje aplikacji.
- Z `ADS_ENABLED=off`: brak wiersza reklamy, brak przycisku, nic w logach, a `GET /api/ads/offer` odpowiada
  `404 ads_disabled`.
- Ustaw `debugGeographyEea: true` z urządzeniem zarejestrowanym jako urządzenie testowe: formularz zgody pojawia się
  **po dotknięciu**, nie przy starcie. Odmów i sprawdź, czy wiersz reklamy znika, a reszta sklepu — ozdoby, portfel,
  panel zarobków, odblokowanie — działa dokładnie jak wcześniej.

---

## 11. Zanim wypuścisz, sprawdź to sam

- Zagraj duel między dwoma prawdziwymi telefonami na danych mobilnych, nie tylko na własnym Wi-Fi.
- Wyślij wynik z prawdziwego telefonu i potwierdź, że pojawia się na publicznej tablicy wyników.
- Zaloguj się na jednym telefonie, potem zaloguj się na drugim i potwierdź, że twoje wyniki idą za tobą.
- Usuń konto w Ustawieniach i potwierdź, że naprawdę zniknęło.
- Sprawdź grę po polsku i po angielsku, i na najmniejszym telefonie, jaki masz.
- Jeśli włączyłeś zakupy: kup odblokowanie na koncie sandbox, przeinstaluj aplikację i przywróć je, potem zrób
  zwrot pieniędzy i potwierdź, że odblokowanie znika, a ozdoba kupiona za Iskry zostaje twoja — [money].
- Jeśli włączyłeś reklamy: obejrzyj jedną i potwierdź, że saldo się zmienia, obejrzyj od razu drugą i potwierdź, że
  nie ma przycisku, potem odrzuć formularz zgody na urządzeniu testowym i potwierdź, że gra jest nietknięta, a
  przycisk reklamy zniknął — [money].
- Zagraj do końca grę z dwiema piłkami na prawdziwym telefonie. Tempo zostało dostrojone na playteście, nie ze
  wzoru, i nic w pakiecie testów nie powie ci, czy *czuć*, że jest dobre.
- Po każdej zmianie w fizyce wdróż serwer **przed** wgraniem aplikacji i przeczytaj ponownie 12.3a.

### Co App Store Connect już odrzucał

Oba te przypadki wróciły jako mail kilka minut po wgraniu przez Transporter, a nie jako błąd kompilacji, więc warto
sprawdzić je najpierw lokalnie:

- **91169, "invalid bundle"** — framework z warstwą symulatora `IOSSIMULATOR`, co zdarza się, gdy kompilacje
  release i symulatora idą na przemian bez czyszczenia pomiędzy. Rozpakuj `.ipa` i przejedź `vtool -show-build` po
  każdym binarium Mach-O w środku; nic nie może wspominać o symulatorze. Kompilacja 4 padła na
  `objective_c.framework`.
- **90068, docelowa wersja systemu** — każde binarium, pody włącznie, musi być na poziomie docelowej wersji z
  `project.pbxproj` i `ios/Podfile` albo wyżej. `vtool -show-build` wypisuje `minos` każdego z nich.

Jedno i drugie naprawia czysta przebudowa: `flutter clean`, potem usuń `ios/Pods`, `ios/Podfile.lock`,
`ios/.symlinks`, `build/` i foldery Runner w `~/Library/Developer/Xcode/DerivedData`, potem
`flutter pub get`, `pod install`, `flutter build ipa`.

Jedna rzecz, która wygląda na błąd, a nim nie jest: release'owy `.ipa` zawiera `integration_test.framework`
(108 KB). Flutterowy helper podów na iOS instaluje wtyczki z zależności deweloperskich do każdej konfiguracji, więc
to domyślne zachowanie, a nie zła konfiguracja, i Apple nigdy tego nie zakwestionowało. Ręczne ograniczenie tego do
Debug groziłoby siedmiu testom w `integration_test/`, a to gorszy interes za 108 KB.

---

## 12. Utrzymanie, kiedy ludzie już grają — [play]

Nic z tego nie dotyczy tego, żeby jakaś funkcja działała, i właśnie dlatego łatwo to pominąć. Wszystko dotyczy
tego, żeby czegoś później nie stracić.

### 12.1 Rób kopię zapasową bazy

Wolumen serwera trzyma tablicę wyników, portfele, rejestr zakupów i powiązania kont. Jeśli go stracisz, tracisz też
zakupy, za które ludzie zapłacili prawdziwymi pieniędzmi, a to staje się problemem ze zwrotami pieniędzy, a nie awarią.

1. Migawki są **już włączone**: Fly utworzył `arco_data` z zaplanowanymi migawkami i 5-dniową retencją.
   Potwierdź to, zamiast zakładać, i wydłuż retencję, jeśli chcesz więcej zapasu:
   ```bash
   fly volumes list
   fly volumes snapshots list vol_vgnmm193mmqx5nj4
   ```
2. **Odtwórz jedną co najmniej raz, zanim będziesz musiał.** Kopia zapasowa, której nikt nie odtworzył, to zgadywanie.
   ```bash
   fly volumes snapshots create <volume-id>       # take one on demand
   fly volumes create arco_data_restore --snapshot-id <id>
   ```
3. Żeby mieć kopię u siebie, ściągaj plik co jakiś czas:
   ```bash
   fly ssh sftp get /app/data/arco.db ./arco-backup-$(date +%F).db
   ```
   SQLite to jeden plik, więc to jest cała kopia zapasowa. Rób to, kiedy na serwerze jest cicho, albo użyj
   `.backup` przez `sqlite3`, żeby nigdy nie skopiować pliku w trakcie zapisu.

### 12.2 Wiedz, kiedy serwer leży

Jeśli się zatrzyma, duele się zatrzymują, a wyniki po cichu nie zapisują się, i nikt ci o tym nie powie. Skieruj
dowolny darmowy monitor uptime na `https://<your-server>/api/health` co pięć minut i ustaw, żeby pisał ci na
telefon. Endpoint odpowiada `{"ok":true,...}` i nie wymaga uwierzytelnienia, więc bezpiecznie go pytać.

### 12.3 Wdrożenia przerywają trwające duele

Każde `fly deploy` restartuje proces, a pokój żyje w pamięci, więc każdy trwający duel się kończy. Gier solo to nie
dotyczy, a oczekujące wyniki same się ponawiają. Wdrażaj, kiedy nikt nie gra.

### 12.3a Zmiana symulacji to zmiana protokołu: zawsze najpierw serwer

Aplikacja i serwer uruchamiają *tę samą* symulację, dosłownie, i to właśnie sprawia, że wynik da się sprawdzić.
Więc każda zmiana w fizyce jest też zmianą formatu transmisji, a `protocolVersion` i `Replay.version` podnosi się
razem. Kompilacja na starej fizyce dostaje wtedy komunikat, żeby **zaktualizować aplikację**, zamiast odmowy dla
uczciwego wyniku — ale dostaje go tylko od serwera, który już został wdrożony.

Kolejność jest więc ustalona i nie jest tą wygodną:

1. `fly deploy` serwera.
2. Potem zbuduj i wgraj aplikację.

Pomiędzy jednym a drugim nic nie jest zepsute. Wdrożenie najpierw oznacza, że przestaje działać *stara* aplikacja:
już zainstalowane kompilacje (w tym cokolwiek w TestFlight) dostają `unsupported_version` na wyniku i
`bad_version` na duelu, dopóki ich tester nie zaktualizuje. Zbudowanie najpierw oznaczałoby, że *nowa* aplikacja
wcale nie dogada się z żywym serwerem, co jest gorsze, i wypuściłoby wersję, której nie dałoby się przetestować
przeciw produkcji.

Więc kiedy wydanie zawiera zmianę fizyki, licz się z okresem, w którym stara kompilacja z TestFlight jest martwa, i
powiedz testerom, żeby wzięli aktualizację. `curl https://arco.fly.dev/api/scores` z `"v": <old>` w ciele to szybki
sposób, żeby potwierdzić, na której wersji jest żywy serwer:

```bash
curl -s -X POST https://arco.fly.dev/api/scores -H 'content-type: application/json' \
  -d '{"name":"VerCheck","replay":{"v":2,"cfg":{"m":0,"s":1,"n":1},"in":[[[0,33]]],"ft":100,"sc":5}}'
# {"ok":false,"error":"unsupported_version","detail":"replay version 2, server supports 3"}
```

To wywołanie nic nie zapisuje, więc można je bezpiecznie odpalić przeciw produkcji.

### 12.4 Kontakt wsparcia i regulamin

Oba sklepy wymagają w opisie adresu wsparcia albo maila i żaden nie przyjmie pustego. Jeśli cokolwiek sprzedajesz,
dodaj też krótką stronę z regulaminem, osobną od polityki prywatności. Zwykła strona na dowolnej domenie, którą
kontrolujesz, wystarczy do obu.

### 12.5 Klasyfikacja wiekowa a reklamy — zdecyduj, zanim wypełnisz ankietę

Ta rzecz ma konsekwencje, których nie cofniesz łatwo. Jeśli zadeklarujesz aplikację jako skierowaną do dzieci, obie
platformy mocno ograniczają reklamy i identyfikatory reklamowe, a Kids Category u Apple zakazuje reklam
zewnętrznych całkowicie. Arco wygląda przyjaźnie dla dzieci, więc ankieta będzie cię pchać w tę stronę.

Wybierz jedno, świadomie:

- **Nie skierowana do dzieci.** Reklamy i identyfikator reklamowy są dozwolone, z przepływem zgody z §10.6.
- **Skierowana do dzieci.** Wyłącz reklamy całkowicie przez `ADS_ENABLED=off` i wypuść bez nich. Wszystko inne w
  grze działa dalej, a sklep po prostu nie pokazuje wiersza z reklamą.

Odpowiedź „skierowana do dzieci” przy jednoczesnym serwowaniu reklam to ten wariant, po którym aplikacja leci ze sklepu.

### 12.6 Trzymaj kod gdzieś poza laptopem — ZROBIONE

Repozytorium jest wypchnięte na **github.com/tymonq19/ARCO**. Pushuj dalej po każdej zmianie; chodzi o to, żeby
martwy laptop kosztował cię dzień, a nie projekt.

Została jedna decyzja: to repozytorium jest **publiczne**. Nie ma w nim żadnych sekretów, a odporność tablicy
wyników na oszustwa nie zależy od tego, czy kod jest prywatny, ale każdy może zbudować i opublikować własną kopię
gry, którą zamierzasz sprzedawać. Przełączenie na prywatne to jedno kliknięcie w ustawieniach repozytorium, w
Danger Zone.
