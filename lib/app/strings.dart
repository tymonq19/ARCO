import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/device_country.dart';
import 'settings.dart';

/// Localized UI strings (EN + PL). Every user-visible text goes through
/// [Strings.of] so that the language switch in Settings applies everywhere.
class Strings {
  const Strings(this.languageCode);

  /// Resolved language code: `en` or `pl`.
  final String languageCode;

  /// Resolves the language from the [Settings] override or the system locale.
  static Strings of(BuildContext context) {
    final settings = Provider.of<Settings>(context, listen: true);
    return Strings(resolveLanguage(settings.language, _systemLocale(context)));
  }

  /// Same as [of] but without subscribing to [Settings]; use this inside
  /// callbacks and async code, where listening is not allowed.
  static Strings read(BuildContext context) {
    final settings = Provider.of<Settings>(context, listen: false);
    return Strings(resolveLanguage(settings.language, _systemLocale(context)));
  }

  static Locale _systemLocale(BuildContext context) =>
      Localizations.maybeLocaleOf(context) ??
      WidgetsBinding.instance.platformDispatcher.locale;

  /// `MaterialApp.locale` for [setting]: `null` for [AppLanguage.system], so
  /// WidgetsApp keeps resolving the device locale against `supportedLocales`.
  /// Any other value pins the locale, which makes Material's own strings
  /// follow the in-app language switch together with this table.
  static Locale? localeFor(AppLanguage setting) =>
      setting == AppLanguage.system ? null : Locale(setting.name);

  static String resolveLanguage(AppLanguage setting, Locale system) {
    switch (setting) {
      case AppLanguage.en:
        return 'en';
      case AppLanguage.pl:
        return 'pl';
      case AppLanguage.system:
        return system.languageCode.toLowerCase() == 'pl' ? 'pl' : 'en';
    }
  }

  Map<String, String> get _map => languageCode == 'pl' ? pl : en;

  /// Looks up [key]; falls back to English and finally to the key itself.
  String t(String key) => _map[key] ?? en[key] ?? key;

  /// Message for a protocol / connection error code, falling back to a
  /// generic message for codes this build does not know.
  String error(String? code) {
    if (code == null || code.isEmpty) return t('error.unknown');
    final key = 'error.$code';
    return en.containsKey(key) ? t(key) : t('error.unknown');
  }

  /// A country as the app names it: its flag and its ISO 3166-1 alpha-2 code.
  ///
  /// No table of country names — the server deliberately ships none (SPEC §4.6)
  /// and neither does Flutter, and inventing 249 names in two languages to label
  /// one leaderboard tab would be a worse answer than the flag everybody already
  /// reads.
  String country(String code) => f('lb.country', {
    'flag': DeviceCountry.flagEmoji(code),
    'code': code.toUpperCase(),
  });

  /// How many balls a game is played with, as the app names it (SPEC §2.3).
  ///
  /// One phrase for the toggle, the leaderboard's board switch, the duel room
  /// and the personal best, so the same game is never called two things. The
  /// case is the theme's to decide (`GameTheme.heading`), which is why this is
  /// set in sentence case.
  String balls(int count) => t(count >= 2 ? 'game.twoBalls' : 'game.oneBall');

  /// Message for a score-submission error code (SPEC §4). Unlike [error] this
  /// falls back to "the server refused it" rather than to a generic failure:
  /// the player is being told what happened to a game they just played.
  String submitError(String? code) {
    final key = 'error.$code';
    return code != null && en.containsKey(key) ? t(key) : t('solo.rejected');
  }

  /// The provider's display name (`Apple`, `Google`), or the raw name for one
  /// this build has never heard of.
  String accountProvider(String? name) {
    if (name == null || name.isEmpty) return '';
    final key = 'account.provider.$name';
    return en.containsKey(key) ? t(key) : name;
  }

  /// Message for a sign-in or deletion refusal (SPEC §4.5), with `{provider}`
  /// filled in for `already_linked`. A code this build has no sentence for falls
  /// back to the honest "it did not finish" rather than to the code itself.
  String accountError(String code, {String? provider}) {
    final key = 'account.error.$code';
    final text = en.containsKey(key) ? t(key) : t('account.error.unknown');
    return text.replaceAll('{provider}', accountProvider(provider));
  }

  /// An amount of the shop currency, named and **declined** (SPEC §4.8).
  ///
  /// The currency is *Sparks* / *Iskry*: it belongs to a game made of light and
  /// hits that throw sparks, where "coins" would belong to anything. Polish
  /// needs three forms of it — 1 iskra, 2-4 iskry, 5+ iskier, with the
  /// 12-14 exception that catches every naive implementation — and a currency
  /// that is ungrammatical every time a number ends in 5 is a currency nobody
  /// believes in.
  String sparks(int n) {
    final amount = n.abs();
    if (amount == 1) return f('currency.one', {'n': n});
    if (languageCode == 'pl') {
      final tens = amount % 100;
      final unit = amount % 10;
      // 12-19 take the many form even though 2-4 do: dwanaście iskier, not
      // dwanaście iskry.
      final few = unit >= 2 && unit <= 4 && (tens < 12 || tens > 14);
      return f(few ? 'currency.few' : 'currency.many', {'n': n});
    }
    return f('currency.few', {'n': n});
  }

  /// The display name of a catalogue item (SPEC §4.8). The server's `nameKey`
  /// *is* the item id, so `ball.comet` is both the id and the key; an item this
  /// build has no name for shows its id rather than an empty card.
  String item(String nameKey) => t(nameKey);

  /// Looks up [key] and substitutes `{name}` placeholders from [args].
  String f(String key, Map<String, Object> args) {
    var s = t(key);
    args.forEach((k, v) => s = s.replaceAll('{$k}', v.toString()));
    return s;
  }

