# Arco — manual setup checklist

Everything in this file is work a human has to do outside the repository: accounts to open, identifiers to
register, secrets to paste. Each item says **when you need it**, so you can play with friends long before you
touch an app store.

Legend: **[play]** needed to play with other people over the internet · **[store]** needed to publish ·
**[money]** needed only once you sell something.

## Where this stands

| section | state |
|---|---|
| 1. Server online | **done** — https://arco.fly.dev, Frankfurt, volume-backed, snapshots on |
| 2-5, 8. Developer accounts and sign-in | not started; the app works without them |
| 6, 7. Store listing, icon | not started |
| 9, 10. Unlock and ads | not started; both features are built and switched off |
| 12.1 Backups | **partly done** — Fly made the volume with scheduled snapshots; a restore has never been rehearsed |
| 12.2 Monitoring, 12.4 Support page, 12.5 Age rating | not started |
| 12.6 Code off the laptop | **done** — github.com/tymonq19/ARCO |

**Nothing below blocks playing.** The server is live, so a duel between two phones works today. Everything
that remains is about publishing, selling, or not losing things later.

---

## 1. Put the server online — [play] — DONE

Duels and the global leaderboard both talk to your own server. Until it is reachable from the internet, the
game works only on your own machine.

**This is already done.** What exists now:

| | |
|---|---|
| address | `https://arco.fly.dev` |
| region | `fra` (Frankfurt) — Fly has no Warsaw region; this is the closest, about 20 ms from Warsaw |
| machine | one, `auto_stop_machines = "off"` so duel rooms in memory are never dropped |
| volume | `arco_data`, 1 GB, encrypted, mounted at `/app/data`, scheduled snapshots with 5-day retention |
| verified | `/api/health` answers, a recorded solo replay was accepted and listed, a tampered score was refused, and a duel ran over two WebSockets |

The configuration lives in `fly.toml` and is committed. Redeploy after a code change with `fly deploy` from
the repository root. The steps below are kept as the record of how it was done and what to repeat if you ever
move hosts.

1. Install the Fly.io command line tool and sign in. A card is required even on the free-scale plan.
2. From the repository root, create the app. The Dockerfile is already correct, so accept it when asked.
   ```bash
   fly launch --name arco --no-deploy
   ```
   If the name is taken, pick another and remember it; it becomes `https://<name>.fly.dev`.
3. Create a volume for the database, in the same region as the app:
   ```bash
   fly volumes create arco_data --size 1
   ```
   Confirm `fly.toml` mounts that volume at `/app/data`, and that `DB_PATH` points inside it.
4. Deploy and check it:
   ```bash
   fly deploy
   curl https://<your-app>.fly.dev/api/health
   ```
   You want `{"ok":true,...}`. The path is `/api/health`, not `/health`.
5. Build the app against it:
   ```bash
   flutter run --dart-define=SERVER_URL=https://<your-app>.fly.dev
   ```
   The address can also be changed at runtime in Settings under Advanced, which is handy for testing.

Cost at this scale is a few dollars a month. Any host that runs a container works; Railway and Render need the
same two things, an always-on instance and a persistent volume.

### Environment variables the server reads

| variable | default | meaning |
|---|---|---|
| `PORT` | 8080 | listening port |
| `DB_PATH` | `data/arco.db` | SQLite file, must be on the mounted volume |
| `VERIFY_REPLAYS` | `strict` | leave it strict; `off` disables leaderboard verification |
| `LOG_LEVEL` | `info` | `debug` while you are setting things up |
| `ACCOUNTS_ENABLED` | `off` | `on` turns on Apple and Google sign-in |
| `APPLE_CLIENT_IDS` | unset | comma separated, see section 3 |
| `GOOGLE_CLIENT_IDS` | unset | comma separated, see section 4 |
| `PURCHASES_ENABLED` | `off` | `on` turns on the one-time unlock, see section 9 — [money] |
| `REVENUECAT_WEBHOOK_SECRET` | unset | **secret**, see section 9 — [money] |
| `REVENUECAT_API_KEY` | unset | **secret**, see section 9 — [money] |
| `PURCHASES_SANDBOX` | `off` | `on` grants premium from sandbox purchases; staging only — [money] |

Set them with `fly secrets set NAME=value`. With `ACCOUNTS_ENABLED=on` and no client ids the server refuses to
start, on purpose: without an id to check tokens against, a token minted for any other app would be accepted.
The same applies to `PURCHASES_ENABLED=on` without both RevenueCat secrets: without the webhook secret anybody
could claim a purchase, and without the API key the server cannot re-verify one for itself.

---

## 2. Apple Developer account — [store], and [play] on a real iPhone

Membership costs 99 USD a year and identity verification can take a few days, so start early.

1. Enrol at developer.apple.com.
2. In Certificates, Identifiers and Profiles, register an App ID with the bundle identifier
   **`com.jtadevs.arco`**. It must match the project exactly.
