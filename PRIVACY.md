# Polityka prywatności gry Arco

*Ostatnia aktualizacja: 1 października 2026 r.* · [English version below](#privacy-policy-for-arco)

Ta polityka wyjaśnia, jakie dane przetwarza gra **Arco** (aplikacja na iOS i Androida oraz jej serwer), po co,
jak długo i jakie masz prawa. Piszemy ją prosto, bo zbieramy mało: tyle, ile potrzeba, żeby działała tablica
wyników, konto, zakupy i reklamy.

## 1. Kto jest administratorem danych

**JTA DEVS sp. z o.o.**, Dąbrowa Górnicza, Polska.
Kontakt we wszystkich sprawach dotyczących prywatności: **jta.devs@gmail.com**.

## 2. Czego nie zbieramy

Nie prosimy o imię i nazwisko, numer telefonu, lokalizację GPS, kontakty, zdjęcia ani dostęp do mikrofonu.
Nie używamy narzędzi analitycznych, nie śledzimy Cię w innych aplikacjach i nie sprzedajemy niczyich danych.
Czujnik ruchu (żyroskop) służy wyłącznie do sterowania w grze i jego odczyty nie opuszczają telefonu.

## 3. Jakie dane przetwarzamy i po co

### 3.1 Na Twoim telefonie
Ustawienia, nick, rekordy i stan sklepu są zapisane lokalnie na urządzeniu. Losowy identyfikator gracza i jego
hasło (sekret) są przechowywane w bezpiecznym magazynie systemu (pęk kluczy / Keystore). Znikają po usunięciu
aplikacji (na iOS sekret może pozostać w pęku kluczy, dopóki nie usuniesz konta w grze).

### 3.2 Identyfikator gracza
Przy pierwszym wysłaniu wyniku lub otwarciu sklepu serwer nadaje losowy identyfikator gracza. Nie jest on
powiązany z Twoją tożsamością. Serwer przechowuje identyfikator, skrót (hash) sekretu, nick, którym grasz,
datę utworzenia i ostatniej aktywności.

### 3.3 Światowa tablica wyników
Gdy wysyłasz wynik, serwer zapisuje: nick, wynik, czas gry, datę, zapis przebiegu rozgrywki (ruchy, potrzebne
do sprawdzenia, że wynik jest prawdziwy), kraj odczytany z ustawień regionu telefonu (nie z lokalizacji) oraz
skrót SHA-256 adresu IP (do ochrony przed nadużyciami). **Publicznie widoczne** są: nick, wynik, czas, data i
kraj.

### 3.4 Pojedynki online
Podczas pojedynku serwer przekazuje między graczami nick i ruchy. Pokój istnieje tylko w pamięci serwera i
znika po zakończeniu meczu; nic z niego nie jest zapisywane.

### 3.5 Konto (opcjonalne)
Konto możesz założyć przez **Apple**, **Google** albo **adres e-mail i hasło**. Logowanie obsługuje **Firebase
Authentication** (Google). Firebase przetwarza: przy e-mailu — adres e-mail i hasło (przechowywane w postaci
zabezpieczonej), przy Apple/Google — identyfikator konta u tego dostawcy, a także adres e-mail, jeśli dostawca
go przekaże. **Nasz serwer nie zapisuje adresu e-mail ani imienia** — przechowuje wyłącznie identyfikator
użytkownika Firebase i datę powiązania konta, żeby Twoje wyniki i zakupy były dostępne na innym urządzeniu.

### 3.6 Iskry i ozdoby
Serwer przechowuje saldo Iskier, kupione i wybrane ozdoby oraz historię przyznanych nagród (za gry i obejrzane
reklamy), żeby saldo było poprawne i nie dało się go oszukać.

### 3.7 Zakupy
Płatności obsługuje **Apple App Store** lub **Google Play** — nie widzimy danych Twojej karty ani konta
płatniczego. Weryfikację zakupów prowadzi **RevenueCat** (RevenueCat, Inc., USA), który otrzymuje potwierdzenie
transakcji ze sklepu i nasz identyfikator gracza. Nasz serwer zapisuje identyfikator transakcji, produkt, datę i
ewentualny zwrot — po to, żeby przyznać odblokowanie, umożliwić jego przywrócenie i cofnąć je po zwrocie
pieniędzy.

### 3.8 Reklamy
Gra jest darmowa i wyświetla reklamy **Google AdMob** (Google Ireland Ltd.): reklamy z nagrodą, które włączasz
sam, żeby dostać Iskry, oraz reklamę między grami (najwyżej po co trzeciej grze). AdMob może przetwarzać
identyfikatory urządzenia (np. identyfikator reklamowy na Androidzie), adres IP, informacje o urządzeniu i
interakcjach z reklamami — m.in. do wyświetlania reklam, ograniczania ich częstotliwości, pomiaru i
zapobiegania oszustwom.

- W Europejskim Obszarze Gospodarczym, Wielkiej Brytanii i Szwajcarii przed pierwszą reklamą zobaczysz formularz
  zgody Google. **Reklamy spersonalizowane wyświetlamy tylko za Twoją zgodą**; bez niej reklamy są
  niespersonalizowane. Zgodę możesz w każdej chwili zmienić w grze: *Ustawienia → Ustawienia prywatności reklam*.
- Na iOS gra nie prosi o zgodę na śledzenie (App Tracking Transparency), więc nie ma dostępu do identyfikatora
  reklamowego IDFA.
- Po obejrzeniu reklamy z nagrodą Google wysyła naszemu serwerowi podpisane potwierdzenie z identyfikatorem
  gracza i transakcji; zapisujemy je, żeby przyznać Iskry.
- Gracz, który kupił pełną wersję, nie widzi żadnych reklam.

Więcej: [jak Google wykorzystuje dane](https://policies.google.com/technologies/partner-sites).

### 3.9 Serwer i dzienniki
Serwer gry działa w usłudze **Fly.io** (Fly.io, Inc., USA) w centrum danych we Frankfurcie (UE). Do ochrony przed
nadużyciami serwer liczy zapytania z danego adresu IP wyłącznie w pamięci, przez kilka minut. Dzienniki
techniczne (błędy i zdarzenia) przechowujemy krótko i nie zawierają one adresów e-mail.

## 4. Podstawy prawne (RODO)

- **wykonanie umowy** (art. 6 ust. 1 lit. b) — gra, tablica wyników, pojedynki, konto, Iskry, zakupy;
- **prawnie uzasadniony interes** (art. 6 ust. 1 lit. f) — ochrona przed oszustwami i nadużyciami, bezpieczeństwo,
  finansowanie darmowej gry reklamami niespersonalizowanymi;
- **zgoda** (art. 6 ust. 1 lit. a) — reklamy spersonalizowane; możesz ją wycofać w każdej chwili;
- **obowiązek prawny** (art. 6 ust. 1 lit. c) — gdy przepisy wymagają przechowywania danych o transakcjach.

## 5. Jak długo przechowujemy dane

Dane gracza przechowujemy, dopóki nie usuniesz konta. **Usunięcie konta** (*Ustawienia → USUŃ MOJE KONTO*)
kasuje na naszym serwerze gracza, jego wyniki z tablicy, saldo Iskier, ozdoby, historię zakupów i nagród za
reklamy oraz usuwa użytkownika w Firebase. Kopie zapasowe bazy danych są nadpisywane w ciągu 5 dni, więc po tym
czasie dane znikają także z nich. Zakup pozostaje zapisany u Apple lub Google i w RevenueCat zgodnie z ich
zasadami — dzięki temu możesz go przywrócić na nowym koncie przyciskiem „Przywróć zakupy”.

## 6. Komu przekazujemy dane

Wyłącznie podmiotom, które pomagają nam prowadzić grę: Google (Firebase Authentication, AdMob), RevenueCat,
Apple i Google jako sklepy oraz Fly.io (hosting). Część z nich ma siedzibę w USA; przekazanie odbywa się na
podstawie decyzji Komisji Europejskiej (EU-US Data Privacy Framework) lub standardowych klauzul umownych.

## 7. Twoje prawa

Masz prawo dostępu do danych, ich sprostowania, usunięcia, ograniczenia przetwarzania, przenoszenia oraz
sprzeciwu, a także prawo wycofania zgody w dowolnym momencie (bez wpływu na wcześniejsze przetwarzanie).
Najszybciej usuniesz dane sam, w grze. W innych sprawach napisz na **jta.devs@gmail.com** — odpowiemy w ciągu
30 dni. Przysługuje Ci też skarga do Prezesa Urzędu Ochrony Danych Osobowych (ul. Stawki 2, 00-193 Warszawa,
[uodo.gov.pl](https://uodo.gov.pl)).

## 8. Dzieci

Gra nie jest skierowana do dzieci poniżej 13 lat i świadomie nie zbieramy ich danych. Jeśli uważasz, że dziecko
przekazało nam dane, napisz do nas — usuniemy je.

## 9. Zmiany

O istotnych zmianach tej polityki poinformujemy w grze lub na tej stronie. Data ostatniej aktualizacji jest na
górze.

---

# Privacy Policy for Arco

*Last updated: 1 October 2026*

This policy explains what data **Arco** (the iOS and Android game and its server) processes, why, for how long,
and what your rights are. We keep it short because we collect little: what the leaderboard, accounts, purchases
and ads need to work.

## 1. Controller

**JTA DEVS sp. z o.o.**, Dąbrowa Górnicza, Poland.
Contact for anything privacy-related: **jta.devs@gmail.com**.

## 2. What we do not collect

We do not ask for your name, phone number, GPS location, contacts, photos or microphone. We use no analytics
tools, do not track you across other apps and do not sell anyone's data. The motion sensor (gyroscope) is used
only to steer in the game and its readings never leave the phone.

## 3. What we process and why

### 3.1 On your phone
Settings, nickname, records and the shop state are stored on the device. A random player id and its secret are
kept in the system's secure storage (Keychain / Keystore). They go when you delete the app (on iOS the secret may
stay in the Keychain until you delete your account in the game).

### 3.2 Player id
The first time you submit a score or open the shop, the server issues a random player id. It is not linked to
your identity. The server stores the id, a hash of its secret, the nickname you play under, and when it was
created and last active.

### 3.3 World leaderboard
When you submit a score, the server stores: nickname, score, play time, date, a recording of the run (the
moves, needed to verify the score is genuine), the country taken from your phone's region setting (not from
location) and a SHA-256 hash of your IP address (to fight abuse). **Publicly visible**: nickname, score, play
time, date and country.

### 3.4 Online duels
During a duel the server relays nicknames and moves between the players. The room exists only in the server's
memory and disappears when the match ends; nothing from it is stored.

### 3.5 Account (optional)
You can create an account with **Apple**, **Google** or an **e-mail address and password**. Sign-in is handled by
**Firebase Authentication** (Google). Firebase processes: for e-mail, the address and the password (stored in a
protected form); for Apple/Google, the account identifier at that provider and the e-mail address if the
provider shares it. **Our server stores no e-mail address and no name** — only the Firebase user id and the date
the account was linked, so your scores and purchases follow you to another device.

### 3.6 Sparks and cosmetics
The server stores your Sparks balance, the cosmetics you own and wear, and a history of rewards (for games and
watched ads), so the balance is right and cannot be faked.

### 3.7 Purchases
Payments are handled by the **Apple App Store** or **Google Play** — we never see your card or payment account.
Purchases are verified by **RevenueCat** (RevenueCat, Inc., USA), which receives the store's transaction
confirmation and our player id. Our server stores the transaction id, product, date and any refund, to grant the
unlock, let you restore it and take it back after a refund.

### 3.8 Ads
The game is free and shows **Google AdMob** ads (Google Ireland Ltd.): rewarded ads you choose to watch for
Sparks, and an ad between games (at most after every third game). AdMob may process device identifiers (such as
the advertising ID on Android), IP address, device information and ad interactions — to serve ads, limit how
often they appear, measure them and prevent fraud.

- In the EEA, the UK and Switzerland you will see Google's consent form before the first ad. **Personalised ads
  are shown only with your consent**; without it ads are non-personalised. You can change your choice at any time
  in the game: *Settings → Ad privacy settings*.
- On iOS the game does not ask for tracking permission (App Tracking Transparency), so it has no access to the
  IDFA advertising identifier.
- After a rewarded ad, Google sends our server a signed confirmation with the player and transaction ids; we store
  it to credit the Sparks.
- A player who bought the full unlock sees no ads at all.

More: [how Google uses data](https://policies.google.com/technologies/partner-sites).

### 3.9 Server and logs
The game server runs on **Fly.io** (Fly.io, Inc., USA) in a data centre in Frankfurt (EU). To fight abuse the
server counts requests per IP address in memory only, for a few minutes. Technical logs (errors and events) are
kept briefly and contain no e-mail addresses.

## 4. Legal bases (GDPR)

- **performance of a contract** (Art. 6(1)(b)) — the game, leaderboard, duels, account, Sparks, purchases;
- **legitimate interests** (Art. 6(1)(f)) — preventing cheating and abuse, security, funding a free game with
  non-personalised ads;
- **consent** (Art. 6(1)(a)) — personalised ads; you can withdraw it at any time;
- **legal obligation** (Art. 6(1)(c)) — where the law requires transaction records to be kept.

## 5. How long we keep data

We keep player data until you delete your account. **Deleting your account** (*Settings → DELETE MY ACCOUNT*)
erases from our server the player, its scores on the leaderboard, Sparks, cosmetics, purchase and ad-reward
history, and deletes the Firebase user. Database backups are overwritten within 5 days, after which the data is
gone from them too. The purchase itself stays on record with Apple or Google and in RevenueCat under their terms
— which is what lets you restore it on a new account with "Restore purchases".

## 6. Who we share data with

Only providers that help us run the game: Google (Firebase Authentication, AdMob), RevenueCat, Apple and Google
as app stores, and Fly.io (hosting). Some are based in the USA; transfers rely on the European Commission's
adequacy decision (EU-US Data Privacy Framework) or standard contractual clauses.

## 7. Your rights

You have the right to access, rectify and erase your data, to restrict or object to its processing, to data
portability, and to withdraw consent at any time (without affecting earlier processing). The quickest way to
erase your data is in the game. For anything else, write to **jta.devs@gmail.com** — we reply within 30 days.
You may also complain to a data protection authority; in Poland that is the President of the Personal Data
Protection Office (UODO, ul. Stawki 2, 00-193 Warsaw, [uodo.gov.pl](https://uodo.gov.pl)).

## 8. Children

The game is not directed at children under 13 and we do not knowingly collect their data. If you believe a child
has given us data, write to us and we will delete it.

## 9. Changes

We will announce material changes to this policy in the game or on this page. The date of the last update is at
the top.