  static const Map<String, String> en = {
    'app.title': 'ARCO',
    'common.home': 'HOME',
    'common.back': 'Back',
    'common.ok': 'OK',
    'common.cancel': 'CANCEL',
    'common.retry': 'RETRY',
    'common.rankValue': '#{rank}',
    'home.tagline': 'Keep the ball in the ring',
    'home.nickname': 'Nickname',
    'home.nicknameHint': '2–12 characters: letters, digits, space, _ or -',
    'home.solo': 'SOLO',
    'home.duel': 'DUEL',
    'home.leaderboard': 'LEADERBOARD',
    'home.settings': 'SETTINGS',
    'home.best': 'Personal best',
    // Named with the board it belongs to as soon as the player has chosen a
    // game other than the classic one: the figure changes when the ball count
    // does, and a number that moves without saying why reads as a bug.
    'home.bestOf': 'Personal best · {balls}',
    'home.noBest': 'No games played yet',
    'home.rank': 'Global rank',
    'home.countryRank': 'Rank in {country}',
    'home.rankUnranked': 'Not ranked yet',
    'name.title': 'Choose a nickname',
    'name.save': 'SAVE',
    'onboarding.welcome': 'Welcome! Pick a look and a name.',
    'onboarding.pickTheme': 'Choose a look',
    'onboarding.nicknameLabel': 'Your nickname',
    'onboarding.changeLater': 'Both can be changed later.',
    'onboarding.start': 'START PLAYING',
    'hud.score': 'Score',
    'hud.time': 'Time',
    'hud.best': 'Best',
    'hud.lives': 'Lives',
    // How many balls the next game is played with (SPEC §2.3). A rule of the
    // game, not a preference, so it is worded as one and lives next to the
    // serve it changes.
    'game.balls': 'Balls in play',
    'game.oneBall': '1 ball',
    'game.twoBalls': '2 balls',
    'game.ballsNote':
        'Two balls is a different game: losing either one costs a life.',
    'solo.tapToStart': 'TAP TO START',
    'solo.controlsHint.joystick':
        'Slide your thumb on the lower half of the screen',
    'solo.controlsHint.tilt': 'Tilt your phone to move the paddle',
    'solo.controlsHint.follow': 'Tap where you want the paddle to go',
    'solo.paused': 'PAUSED',
    'solo.resume': 'RESUME',
    'solo.gameOver': 'GAME OVER',
    'solo.newBest': 'NEW BEST!',
    'solo.retry': 'RETRY',
    'solo.submitting': 'Submitting score…',
    'solo.rank': 'Global rank #{rank}',
    'solo.savedLocally': 'Offline — saved locally, will retry later',
    'solo.rejected': 'Score rejected by the server',
    'solo.invalidName': 'Set a valid nickname to submit scores',
    'solo.pendingSent': 'Pending score submitted: rank #{rank}',
    'solo.rankCountry': 'Global rank #{rank} · #{countryRank} in {country}',
    'solo.changeName': 'CHANGE NICKNAME',
    'duel.title': 'DUEL',
    'duel.create': 'CREATE ROOM',
    'duel.join': 'JOIN',
    'duel.joinTitle': 'Join a room',
    'duel.roomCode': 'Room code',
    'duel.enterCode': 'Enter the 4-letter code',
    'duel.waiting': 'Waiting for a friend…',
    'duel.copy': 'COPY CODE',
    'duel.copied': 'Code copied to clipboard',
    'duel.share': 'SHARE',
    'duel.shareText': 'Join my Arco duel! Room code: {code}',
    'duel.shared': 'Invitation copied to clipboard',
    'duel.connecting': 'Connecting…',
    'duel.connected': 'Connected',
    'duel.disconnected': 'Disconnected',
    'duel.ping': 'Ping',
    'duel.opponentJoined': '{name} joined!',
    // The ball count is the creator's to pick, and the joiner is told what they
    // have walked into before the first serve (SPEC §2.3, §3).
    'duel.ballsRoom': 'This room plays {balls}',
    'duel.ballsHost': 'You pick; your opponent is told before the first serve.',
    'duel.starting': 'Starting…',
    'duel.getReady': 'GET READY',
    'duel.go': 'GO!',
    'duel.you': 'You',
    'duel.opponent': 'Opponent',
    'duel.win': 'YOU WIN',
    'duel.lose': 'YOU LOSE',
    'duel.rematch': 'REMATCH',
    'duel.leave': 'LEAVE',
    'duel.waitingRematch': 'Waiting for the opponent…',
    'duel.peerLeft': 'Your opponent left the game',
    'duel.connectionLost': 'Connection lost',
    'error.bad_code': 'Invalid room code',
    'error.room_not_found': 'Room not found',
    'error.room_full': 'That room is full',
    'error.not_in_room': 'You are not in a room',
    'error.bad_message': 'Protocol error',
    'error.rate_limited': 'Too many requests — try again in a minute',
    // Both version refusals say what to do about it. "Not supported by the
    // server" reads as a verdict the player has to accept; the truth is that a
    // newer build fixes it, and on a submission the game is still stored.
    'error.bad_version': 'Update Arco to play online',
    'error.bad_name': 'Invalid nickname',
    'error.connection': 'Could not connect to the server',
    'error.timeout': 'The server did not respond in time',
    'error.closed': 'The connection was closed',
    'error.unknown': 'Something went wrong',
    'error.offensive_name':
        'That nickname cannot go on the leaderboard. Pick another one and '
        'your score goes up under it.',
    'error.invalid_name': 'Invalid nickname',
    'error.invalid_replay': 'The server could not verify this game',
    'error.replay_mismatch': 'The score does not match the game',
    // The run was fine; this build's replay format is not one the server reads
    // (SPEC §2.5: `Replay.version`). The game stays stored, so this is an
    // instruction and not a verdict.
    'error.unsupported_version': 'Update Arco to submit this score',
    'error.too_large': 'That game is too long to submit',
    'lb.title': 'LEADERBOARD',
    'lb.all': 'All time',
    'lb.week': 'This week',
    'lb.day': 'Today',
    // Which of the two boards is on screen (SPEC §4.6): the ball count is part
    // of the game, so a one-ball score and a two-ball score are not ranked
    // against each other.
    'lb.board': 'Board',
    'lb.empty': 'No scores yet — be the first!',
    'lb.offline': 'Could not load the leaderboard',
    'lb.retry': 'RETRY',
    'lb.you': 'you',
    'lb.seconds': '{s} s',
    'lb.country': '{flag} {code}',
    'lb.countryEmpty': 'No scores from {country} yet — be the first!',
    'settings.title': 'SETTINGS',
    'settings.theme': 'Theme',
    'settings.language': 'Language',
    'settings.langSystem': 'System',
    'settings.langEn': 'English',
    'settings.langPl': 'Polish',
    'settings.sound': 'Sound',
    'settings.haptics': 'Haptics',
    // The drifting ball behind the title screen. Named for what it does rather
    // than for what it is: "menu motion" is the thing somebody who dislikes
    // movement behind text will look for.
    'settings.menuMotion': 'Menu motion',
    'settings.menuMotionDesc': 'Your ball drifts behind the main menu',
    'settings.controls': 'Controls',
    'settings.controlJoystick': 'Joystick',
    'settings.controlTilt': 'Tilt',
    'settings.controlFollow': 'Follow',
    'settings.controlJoystickDesc': 'Floating stick under your thumb',
    'settings.controlTiltDesc': 'Tilt the phone left / right',
    'settings.controlFollowDesc': 'The paddle chases your finger',
    'settings.tiltSensitivity': 'Tilt sensitivity',
    'settings.calibrate': 'CALIBRATE',
    'settings.calibrated': 'Calibrated — this position is now level',
    'settings.tiltPreview': 'Tilt preview',
    'settings.tiltUnavailable': 'Tilt sensor unavailable on this device',
    'settings.joystickSide': 'Joystick position',
    'settings.sideFloat': 'Floating',
    'settings.sideLeft': 'Left',
    'settings.sideRight': 'Right',
    'settings.advanced': 'Advanced',
    'settings.serverUrl': 'Server URL',
    'settings.serverHint': 'e.g. http://192.168.1.20:8080',
    'settings.serverReset': 'Reset to default',
    'settings.testConnection': 'TEST CONNECTION',
    'settings.serverOk': 'Server OK (v{version}, rooms: {rooms})',
    'settings.serverFail': 'Server unreachable',
    'settings.serverTesting': 'Testing…',
    'theme.neon': 'Neon',
    'theme.classic': 'Classic',
    'theme.modernist': 'Modernist',
    'theme.glass': 'Glass',
    // ------------------------------------------------- cosmetic shop (4.8)
    // The currency is **Sparks**: the game is a ring of light where every hit
    // throws a shower of them, so the word is already on screen before it is a
    // number. "Coins" would belong to any game at all.
    'currency.name': 'Sparks',
    'currency.one': '{n} spark',
    'currency.few': '{n} sparks',
    'currency.many': '{n} sparks',
    'shop.title': 'SHOP',
    'shop.tagline': 'Looks, balls and paddles',
    'shop.open': 'SHOP',
    'shop.section.theme': 'Looks',
    'shop.section.ball': 'Balls',
    'shop.section.paddle': 'Paddles',
    'shop.equipped': 'WORN',
    'shop.owned': 'OWNED',
    'shop.wear': 'WEAR',
    'shop.locked': 'In the shop',
    'shop.buy': 'BUY',
    'shop.buyTitle': 'Buy {item}?',
    'shop.buyBody':
        'It costs {price}. Your wallet holds {balance} right now.\n\nIt is a '
        'look and nothing more: no item in this shop changes how the game '
        'plays.',
    'shop.buying': 'Buying…',
    'shop.bought': 'Bought {item} — {balance} left.',
    'shop.insufficient': 'Not enough yet — {missing} to go.',
    'shop.buyOffline':
        'No connection, so nothing was bought and nothing was taken. Try again '
        'when you are back online.',
    'shop.buyFailed':
        'That did not go through, and nothing was taken. You can safely try '
        'again.',
    'shop.offline':
        'The shop needs a connection. Everything you already own keeps working.',
    'shop.unavailable':
        'The shop is not answering right now. Nothing has been charged — try '
        'again in a minute.',
    'shop.earnTitle': 'Earned today',
    'shop.earnedToday': '{earned} of {cap}',
    'shop.capReached':
        'You have earned today\'s {cap}. The allowance resets at midnight UTC — '
        'play on, it just stops paying.',
    'shop.earnHint': 'Sparks come from playing: every solo run pays into this.',
    'shop.accountHint':
        'Signing in keeps what you have bought if you lose this phone.',
    'shop.equipPending':
        'Saved on this phone — it reaches your account when you are online.',
    'shop.updateApp':
        'There is newer content than this version of the app can draw.',
    'shop.balanceUnknown': 'Play a run to start earning',
    // The one-time unlock — one non-consumable purchase (SPEC §4.9).
    //
    // The tone is the product decision: the unlock is a shortcut and a
    // convenience, not the point of the game, so nothing here urges, compares,
    // counts down or calls anything a deal. There is no second tier to be better
    // than, and no price in this table — the price is the store's, printed
    // verbatim from whatever StoreKit or Google Play hands the app.
    'unlock.full': 'Unlock everything',
    'shop.unlockTitle': 'One-time unlock',
    'shop.unlockPerk.now': 'Every look, ball and paddle in the shop.',
    'shop.unlockPerk.later': 'And every one added later, at no extra cost.',
    'shop.unlockPerk.ads': 'No ads, ever.',
    'shop.unlockButton': 'UNLOCK',
    'shop.unlockFree':
        'Paid once, and that is all. Everything here is earned by playing too — '
        'this just skips the waiting.',
    'shop.unlockStoreSilent':
        'The store is not answering right now, so there is no price to show. '
        'Playing still earns sparks.',
    'shop.unlockDone': 'Everything is unlocked. Enjoy.',
    'shop.unlockWaiting':
        'Paid. It unlocks in a moment — even if you close the game.',
    'shop.unlockPending':
        'The payment is waiting for approval. Everything unlocks as soon as it '
        'goes through, even if the game is closed.',
    'shop.unlockNotAllowed': 'This device does not allow purchases.',
    'shop.unlockStoreDown':
        'The store did not answer. Nothing was charged — try again later.',
    'shop.unlockOffline': 'No connection. Nothing was charged.',
    'shop.unlockFailed':
        'The purchase did not go through. Nothing was charged.',
    // What a player who has bought it sees, everywhere a balance used to be. Kept
    // to one word: it replaces a figure in an app bar, on a 320 pt phone, at 1.6
    // text scale.
    'shop.premiumBadge': 'Unlocked',
    'shop.unlockedTitle': 'Your purchase',
    'shop.unlockedHeading': 'Everything is unlocked',
    'shop.unlockedBody':
        'Every look, ball and paddle is yours — including the ones added later — '
        'and there are no ads. That is the whole of it. Thank you.',
    // Restore purchases (SPEC §4.9). The unlock is a non-consumable, so this is a
    // real feature and the sentence can simply say when to use it.
    'shop.restore': 'RESTORE PURCHASES',
    'shop.restoreHint':
        'Bought the unlock before, on this phone or another one? This asks the '
        'store for it and puts it back. Safe to tap more than once.',
    'shop.restoreDone': 'Restored — everything is unlocked again.',
    'shop.restoreNothing':
        'No purchase found for this store account. If you paid with a different '
        'Apple or Google account, sign in to that one and try again.',
    'shop.restoreFailed': 'Could not reach the store. Try again later.',
    // Rewarded ads that pay Sparks (SPEC §4.10).
    //
    // The tone is the product decision again, and the rule is stronger than for
    // the unlock: an ad is something the player gives us — half a minute of their
    // attention — so it is offered once, quietly, with what it pays stated plainly
    // and no suggestion that anything is waiting behind it. Nothing here urges,
    // counts down, or calls watching an ad a reward for anything but the time it
    // takes.
    'ads.title': 'From ads today',
    'ads.hint':
        'A short ad pays {sparks}. Completely optional — playing pays more, and '
        'nothing in the game is behind an ad.',
    'ads.watch': 'WATCH AN AD',
    'ads.today': '{earned} of {cap}',
    'ads.cooldown': 'The next one in about {minutes} min.',
    'ads.dayFull':
        "That's all of today's ads. The allowance resets at midnight UTC — and "
        'playing keeps paying in the meantime.',
    // The consent ask. It appears where the player is already reading about
    // earning Sparks, never on launch, and it says up front that saying no costs
    // them nothing — because it does not.
    'ads.consentHint':
        'Ads need your choice about data first. Say no and the game is exactly '
        'the same; the ad button simply goes away.',
    'ads.consentButton': 'CHOOSE ABOUT ADS',
    'ads.credited': 'Thanks — {sparks} added. You now have {balance}.',
    'ads.waiting':
        'Thanks. Your sparks are on their way — they land in a moment, even if '
        'you close the game.',
    'ads.noAd': 'No ad right now. Nothing lost — playing still pays.',
    'ball.orb': 'Orb',
    'ball.comet': 'Comet',
    'ball.prism': 'Prism',
    'ball.ember': 'Ember',
    'paddle.arc': 'Arc',
    'paddle.blade': 'Blade',
    'paddle.halo': 'Halo',
    'paddle.chevron': 'Chevron',
    'settings.shop': 'MORE LOOKS IN THE SHOP',
    'onboarding.moreLooks': 'More looks unlock in the shop as you play.',
    // ---------------------------------------------------------- account (4.5)
    'account.title': 'Account',
    'account.offerTitle': 'Keep this score safe',
    'account.offerBody':
        'Sign in and your scores survive a lost phone — and follow you to any '
        'device you play on.',
    'account.offerBodyBoard':
        'Sign in and your place on this board survives a lost phone — and '
        'follows you to any device you play on.',
    'account.notNow': 'NOT NOW',
    // Apple's approved wording, which their review checks for; the same form is
    // used for Google, whose branding asks for it too.
    'account.signInApple': 'Sign in with Apple',
    'account.signInGoogle': 'Sign in with Google',
    'account.working': 'Signing in…',
    'account.provider.apple': 'Apple',
    'account.provider.google': 'Google',
    'account.linkedWith': 'Signed in with {provider}',
    'account.linkedSince': 'Since {date}',
    'account.signedOutHint':
        'Not signed in. Your scores are kept on this phone only.',
    'account.signOut': 'SIGN OUT ON THIS DEVICE',
    'account.signOutDone':
        'Signed out. Your scores stay on the leaderboard — sign in again to get '
        'them back on this phone.',
    'account.outcome.created': 'Account created — your scores are safe now.',
    'account.outcome.linked': 'Done — your scores are on your account now.',
    'account.outcome.restored':
        'Welcome back — your scores are on this device again.',
    'account.outcome.merged':
        'Accounts merged — {count} of your runs moved across.',
    'account.outcome.retried': 'Already signed in on this device.',
    'account.delete': 'DELETE MY ACCOUNT',
    'account.deleteTitle': 'Delete your account?',
    'account.deleteBody':
        'This deletes your account, this phone\'s sign-in and every link '
        'between you and the runs you have played.\n\nThe scores themselves stay '
        'on the leaderboard without a name attached to you: removing them would '
        'change everybody else\'s rank. Your personal best on this phone stays '
        'too, and you can keep playing.',
    'account.deleteContinue': 'CONTINUE',
    'account.deleteConfirmTitle': 'This cannot be undone',
    'account.deleteConfirmBody':
        'There is no way to get the account back, and no way to prove those '
        'runs were yours afterwards.',
    'account.deleteConfirm': 'DELETE PERMANENTLY',
    'account.deleteCancel': 'KEEP MY ACCOUNT',
    'account.deleted': 'Account deleted',
    'account.deletedRuns':
        'Account deleted — {count} runs stay without an owner',
    'account.error.offline':
        'No connection — sign in again when you are back online.',
    'account.error.accounts_disabled':
        'Sign-in is switched off on this server.',
    'account.error.invalid_token':
        'That sign-in could not be verified. Please try again.',
    'account.error.invalid_credentials':
        'This device was signed out. Please try again.',
    'account.error.invalid_provider':
        'This server does not accept that sign-in.',
    'account.error.already_linked':
        'This player is already signed in with {provider}. Sign out on this '
        'device first.',
    'account.error.keys_unavailable':
        'The sign-in service cannot be reached right now — try again in a '
        'minute.',
    'account.error.rate_limited': 'Too many attempts — try again in a minute.',
    'account.error.unavailable':
        'That sign-in is not available on this device.',
    'account.error.no_token':
        'That sign-in returned nothing to verify. Please try again.',
    'account.error.unknown': 'Sign-in did not finish. Please try again.',
  };