3. Enable the **Sign in with Apple** capability on that App ID.
4. In Xcode, open `ios/Runner.xcworkspace`, select the Runner target, Signing and Capabilities, choose your
   team, and add the **Sign in with Apple** capability there too so the entitlement lands in the build.
5. To test on your own iPhone you only need the free personal team; the paid membership is for distribution.

---

## 3. Sign in with Apple — [store]

1. The App ID from section 2 with the capability enabled is the main client id. It is your bundle identifier,
   `com.jtadevs.arco`.
2. Only if you also run the web build: create a **Services ID**, enable Sign in with Apple on it, and add your
   web domain and return URL. Its identifier is a second client id.
3. Put every id you use into the server:
   ```bash
   fly secrets set APPLE_CLIENT_IDS=com.jtadevs.arco
   fly secrets set ACCOUNTS_ENABLED=on
   ```
4. Check `GET /api/health` afterwards. Its `accounts` field must list `apple`. The app only shows buttons that
   this field advertises, so an empty list means the app will show none.

---

## 4. Google Sign-In — [store]

1. Create a project in the Google Cloud console and configure the OAuth consent screen. An app used by anyone
   outside your own account needs it published, and that review takes time.
2. Create OAuth client ids:
   - **iOS**, with bundle id `com.jtadevs.arco`,
   - **Android**, with package `com.jtadevs.arco` plus the SHA-1 fingerprint of your signing key,
   - **Web**, only if you ship the web build.
3. Give the server every id that may appear in a token:
   ```bash
   fly secrets set GOOGLE_CLIENT_IDS=<ios id>,<android id>
   ```
4. The client side also needs configuration files and a URL scheme; the exact keys are listed in section 8,
   which is filled in from the implementation.

Remember Apple's rule: an iOS app that offers Google sign-in must also offer Sign in with Apple. Both are built,
so just do not enable only Google.

---

## 5. Android signing — [store]

1. Create an upload keystore and keep it somewhere you will not lose it. Losing it means you cannot update your
   own app.
2. Reference it from `android/key.properties` and make sure that file is not committed.
3. Take the SHA-1 of the upload key and of Google Play's app signing key, and put both into the Android OAuth
   client from section 4. Forgetting the second one is the usual reason sign-in works in testing and fails in
   production.

---

## 6. Store listings — [store]

Both stores need the same raw material, so prepare it once:

- The name **Arco**, a short subtitle, and a description in English first, then Polish.
- An icon at 1024 by 1024 with no transparency and no rounded corners.
- Screenshots from the required device sizes. The four themes give you visually distinct shots for free.
- A privacy policy at a public URL. Keep it honest and short: the game stores a nickname, scores, an
  approximate country from the device locale, and, only if the player signs in, an opaque identifier from
  Apple or Google. No email address and no real name are stored.
- An age rating questionnaire. There is no objectionable content, but an online leaderboard with
  player-chosen nicknames is worth declaring, and the nickname filter is your answer to the follow-up.
- Export compliance: the app uses only standard HTTPS, which is the ordinary exemption.

---

## 7. Icon and launch screen — [store]

The project still ships Flutter's placeholder icon. Replace the icon sets under `ios/Runner/Assets.xcassets`
and `android/app/src/main/res`, and the launch screen under `ios/Runner/Base.lproj`. A first cold launch shows
the launch screen, so a plain dark background with the wordmark reads better than a white flash.

---

## 8. Sign-in platform configuration — [store]

Everything below is platform work that no Dart code can do for you. Until it is done, the sign-in buttons
either do not appear (because `GET /api/health` advertises nothing) or fail on the tap. The app degrades
quietly in both cases and stays fully playable, so none of this blocks shipping a build without accounts.

The packages are already in `pubspec.yaml`: `sign_in_with_apple: ^8.1.0` and `google_sign_in: ^7.2.0`.

### 8.1 Compile-time values the app reads

They are public identifiers, not secrets, and the server never trusts them — it checks the token's `aud`
against its own `APPLE_CLIENT_IDS` / `GOOGLE_CLIENT_IDS`. See `lib/app/account_config.dart`.

| `--dart-define` | needed for | value |
|---|---|---|
| `GOOGLE_CLIENT_ID` | iOS / macOS | the **iOS** OAuth client id, `…apps.googleusercontent.com`. Optional if you put `GIDClientID` in `Info.plist` instead (8.3). |
| `GOOGLE_SERVER_CLIENT_ID` | **Android** | the **Web** OAuth client id of the same project. Without it Android returns no `idToken` at all and the app reports "that sign-in returned nothing to verify". This id is the `aud` the token carries, so it is what `GOOGLE_CLIENT_IDS` must list for Android. |
| `APPLE_SERVICE_ID` | Android only | the Apple **Services ID** for the web flow. Without it (and the next one) the Apple button is not offered on Android. |
| `APPLE_REDIRECT_URI` | Android only | the Return URL registered on that Services ID, e.g. `https://arco.example.com/callbacks/sign_in_with_apple`. |

Example release build:

```bash
flutter build ipa --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=GOOGLE_CLIENT_ID=123-ios.apps.googleusercontent.com
flutter build appbundle --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=123-web.apps.googleusercontent.com
```

### 8.2 iOS — Sign in with Apple

1. The App ID `com.jtadevs.arco` needs the **Sign in with Apple** capability (section 2).
2. In Xcode, Runner target → Signing and Capabilities → **+ Capability** → Sign in with Apple. This writes
   `com.apple.developer.applesignin = ["Default"]` into `ios/Runner/Runner.entitlements` and links the
   entitlement to your provisioning profile. The repository deliberately does not ship this entitlement: a
   build signed against an App ID that lacks the capability fails to install.
3. Nothing else. No `Info.plist` key, no URL scheme, and the token's `aud` is the bundle id — so
   `APPLE_CLIENT_IDS=com.jtadevs.arco` on the server.
4. It needs iOS 13 or newer. The project already targets 13.0, and the app hides the button below that.

### 8.3 iOS — Google Sign-In

1. Create the **iOS** OAuth client (section 4) and download its `GoogleService-Info.plist` — or just copy the
   two values out of it.
2. Add to `ios/Runner/Info.plist`:
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
   The URL scheme is the client id's **reversed** form, exactly as the console shows it. Without it the
   Google sheet opens and never comes back.
3. `GIDClientID` and `--dart-define=GOOGLE_CLIENT_ID` do the same job; passing the define wins. Use one.
4. No entitlement and no keychain sharing group is needed.

### 8.4 Android — Google Sign-In

1. Create the **Android** OAuth client with package `com.jtadevs.arco` and the SHA-1 of *both* your upload key
   and Play's app signing key (section 5).
2. Also create a **Web** OAuth client and pass it as `--dart-define=GOOGLE_SERVER_CLIENT_ID`. Android gets its
   `idToken` from that id.
3. `google_sign_in` 7.x uses Credential Manager, so there is **no** `google-services.json` and no
   `com.google.gms.google-services` Gradle plugin to add. `android/app/build.gradle.kts` needs no new entry;
   the plugin's own manifest and dependencies are merged in by Flutter.
4. `minSdk` must be 21 or higher, which `flutter.minSdkVersion` already satisfies.

### 8.5 Android — Sign in with Apple (optional)

There is no native Apple sign-in on Android; the package opens Apple's web flow in a Chrome Custom Tab.

1. Create an Apple **Services ID**, enable Sign in with Apple on it, and register a Return URL you control.
2. That URL must be a real endpoint: it receives Apple's `POST` and has to redirect back into the app with
   `intent://callback?...#Intent;package=com.jtadevs.arco;scheme=signinwithapple;end`. The package's README has
   the two-line handler.
3. Add the intent filter the package documents to `android/app/src/main/AndroidManifest.xml` (scheme
   `signinwithapple`, host `callback`).
4. Pass `APPLE_SERVICE_ID` and `APPLE_REDIRECT_URI`, and add the Services ID to `APPLE_CLIENT_IDS` on the
   server — the web flow's `aud` is the Services ID, not the bundle id.
5. Skipping all of this is fine: the app then offers only Google on Android, which Apple's rule permits
   because it only governs what iOS offers.

### 8.6 Server side

```bash
fly secrets set ACCOUNTS_ENABLED=on
fly secrets set APPLE_CLIENT_IDS=com.jtadevs.arco
fly secrets set GOOGLE_CLIENT_IDS=123-ios.apps.googleusercontent.com,123-web.apps.googleusercontent.com
```

A provider with no client id is not advertised, so an Apple-only launch simply leaves `GOOGLE_CLIENT_IDS`
unset. `GET /api/health` is the single source of truth for which buttons the app shows: if `accounts` is `[]`,
no sign-in appears anywhere in the app, and there are no dead buttons to explain.

### 8.7 What to check on a device

- `GET /api/health` lists the providers you configured.
- On iOS, both buttons appear on the game-over card after a personal best, Apple first.
- Cancelling the sheet does nothing at all — no error, no message.
- Signing in on a second device says "Welcome back" and the leaderboard highlights the same runs.
- Settings → Account shows the provider and the date, and **Delete my account** takes two taps through two
  different dialogs.
- Web: nothing about sign-in is shown, on purpose — the browser build has no keychain to keep a credential in.

---

## 9. The one-time unlock (RevenueCat) — [money]

Nothing here is needed to ship. The game is complete without it: every cosmetic is earnable with Sparks by playing,
200 a day, every day, and nothing in the game is behind a payment. Until you finish this section the server answers
`404 purchases_disabled`, the shop offers nothing to buy, and there is no dead button to explain.

What is sold is **one product, bought once**: a non-consumable that unlocks every cosmetic that exists and every one
added later, and turns ads off, forever. There is no second tier and no Spark pack.

Two halves have to agree: **the stores** decide what it costs, and **our server** decides what it grants. The price
never appears in our code or in the app — the app prints whatever StoreKit or Google Play hands it, in the player's
own currency, with their market's tax. Changing the price is a change in App Store Connect or the Play Console and
nothing else. Aim for the low-mid teens in PLN; pick the tier in the store, not here.

### 9.1 The product identifier

Create **the same identifier** in both stores. It is already in `server/lib/src/catalogue.dart`; if you change it
there, change it in both stores and in RevenueCat too, or the webhook will be refused as `unknown_product`.

| product id | type | what the server grants |
|---|---|---|
| `arco.unlock.full` | non-consumable | every cosmetic, present and future; no ads |

**Non-consumable**, in both stores — App Store Connect calls it *Non-Consumable*, the Play Console *one-time
product*. It is bought once and the stores remember it forever, which is what makes **Restore purchases** a real
feature rather than an explanation. A consumable would be wrong here in both directions: it could be bought again,
and it could not be restored.

If you had created the old `arco.sparks.small|medium|large` consumables in either store, leave them alone or mark
them unavailable — nothing has shipped, nobody holds one, and the server refuses a webhook naming one rather than
granting anything for it.

### 9.2 App Store Connect

1. My Apps → Arco → **In-App Purchases** → create one **Non-Consumable** product with the identifier above.
2. Give it a reference name, a display name and a description in every language you ship (English and Polish), and
   pick a price tier. Apple fills in every market from the tier; do not try to match it in code.
3. Upload a screenshot of the purchase in the app and a review note. The product is reviewed **separately from the
   build** and cannot be bought until approved.
4. Agreements, Tax, and Banking → complete the **Paid Applications** agreement, tax forms and bank details.
   Nothing can be sold until this is done, and it takes longer than the code does.
5. Users and Access → **Integrations** → App Store Server Notifications / In-App Purchase keys: create an
   **In-App Purchase key** and download the `.p8`. RevenueCat needs it (9.4).

### 9.3 Google Play Console

1. Monetise → Products → **In-app products** → create one product with the same identifier, with a price and a
   name and description per language, and **activate** it.
2. Monetise with Play → **Payments profile**: complete the merchant account, tax and bank details.
3. Setup → API access: link a Google Cloud project, create a **service account** with the *Financial data* and
   *Manage orders* permissions, grant it access in Play Console, and download its **JSON key**. RevenueCat needs it
   (9.4).
4. The app must have been uploaded to a track at least once before in-app products can be created.

### 9.4 RevenueCat

1. Create a project. Add an **App Store** app (bundle id `com.jtadevs.arco`, upload the `.p8` In-App Purchase key
   from 9.2) and a **Play Store** app (package name, upload the service-account JSON from 9.3).
2. Products → import or add `arco.unlock.full` for both stores.
3. **Entitlements** → create one with the identifier **`premium`** and attach both store products to it. This *is*
   needed now, and this is the paragraph that changed when the packs became one unlock: an entitlement is how
   RevenueCat models a permanent thing a customer either holds or does not, which is exactly what a non-consumable
   is. (With the old consumables there was nothing permanent to attach, which is why this used to say entitlements
   were not needed.)

   The entitlement is what makes the app's own customer-info check meaningful, and the server reads it too — but
   **never as authority for a grant**: an entitlement carries no store transaction id, and the transaction id is the
   idempotency key that stops a refunded payment unlocking again. If RevenueCat reports the entitlement and the
   server has no matching transaction, the server logs

   ```
   RevenueCat reports the "premium" entitlement for player=… but no arco.unlock.full transaction
   ```

   which means the product is attached to the wrong entitlement, or to none, or somebody granted the entitlement by
   hand in the dashboard. It is the one purchase warning that needs a human in the dashboard.
4. **API keys** — there are two kinds and they are not interchangeable:

   | key | where it goes | secret? |
   |---|---|---|
   | **public SDK key**, `appl_…` (iOS) | `--dart-define=REVENUECAT_IOS_KEY=…` (9.5) | no — it is in every build |
   | **public SDK key**, `goog_…` (Android) | `--dart-define=REVENUECAT_ANDROID_KEY=…` (9.5) | no |
   | **secret API key**, `sk_…` | the server's `REVENUECAT_API_KEY` (9.6) | **yes — server only, never in the app** |

5. **Webhook**: Integrations → Webhooks → add one.
   - URL: `https://<your-server>/api/purchases/webhook`
   - Authorization header value: invent a long random string (`openssl rand -hex 32`) and paste it here. The
     **same** string goes into the server's `REVENUECAT_WEBHOOK_SECRET` (9.6). Paste it identically in both
     places; `Bearer <string>` is accepted too, but pick one form and keep it.
   - Event types: all of them is fine. The server grants on `NON_RENEWING_PURCHASE` and `INITIAL_PURCHASE`, revokes
     on `CANCELLATION` and `REFUND`, and acknowledges everything else with a `200` so RevenueCat stops retrying. A
     non-consumable arrives as `NON_RENEWING_PURCHASE`: RevenueCat uses that type for every purchase that will not
     auto-renew.