  static const Map<String, String> pl = {
    'app.title': 'ARCO',
    'common.home': 'MENU',
    'common.back': 'Wstecz',
    'common.ok': 'OK',
    'common.cancel': 'ANULUJ',
    'common.retry': 'PONÓW',
    'common.rankValue': '#{rank}',
    'home.tagline': 'Utrzymaj piłkę w kole',
    'home.nickname': 'Pseudonim',
    'home.nicknameHint': '2–12 znaków: litery, cyfry, spacja, _ lub -',
    'home.solo': 'ZAGRAJ SOLO',
    'home.duel': 'POJEDYNEK',
    'home.leaderboard': 'TABLICA WYNIKÓW',
    'home.settings': 'USTAWIENIA',
    'home.best': 'Rekord osobisty',
    'home.bestOf': 'Rekord osobisty · {balls}',
    'home.noBest': 'Nie zagrano jeszcze żadnej gry',
    'home.rank': 'Miejsce na świecie',
    'home.countryRank': 'Miejsce w {country}',
    'home.rankUnranked': 'Brak miejsca w rankingu',
    'name.title': 'Wybierz pseudonim',
    'name.save': 'ZAPISZ',
    'onboarding.welcome': 'Witaj! Wybierz motyw i pseudonim.',
    'onboarding.pickTheme': 'Wybierz motyw',
    'onboarding.nicknameLabel': 'Twój pseudonim',
    'onboarding.changeLater': 'Oba możesz zmienić później.',
    'onboarding.start': 'ZACZNIJ GRAĆ',
    'hud.score': 'Wynik',
    'hud.time': 'Czas',
    'hud.best': 'Rekord',
    'hud.lives': 'Życia',
    'game.balls': 'Piłki w grze',
    'game.oneBall': '1 piłka',
    'game.twoBalls': '2 piłki',
    'game.ballsNote':
        'Dwie piłki to inna gra: utrata którejkolwiek kosztuje życie.',
    'solo.tapToStart': 'DOTKNIJ, ABY ZACZĄĆ',
    'solo.controlsHint.joystick': 'Przesuwaj kciukiem po dolnej połowie ekranu',
    'solo.controlsHint.tilt': 'Przechylaj telefon, aby ruszać paletką',
    'solo.controlsHint.follow': 'Dotknij tam, gdzie ma być paletka',
    'solo.paused': 'PAUZA',
    'solo.resume': 'WZNÓW',
    'solo.gameOver': 'KONIEC GRY',
    'solo.newBest': 'NOWY REKORD!',
    'solo.retry': 'JESZCZE RAZ',
    'solo.submitting': 'Wysyłanie wyniku…',
    'solo.rank': 'Miejsce #{rank} na świecie',
    'solo.savedLocally': 'Offline — zapisano lokalnie, spróbuję później',
    'solo.rejected': 'Serwer odrzucił wynik',
    'solo.invalidName': 'Ustaw poprawny pseudonim, aby wysyłać wyniki',
    'solo.pendingSent': 'Zaległy wynik wysłany: miejsce #{rank}',
    'solo.rankCountry':
        'Miejsce #{rank} na świecie · #{countryRank} w {country}',
    'solo.changeName': 'ZMIEŃ PSEUDONIM',
    'duel.title': 'POJEDYNEK',
    'duel.create': 'UTWÓRZ POKÓJ',
    'duel.join': 'DOŁĄCZ',
    'duel.joinTitle': 'Dołącz do pokoju',
    'duel.roomCode': 'Kod pokoju',
    'duel.enterCode': 'Wpisz 4-literowy kod',
    'duel.waiting': 'Czekam na znajomego…',
    'duel.copy': 'KOPIUJ KOD',
    'duel.copied': 'Kod skopiowany do schowka',
    'duel.share': 'UDOSTĘPNIJ',
    'duel.shareText': 'Zagraj ze mną w Arco! Kod pokoju: {code}',
    'duel.shared': 'Zaproszenie skopiowane do schowka',
    'duel.connecting': 'Łączenie…',
    'duel.connected': 'Połączono',
    'duel.disconnected': 'Rozłączono',
    'duel.ping': 'Ping',
    'duel.opponentJoined': '{name} dołącza do gry!',
    'duel.ballsRoom': 'W tym pokoju gracie: {balls}',
    'duel.ballsHost':
        'Ty wybierasz; przeciwnik dowie się przed pierwszym '
        'serwisem.',
    'duel.starting': 'Start…',
    'duel.getReady': 'PRZYGOTUJ SIĘ',
    'duel.go': 'START!',
    'duel.you': 'Ty',
    'duel.opponent': 'Przeciwnik',
    'duel.win': 'WYGRYWASZ',
    'duel.lose': 'PRZEGRYWASZ',
    'duel.rematch': 'REWANŻ',
    'duel.leave': 'WYJDŹ',
    'duel.waitingRematch': 'Czekam na przeciwnika…',
    'duel.peerLeft': 'Przeciwnik opuścił grę',
    'duel.connectionLost': 'Utracono połączenie',
    'error.bad_code': 'Nieprawidłowy kod pokoju',
    'error.room_not_found': 'Nie znaleziono pokoju',
    'error.room_full': 'Ten pokój jest pełny',
    'error.not_in_room': 'Nie jesteś w żadnym pokoju',
    'error.bad_message': 'Błąd protokołu',
    'error.rate_limited': 'Zbyt wiele prób — spróbuj za minutę',
    'error.bad_version': 'Zaktualizuj Arco, aby zagrać online',
    'error.bad_name': 'Nieprawidłowy pseudonim',
    'error.connection': 'Nie można połączyć się z serwerem',
    'error.timeout': 'Serwer nie odpowiedział na czas',
    'error.closed': 'Połączenie zostało zamknięte',
    'error.unknown': 'Coś poszło nie tak',
    'error.offensive_name':
        'Tego pseudonimu nie można umieścić w tablicy wyników. Wybierz '
        'inny, a wynik zostanie wysłany.',
    'error.invalid_name': 'Nieprawidłowy pseudonim',
    'error.invalid_replay': 'Serwer nie mógł zweryfikować tej gry',
    'error.replay_mismatch': 'Wynik nie zgadza się z przebiegiem gry',
    'error.unsupported_version': 'Zaktualizuj Arco, aby wysłać wynik',
    'error.too_large': 'Ta gra jest zbyt długa, aby ją wysłać',
    'lb.title': 'TABLICA WYNIKÓW',
    'lb.all': 'Wszech czasów',
    'lb.week': 'Ten tydzień',
    'lb.day': 'Dzisiaj',
    'lb.board': 'Tablica',
    'lb.empty': 'Brak wyników — bądź pierwszy!',
    'lb.offline': 'Nie udało się wczytać tablicy wyników',
    'lb.retry': 'PONÓW',
    'lb.you': 'ty',
    'lb.seconds': '{s} s',
    'lb.country': '{flag} {code}',
    'lb.countryEmpty': 'Brak wyników z {country} — bądź pierwszy!',
    'settings.title': 'USTAWIENIA',
    'settings.theme': 'Motyw',
    'settings.language': 'Język',
    'settings.langSystem': 'Systemowy',
    'settings.langEn': 'Angielski',
    'settings.langPl': 'Polski',
    'settings.sound': 'Dźwięk',
    'settings.haptics': 'Wibracje',
    'settings.menuMotion': 'Ruch w menu',
    'settings.menuMotionDesc': 'Twoja piłka krąży w tle menu głównego',
    'settings.controls': 'Sterowanie',
    'settings.controlJoystick': 'Joystick',
    'settings.controlTilt': 'Przechył telefonu',
    'settings.controlFollow': 'Podążaj za palcem',
    'settings.controlJoystickDesc': 'Pływający drążek pod kciukiem',
    'settings.controlTiltDesc': 'Przechylaj telefon w lewo / prawo',
    'settings.controlFollowDesc': 'Paletka podąża za palcem',
    'settings.tiltSensitivity': 'Czułość przechyłu',
    'settings.calibrate': 'KALIBRUJ',
    'settings.calibrated': 'Skalibrowano — to jest teraz poziom',
    'settings.tiltPreview': 'Podgląd przechyłu',
    'settings.tiltUnavailable':
        'Czujnik przechyłu niedostępny na tym urządzeniu',
    'settings.joystickSide': 'Pozycja joysticka',
    'settings.sideFloat': 'Pływający',
    'settings.sideLeft': 'Lewa strona',
    'settings.sideRight': 'Prawa strona',
    'settings.advanced': 'Zaawansowane',
    'settings.serverUrl': 'Adres serwera',
    'settings.serverHint': 'np. http://192.168.1.20:8080',
    'settings.serverReset': 'Przywróć domyślny',
    'settings.testConnection': 'TESTUJ POŁĄCZENIE',
    'settings.serverOk': 'Serwer działa (v{version}, pokoje: {rooms})',
    'settings.serverFail': 'Serwer niedostępny',
    'settings.serverTesting': 'Testowanie…',
    'theme.neon': 'Neon',
    'theme.classic': 'Klasyczny',
    'theme.modernist': 'Modernizm',
    'theme.glass': 'Szkło',
    // ------------------------------------------------- cosmetic shop (4.8)
    // Waluta to **Iskry**: gra jest pierścieniem światła, w którym każde
    // odbicie sypie iskrami, więc słowo jest na ekranie, zanim stanie się
    // liczbą. Odmiana przez przypadki w [Strings.sparks].
    'currency.name': 'Iskry',
    'currency.one': '{n} iskra',
    'currency.few': '{n} iskry',
    'currency.many': '{n} iskier',
    'shop.title': 'SKLEP',
    'shop.tagline': 'Motywy, piłki i paletki',
    'shop.open': 'SKLEP',
    'shop.section.theme': 'Motywy',
    'shop.section.ball': 'Piłki',
    'shop.section.paddle': 'Paletki',
    'shop.equipped': 'UŻYWANE',
    'shop.owned': 'POSIADANE',
    'shop.wear': 'ZAŁÓŻ',
    'shop.locked': 'W sklepie',
    'shop.buy': 'KUP',
    // "Kupić Kometę?" would need the accusative, and an item name substituted
    // into a sentence cannot carry a case. Naming the item after a colon is both
    // natural Polish and grammatical whatever the noun is.
    'shop.buyTitle': 'Kupujesz: {item}',
    'shop.buyBody':
        'Kosztuje {price}. W portfelu masz teraz {balance}.\n\nTo tylko wygląd: '
        'żadna rzecz w tym sklepie nie zmienia rozgrywki.',
    'shop.buying': 'Kupowanie…',
    'shop.bought': 'Kupione: {item} — zostaje {balance}.',
    'shop.insufficient': 'Jeszcze za mało — brakuje {missing}.',
    'shop.buyOffline':
        'Brak połączenia, więc nic nie zostało kupione ani pobrane. Spróbuj '
        'ponownie, gdy wrócisz online.',
    'shop.buyFailed':
        'Nie udało się i nic nie zostało pobrane. Możesz bezpiecznie spróbować '
        'ponownie.',
    'shop.offline':
        'Sklep potrzebuje połączenia. Wszystko, co już masz, działa dalej.',
    'shop.unavailable':
        'Sklep teraz nie odpowiada. Nic nie zostało pobrane — spróbuj za '
        'minutę.',
    'shop.earnTitle': 'Zdobyte dziś',
    'shop.earnedToday': '{earned} z {cap}',
    'shop.capReached':
        'Zdobyłeś już dzisiejsze {cap}. Limit odnawia się o północy UTC — graj '
        'dalej, tylko przestaje płacić.',
    'shop.earnHint': 'Iskry zdobywasz grą: każda gra solo do tego dolicza.',
    'shop.accountHint':
        'Zalogowanie zachowa Twoje zakupy, jeśli zgubisz ten telefon.',
    'shop.equipPending':
        'Zapisano na tym telefonie — trafi na konto, gdy wrócisz online.',
    'shop.updateApp':
        'Są nowsze rzeczy, niż ta wersja aplikacji potrafi narysować.',
    'shop.balanceUnknown': 'Zagraj, aby zacząć zdobywać',
    // Jednorazowe odblokowanie (SPEC §4.9): jeden zakup, bez ceny w tej tabeli —
    // cenę podaje sklep urządzenia i wyświetlamy ją dosłownie.
    'unlock.full': 'Odblokuj wszystko',
    'shop.unlockTitle': 'Jednorazowy zakup',
    'shop.unlockPerk.now': 'Wszystkie motywy, piłki i paletki ze sklepu.',
    'shop.unlockPerk.later': 'I każde dodane później, bez dopłat.',
    'shop.unlockPerk.ads': 'Żadnych reklam, nigdy.',
    'shop.unlockButton': 'ODBLOKUJ',
    'shop.unlockFree':
        'Płacisz raz i na tym koniec. Wszystko tutaj zdobywasz też grą — to '
        'skraca czekanie i nic więcej.',
    'shop.unlockStoreSilent':
        'Sklep teraz nie odpowiada, więc nie ma ceny do pokazania. Grając nadal '
        'zdobywasz iskry.',
    'shop.unlockDone': 'Wszystko odblokowane. Baw się dobrze.',
    'shop.unlockWaiting':
        'Zapłacone. Odblokuje się za moment — nawet jeśli zamkniesz grę.',
    'shop.unlockPending':
        'Płatność czeka na zatwierdzenie. Wszystko odblokuje się, gdy przejdzie '
        '— nawet przy zamkniętej grze.',
    'shop.unlockNotAllowed': 'To urządzenie nie pozwala na zakupy.',
    'shop.unlockStoreDown':
        'Sklep nie odpowiedział. Nic nie zostało pobrane — spróbuj później.',
    'shop.unlockOffline': 'Brak połączenia. Nic nie zostało pobrane.',
    'shop.unlockFailed':
        'Zakup nie doszedł do skutku. Nic nie zostało pobrane.',
    'shop.premiumBadge': 'Odblokowane',
    'shop.unlockedTitle': 'Twój zakup',
    'shop.unlockedHeading': 'Wszystko odblokowane',
    'shop.unlockedBody':
        'Każdy motyw, każda piłka i każda paletka są Twoje — również te dodane '
        'później — i nie ma żadnych reklam. To wszystko. Dziękujemy.',
    'shop.restore': 'PRZYWRÓĆ ZAKUPY',
    'shop.restoreHint':
        'Kupiłeś już odblokowanie — na tym telefonie albo na innym? To pyta o '
        'nie sklep i przywraca zakup. Można spokojnie dotknąć kilka razy.',
    'shop.restoreDone': 'Przywrócone — wszystko jest znowu odblokowane.',
    'shop.restoreNothing':
        'Nie znaleziono zakupu na tym koncie sklepu. Jeśli płaciłeś z innego '
        'konta Apple lub Google, zaloguj się na nie i spróbuj ponownie.',
    'shop.restoreFailed': 'Nie udało się połączyć ze sklepem. Spróbuj później.',
    // Reklamy za iskry (SPEC §4.10). Liczebnik odmienia [Strings.sparks].
    'ads.title': 'Z reklam dziś',
    'ads.hint':
        'Krótka reklama daje {sparks}. Całkowicie opcjonalnie — grą zdobędziesz '
        'więcej, a nic w grze nie jest zamknięte za reklamą.',
    'ads.watch': 'OBEJRZYJ REKLAMĘ',
    'ads.today': '{earned} z {cap}',
    'ads.cooldown': 'Następna za około {minutes} min.',
    'ads.dayFull':
        'To już wszystkie dzisiejsze reklamy. Limit odnawia się o północy UTC — '
        'a grą zdobywasz iskry dalej.',
    'ads.consentHint':
        'Reklamy wymagają najpierw Twojej decyzji o danych. Możesz odmówić — gra '
        'będzie dokładnie taka sama, tylko przycisk reklamy zniknie.',
    'ads.consentButton': 'ZDECYDUJ O REKLAMACH',
    'ads.credited': 'Dzięki — dodano {sparks}. Masz teraz {balance}.',
    'ads.waiting':
        'Dzięki. Iskry są właśnie doliczane — będą za moment, nawet jeśli '
        'zamkniesz grę.',
    'ads.noAd': 'Teraz nie ma reklamy. Nic nie tracisz — grą zdobywasz dalej.',
    'ball.orb': 'Kula',
    'ball.comet': 'Kometa',
    'ball.prism': 'Pryzmat',
    'ball.ember': 'Żar',
    'paddle.arc': 'Łuk',
    'paddle.blade': 'Ostrze',
    'paddle.halo': 'Aureola',
    'paddle.chevron': 'Szewron',
    'settings.shop': 'WIĘCEJ MOTYWÓW W SKLEPIE',
    'onboarding.moreLooks': 'Kolejne motywy odblokujesz w sklepie, grając.',
    // ---------------------------------------------------------- account (4.5)
    'account.title': 'Konto',
    'account.offerTitle': 'Zachowaj ten wynik',
    'account.offerBody':
        'Zaloguj się, a Twoje wyniki przetrwają utratę telefonu — i będą z Tobą '
        'na każdym urządzeniu.',
    'account.offerBodyBoard':
        'Zaloguj się, a Twoje miejsce w tej tablicy przetrwa utratę telefonu — '
        'i będzie z Tobą na każdym urządzeniu.',
    'account.notNow': 'NIE TERAZ',
    // Oficjalne brzmienie Apple i Google w języku polskim.
    'account.signInApple': 'Zaloguj się przez Apple',
    'account.signInGoogle': 'Zaloguj się przez Google',
    'account.working': 'Logowanie…',
    'account.provider.apple': 'Apple',
    'account.provider.google': 'Google',
    'account.linkedWith': 'Zalogowano przez {provider}',
    'account.linkedSince': 'Od {date}',
    'account.signedOutHint':
        'Nie zalogowano. Wyniki są przechowywane tylko na tym telefonie.',
    'account.signOut': 'WYLOGUJ NA TYM URZĄDZENIU',
    'account.signOutDone':
        'Wylogowano. Wyniki zostają w tablicy — zaloguj się ponownie, aby '
        'wróciły na ten telefon.',
    'account.outcome.created': 'Konto utworzone — wyniki są bezpieczne.',
    'account.outcome.linked': 'Gotowe — wyniki są teraz na Twoim koncie.',
    'account.outcome.restored':
        'Witaj ponownie — wyniki są znów na tym urządzeniu.',
    'account.outcome.merged':
        'Konta połączone — przeniesiono {count} Twoich gier.',
    'account.outcome.retried': 'Już zalogowano na tym urządzeniu.',
    'account.delete': 'USUŃ MOJE KONTO',
    'account.deleteTitle': 'Usunąć konto?',
    'account.deleteBody':
        'Usuwamy Twoje konto, logowanie na tym telefonie i każde powiązanie '
        'między Tobą a rozegranymi grami.\n\nSame wyniki zostają w tablicy, ale '
        'bez powiązania z Tobą: ich usunięcie zmieniłoby miejsca wszystkich '
        'innych. Rekord na tym telefonie też zostaje i możesz grać dalej.',
    'account.deleteContinue': 'DALEJ',
    'account.deleteConfirmTitle': 'Tego nie można cofnąć',
    'account.deleteConfirmBody':
        'Konta nie da się odzyskać i nie będzie już sposobu, aby wykazać, że te '
        'gry były Twoje.',
    'account.deleteConfirm': 'USUŃ NA ZAWSZE',
    'account.deleteCancel': 'ZACHOWAJ KONTO',
    'account.deleted': 'Konto usunięte',
    'account.deletedRuns':
        'Konto usunięte — {count} gier zostaje bez właściciela',
    'account.error.offline':
        'Brak połączenia — zaloguj się ponownie, gdy wrócisz online.',
    'account.error.accounts_disabled':
        'Logowanie jest wyłączone na tym serwerze.',
    'account.error.invalid_token':
        'Nie udało się zweryfikować tego logowania. Spróbuj ponownie.',
    'account.error.invalid_credentials':
        'To urządzenie zostało wylogowane. Spróbuj ponownie.',
    'account.error.invalid_provider':
        'Ten serwer nie obsługuje tego sposobu logowania.',
    'account.error.already_linked':
        'Ten gracz jest już zalogowany przez {provider}. Najpierw wyloguj się '
        'na tym urządzeniu.',
    'account.error.keys_unavailable':
        'Usługa logowania jest teraz nieosiągalna — spróbuj za minutę.',
    'account.error.rate_limited': 'Zbyt wiele prób — spróbuj za minutę.',
    'account.error.unavailable':
        'To logowanie nie jest dostępne na tym urządzeniu.',
    'account.error.no_token':
        'To logowanie nie zwróciło nic do weryfikacji. Spróbuj ponownie.',
    'account.error.unknown':
        'Logowanie nie zostało ukończone. Spróbuj ponownie.',
  };
}