6. Leave **App User IDs** alone. The app sets the RevenueCat app user id to the Arco player id itself, which is
   what lets a webhook name a player with no mapping table in between — and what lets a restore find the same
   player again.

### 9.5 Compile-time values the app reads

Public SDK keys, one per platform, in `lib/app/purchase_config.dart`. Not secrets: a public SDK key is baked into
every build of every app that uses RevenueCat, it can only make purchases *for this app*, and our server never
believes anything the SDK says with it.

| `--dart-define` | needed for | value |
|---|---|---|
| `REVENUECAT_IOS_KEY` | iOS | the RevenueCat **public** iOS SDK key, `appl_…` |
| `REVENUECAT_ANDROID_KEY` | Android | the RevenueCat **public** Android SDK key, `goog_…` |

With neither set the app reports the store unavailable and the shop offers nothing to buy — which is exactly what a
fork with no RevenueCat project should see.

```bash
flutter build ipa --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=REVENUECAT_IOS_KEY=appl_xxxxxxxxxxxxxxxxxxxxxxxx
flutter build appbundle --dart-define=SERVER_URL=https://arco.fly.dev \
  --dart-define=REVENUECAT_ANDROID_KEY=goog_xxxxxxxxxxxxxxxxxxxxxxxx
```

### 9.6 Server side

```bash
fly secrets set PURCHASES_ENABLED=on
fly secrets set REVENUECAT_WEBHOOK_SECRET=<the same string you pasted into RevenueCat>
fly secrets set REVENUECAT_API_KEY=sk_xxxxxxxxxxxxxxxxxxxxxxxx
# staging only — grants premium from sandbox purchases so you can test before real money exists:
# fly secrets set PURCHASES_SANDBOX=on
```

Both secrets are required with the switch on, and the server **refuses to start** without them. Setting them while
`PURCHASES_ENABLED` is off starts normally and logs a warning, because that combination is nearly always a
mistake. Neither is ever logged.

The startup line to look for is `purchases enabled: arco.unlock.full (entitlement "premium"), sandbox ignored`.

`GET /api/health` is the single source of truth about the *deployment*: `"purchases": true` means it can take money
and the app will offer the unlock; `false` means it will not, and there is nothing to explain to anybody. Whether a
*player* is premium is `GET /api/shop/inventory` (`"premium": true`), which is also the only thing the app acts on.

### 9.7 Seeing the payment sheet with no App Store account at all (simulator)

`ios/Arco.storekit` is a checked-in **StoreKit configuration**: the product of §9.1 as a non-consumable, with a
placeholder price. It is already referenced by the shared `Runner` scheme's Run action, so there is nothing to
configure — it exists so the sheet, the price and the whole purchase flow can be exercised on a simulator before
anybody has an App Store Connect product or a sandbox Apple ID.

Its price is a **placeholder and is never shown by anything but this file**: the app prints whatever StoreKit hands
it (§9.1), so what you see on the simulator is what this file says, and what a player sees is what Apple says.

**It only applies when Xcode launches the app.** Open `ios/Runner.xcworkspace` and press Run. Xcode syncs the
configuration into the simulator as part of launching (`DVTDevice
handleStoreKitConfigurationSyncForBundleID:configurationFilePath:`); `flutter run` and `flutter test` install and
launch through `simctl`, which does not, so StoreKit answers those launches with **no products** and the shop
correctly offers nothing to buy. If you see "the store could not be reached" after a `flutter run`, that is this and
not a bug — check it from Xcode.

Because the product is now a non-consumable, the simulator will also let you buy it **once** and then report it as
already owned; Xcode's Debug → StoreKit → Manage Transactions is where you delete the transaction to buy it again.

A purchase made this way still has to reach RevenueCat to become premium, and RevenueCat needs the real project of
§9.4. So the StoreKit configuration proves the *store* half on a simulator; the granting half is proved by the
server's own tests and by `integration_test/money_tour_test.dart`.

### 9.8 What to check on a device

Use a **TestFlight** build and a **sandbox** Apple ID (Settings → App Store → Sandbox Account), against a staging
server with `PURCHASES_SANDBOX=on`. A sandbox purchase against a production server is deliberately ignored.

- The shop shows **one** thing to buy, with a price in **your** currency, below the "earned today" panel.
- Buying it: the sheet appears, and afterwards every look in the shop is yours — including ones you had not bought
  with Sparks — the card is a confirmation with no price, and the ad row is gone.
- Buying it with the phone in airplane mode after the sheet: "paid, unlocking shortly", and it is unlocked when you
  come back — the webhook does not need the app to be running.
- Cancelling the sheet says **nothing at all**.
- With Screen Time → Content and Privacy → In-app Purchases set to *Don't Allow*, the app says the device does not
  allow purchases.
- **Delete the app, reinstall it, sign in, and press Restore Purchases**: everything comes back. This is the check
  that matters most, and the one a consumable could never pass.
- **Kill the app, turn on airplane mode and reopen it**: everything is still unlocked, off the cached snapshot alone.
- The shop shows **no Spark figure** afterwards — the app bar says *Unlocked*, the "earned today" panel is gone, and
  a finished run shows no reward chip. The wallet is still being credited underneath: read
  `GET /api/shop/inventory` (or the refund check below) to see it move. One rule, deliberately: a Spark figure
  appears only where it can be acted on.
- Every look also reads as owned in **Settings → Theme** and on the welcome screen, with no lock badges anywhere.
- Refund the sandbox purchase in RevenueCat (Customers → the customer → the transaction → Refund) and confirm the
  unlock goes away — **and that a look you had already bought with Sparks is still yours**, still equipped, while
  the premium-only one you were wearing falls back to the free default. The Spark balance comes back too, carrying
  everything the account earned while it was hidden.
- `SELECT * FROM purchases` on the server shows one row per payment, with `source = 'webhook'`. A ledger that is all
  `sync` means the webhook is not arriving, and a broken webhook is a refund with nowhere to land.

### 9.9 Rewarded ads

Implemented, and a separate switch: see §10. They are offered only to players who have **not** bought the unlock.

---

## 10. Rewarded ads that pay Sparks (AdMob) — [money]

Nothing here is needed to ship, and nothing here is needed to *play*. Until you finish this section the server
answers `404 ads_disabled`, the app shows no ad button anywhere, and there is nothing to explain to anybody.

The whole point of the design is that **the phone never says how much an ad paid**. AdMob tells our server
directly, with a signature, and our server decides the amount from its own table. So most of this section is about
making that one callback reach the right place.

**You can walk the entire loop before you open an AdMob account.** Google publishes test ad units that serve a real
rewarded ad to anybody, and they are already wired in — see §10.1. Do that first; come back for the account when
you want real revenue.

### 10.1 Test ads, with no AdMob account

```bash
flutter run --dart-define=ADMOB_TEST_ADS=on
```

That switches the app to Google's **published** test ad units, which always fill. The AdMob *application* ids the
SDK needs are already checked in — Google's test ones — in `ios/Runner/Info.plist` (`GADApplicationIdentifier`) and
`android/app/src/main/AndroidManifest.xml` (`com.google.android.gms.ads.APPLICATION_ID`). Replace both with your own
in §10.2.

The server side still has to be on, and the callback still has to reach it (§10.4). Test ads produce real signed
SSV callbacks, so this exercises the whole path: load, show, Google's callback, our signature check, our credit.

`ADMOB_TEST_ADS` is a **build-time** switch on purpose: a release build cannot be talked into test ads by a stale
preference, and a test id cannot be left serving in a shipped app.

### 10.2 AdMob account and app

1. Create an AdMob account at <https://apps.admob.com> and link it to the Google account you want paid.
2. **Apps → Add app**, once per platform (iOS and Android). If the app is already on a store, pick it; otherwise say
   it is not published yet and link it later.
3. Copy each **App ID** (`ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY`, with a **tilde**) and paste it over Google's test
   id:
   - `ios/Runner/Info.plist` → `GADApplicationIdentifier`
   - `android/app/src/main/AndroidManifest.xml` → `com.google.android.gms.ads.APPLICATION_ID`

   The SDK reads these from the platform manifest, not from Dart, and it will **crash on initialisation** if the id
   is missing or belongs to another account. There is no `--dart-define` for them.
4. In **App settings** for each app, fill in the privacy and data-use answers AdMob asks for. Apple also needs the
   app's privacy answers in App Store Connect to say that data is collected for third-party advertising — a rewarded
   ad collects an advertising identifier, and that is a disclosure whether or not you think of it as tracking.

### 10.3 Ad units

One **rewarded** ad unit per platform. Nothing else — this app has no interstitial, no banner and no app-open ad,
and `test/services/ad_pin_test.dart` fails the build if one is ever added without a deliberate change.

1. **Ad units → Add ad unit → Rewarded**.
2. Name it something you will recognise (`Arco rewarded — Sparks`).
3. **Reward amount** and **reward item**: put anything. `10` and `sparks` read best in the dashboard, but the server
   **does not read either value** — what an ad pays is `AdRate.sparksPerAd` in `server/lib/src/tokens.dart`. A number
   typed into a web form is not a source of truth about an economy. Both values are recorded in our ledger so a
   dashboard that has drifted from the code is visible in a query.
4. Copy each **Ad unit ID** (`ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ`, with a **slash**).

### 10.4 The server-side verification URL — the important one

In each rewarded ad unit: **Ad unit → Server-side verification → Edit** and set

```
https://<your-server>/api/ads/callback
```

That is the **only** thing that credits a Spark. Get it wrong and players watch ads for nothing; leave it empty and
the same.

- It must be **HTTPS** and reachable from the public internet. AdMob will not call a private address.
- No trailing slash, no query string of your own — unless you use the optional key below.
- AdMob appends its own parameters (`ad_network`, `ad_unit`, `custom_data`, `reward_amount`, `reward_item`,
  `timestamp`, `transaction_id`, `user_id`, then `signature` and `key_id`).
- Set it on **both** platforms' ad units. Forgetting one means Android players earn nothing.

Then turn the feature on:

```bash
fly secrets set ADS_ENABLED=on
```

That is all it needs. Unlike purchases, there is **no secret to configure**: what authenticates the callback is
Google's own ECDSA signature over the query string, checked against the keys Google publishes at
`https://www.gstatic.com/admob/reward/verifier-keys.json`. Your server must be able to reach that URL over HTTPS.

**Optional hardening.** If you would like the callback URL to be revocable:

```bash
fly secrets set ADMOB_CALLBACK_KEY=$(openssl rand -hex 24)
```

and then set the SSV URL to `https://<your-server>/api/ads/callback?arco_key=<that value>`. Because AdMob appends
its parameters *after* yours, the key ends up inside the content Google signs, so it cannot be stripped or forged.
It is not the authentication — the signature is — but it means a leaked URL can be killed by changing one variable.
**Set it on both sides or on neither:** the key with no `arco_key` in the URL makes every reward a `401 invalid_key`,
with a log line naming the variable.

`GET /api/health` is the single source of truth: `"ads": true` means the deployment credits ads and the app may
offer one; `false` means it will not, and no button appears.

### 10.5 Compile-time values the app reads

The ad unit ids are **never** in source — they are an account identifier, and a real one in a repository is a real
one that forks and CI builds would send impressions to.

```bash
flutter build ios --release \
  --dart-define=ADMOB_IOS_REWARDED_UNIT=ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ \
  --dart-define=ADMOB_ANDROID_REWARDED_UNIT=ca-app-pub-XXXXXXXXXXXXXXXX/WWWWWWWWWW
```

| define | value | what happens without it |
|---|---|---|
| `ADMOB_IOS_REWARDED_UNIT` | the iOS rewarded unit id | no ad button on iOS |
| `ADMOB_ANDROID_REWARDED_UNIT` | the Android rewarded unit id | no ad button on Android |
| `ADMOB_TEST_ADS` | `on` to use Google's test units instead | — (and it **overrides** the two above) |

A build given none of them shows no ad button at all — not a disabled one, not an error. That is also what the web
build and every desktop get, because AdMob has no ads there. Keep these in the same place as your RevenueCat keys
(§9.5): a CI secret, or a local `--dart-define-from-file` JSON that is not committed.

### 10.6 Consent — exactly what a human has to configure

Ads in the EEA, the UK, Switzerland and the regulated US states need a consent choice before a personalised ad may
be requested. The app already wires Google's **UMP** SDK; what it cannot do for you is create the message.

1. **AdMob → Privacy & messaging → GDPR.** Create a **GDPR message**, pick the languages you ship (English and
   Polish), and choose the consent options you want to offer. Google's default "Consent or manage options" is fine.
   **Publish** it — an unpublished message means the form never appears and `canRequestAds()` stays false, so your
   European players simply never see an ad button.
2. **Privacy & messaging → US states.** Create and publish the **US states** message too if you serve the US.
3. In the GDPR message, list your **ad partners** (Google's default set is fine) and paste your **privacy policy
   URL**. The form will not publish without one, and the same URL belongs in your store listings.
4. **IDFA / App Tracking Transparency (iOS).** If you enable personalised ads, Apple requires an ATT prompt.
   Google's UMP can show it for you: in the GDPR message settings, turn on **"Also ask for ATT"** (AdMob calls it
   *App Tracking Transparency message*). If you turn that on you must also add an
   `NSUserTrackingUsageDescription` string to `ios/Runner/Info.plist` explaining why — iOS shows it verbatim, and an
   app that asks without one is rejected. If you would rather not ask at all, leave ATT off and serve
   non-personalised ads; the app treats that as a perfectly good ad and the button works exactly the same.
5. **Test devices.** A consent form only appears where consent is required, so from outside Europe you will never
   see it by accident. To test it: **AdMob → Settings → Test devices**, add your device by its hashed id (it is
   printed in the device log the first time the SDK runs), then construct
   `GoogleRewardedAds(debugGeographyEea: true)` in `lib/main.dart` for that build. Without the device in AdMob's
   list the debug geography does nothing at all, which is why this is safe to leave in a debug build and not in a
   release one.

**What the app does with all this, so you know what you are configuring for:** opening the shop only *checks*
whether a form is required — no UI. The form itself appears when the player taps the ad row, which is the moment
they have asked for the thing consent is needed for. A player who declines gets a fully working game with the ad
button simply absent, permanently and silently, and the row says that before they choose. The game-over overlay
never shows a form.

### 10.7 What to check on a device

- With `--dart-define=ADMOB_TEST_ADS=on` and `ADS_ENABLED=on`: the shop shows the ad row **between** the "earned
  today" panel and the one-time unlock, and the button appears only once an ad has loaded.
- Watch one. The balance goes up by `AdRate.sparksPerAd` and the message names the new balance.
- `SELECT * FROM ad_rewards` on the server shows one row, `sparks = 10`, `refused` null, and a `reward_amount`
  matching whatever you typed into AdMob — which the server ignored.
- Watch a second one immediately: **no button** (the five-minute cooldown), and the row says when the next one is.
- Watch six in a day: the row says the day's ads are done, and a solo run still pays its **full** Sparks — the two
  caps are separate.
- Finish a solo run: the ad offer appears under the score, above RETRY, and only if one was already loaded. Start a
  run: **nothing** about ads anywhere.
- Turn airplane mode on right after the ad closes: "your sparks are on their way", and they are there when you come
  back — Google's callback does not need the app.
- With `ADS_ENABLED=off`: no ad row, no button, nothing in the logs, and `GET /api/ads/offer` answers
  `404 ads_disabled`.
- Set `debugGeographyEea: true` with your device registered as a test device: the consent form appears **on the
  tap**, not on launch. Decline it, and confirm the ad row disappears and the rest of the shop — cosmetics, wallet,
  earning panel, the unlock — works exactly as before.

---

## 11. Before you ship, check these yourself

- Play a duel between two real phones on mobile data, not only on your own Wi-Fi.
- Submit a score from a real phone and confirm it appears on the public leaderboard.
- Sign in on one phone, then sign in on a second and confirm your scores follow you.
- Delete your account from Settings and confirm it is really gone.
- Try the game in Polish and in English, and on the smallest phone you own.
- If you turned on purchases: buy the unlock with a sandbox account, reinstall the app and restore it, then refund
  it and confirm the unlock goes away while a cosmetic you bought with Sparks stays yours — [money].
- If you turned on ads: watch one and confirm the balance moves, watch a second immediately and confirm there is no
  button, then decline the consent form on a test device and confirm the game is untouched with the ad button gone
  — [money].

---

## 12. Running it once people play — [play]

None of this is about making a feature work, which is why it is easy to skip. All of it is about not losing
something later.

### 12.1 Back up the database

The server's volume holds the leaderboard, the wallets, the purchase ledger and the account links. If it is
lost, so are purchases people paid real money for, and that becomes a refund problem rather than an outage.

1. Snapshots are **already on**: Fly created `arco_data` with scheduled snapshots and 5-day retention.
   Confirm rather than assume, and lengthen the retention if you want more room:
   ```bash
   fly volumes list
   fly volumes snapshots list vol_vgnmm193mmqx5nj4
   ```
2. **Restore one at least once, before you need to.** A backup nobody has restored is a guess.
   ```bash
   fly volumes snapshots create <volume-id>       # take one on demand
   fly volumes create arco_data_restore --snapshot-id <id>
   ```
3. For a copy you hold yourself, pull the file down periodically:
   ```bash
   fly ssh sftp get /app/data/arco.db ./arco-backup-$(date +%F).db
   ```
   SQLite is a single file, so this is the whole backup. Do it while the server is quiet, or use
   `.backup` through `sqlite3` so you never copy a file mid-write.

### 12.2 Know when the server is down

If it stops, duels stop and scores silently fail to save, and nobody will tell you. Point any free uptime
monitor at `https://<your-server>/api/health` every five minutes and have it message your phone. The endpoint
answers `{"ok":true,...}` and needs no authentication, so it is safe to poll.

### 12.3 Deploys interrupt live duels

Every `fly deploy` restarts the process, and a room lives in memory, so any duel in progress ends. Solo games
are unaffected and pending scores retry by themselves. Deploy when nobody is playing.

### 12.4 Support contact and terms

Both stores require a support URL or email in the listing, and neither accepts a blank one. If you sell
anything, add a short terms-of-service page as well, separate from the privacy policy. A plain page on any
domain you control is enough for both.

### 12.5 Age rating versus ads — decide before you fill in the questionnaire

This one has consequences you cannot undo easily. If you declare the app as directed at children, both
platforms sharply restrict advertising and advertising identifiers, and Apple's Kids Category forbids
third-party ads outright. Arco looks child-friendly, so the questionnaire will push you that way.

Pick one, deliberately:

- **Not directed at children.** Ads and an advertising identifier are allowed, with the consent flow of §10.6.
- **Directed at children.** Turn ads off entirely with `ADS_ENABLED=off` and ship without them. Everything else
  in the game keeps working, and the shop simply shows no ad row.

Answering "directed at children" while serving ads is the version that gets an app pulled.

### 12.6 Keep the code somewhere other than your laptop — DONE

The repository is pushed to **github.com/tymonq19/ARCO**. Keep pushing after each change; the point is that a
dead laptop costs you a day, not the project.

One decision left: that repository is **public**. There are no secrets in it, and the leaderboard's
cheat-resistance does not depend on the code being private, but anyone can build and publish their own copy of
a game you intend to sell. Switching it to private is one click in the repository settings, under Danger Zone.
