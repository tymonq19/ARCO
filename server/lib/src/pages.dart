/// The two public web pages the stores ask for: the privacy policy and the
/// support page.
///
/// App Store Connect, Google Play and AdMob's consent message each want a
/// public URL for a privacy policy, and the app links to the same page from
/// Settings. Serving it from this server keeps the address stable and under our
/// control, and rendering it from `PRIVACY.md` — the file in the repository —
/// means there is one text, never a web copy that has drifted from it.
library;

import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:shelf/shelf.dart';

import 'logging.dart';

/// Where support requests go, on the support page and in the policy.
const String supportEmail = 'jta.devs@gmail.com';

class PublicPages {
  PublicPages({String? privacyMarkdown})
    : _privacyHtml = privacyMarkdown == null
          ? null
          : _page(
              title: 'Arco — polityka prywatności / privacy policy',
              lang: 'pl',
              body: md.markdownToHtml(
                privacyMarkdown,
                extensionSet: md.ExtensionSet.gitHubWeb,
              ),
            );

  /// Reads `PRIVACY.md` from [path], or from the places it sits in the image
  /// (`/app/PRIVACY.md`, the working directory) and in a checkout (the
  /// repository root, one level above `server/`). A missing file is logged and
  /// the page answers 404 rather than the server refusing to start: the game
  /// does not depend on it.
  factory PublicPages.load(Logger log, {String? path}) {
    final candidates = [?path, 'PRIVACY.md', '../PRIVACY.md'];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        return PublicPages(privacyMarkdown: file.readAsStringSync());
      }
    }
    log.warn(
      'no PRIVACY.md found (tried ${candidates.join(', ')}); '
      '/privacy will answer 404',
    );
    return PublicPages();
  }

  final String? _privacyHtml;

  /// `GET /privacy`.
  Response privacy(Request request) {
    final html = _privacyHtml;
    if (html == null) return Response.notFound('Not found');
    return _html(html);
  }

  /// `GET /support`.
  Response support(Request request) => _html(_supportHtml);

  static Response _html(String body) => Response.ok(
    body,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'public, max-age=300',
      'x-content-type-options': 'nosniff',
    },
  );

  static final String _supportHtml = _page(
    title: 'Arco — pomoc / support',
    lang: 'pl',
    body:
        '''
<h1>Arco — pomoc</h1>
<p>Masz pytanie, problem z grą, zakupem albo kontem? Napisz do nas:
<a href="mailto:$supportEmail">$supportEmail</a>. Odpowiadamy zwykle w ciągu kilku dni.</p>
<h2>Najczęstsze sprawy</h2>
<ul>
<li><strong>Przywrócenie zakupu</strong> — zaloguj się tym samym kontem, a potem w sklepie gry wybierz
„Przywróć zakupy”.</li>
<li><strong>Usunięcie konta i danych</strong> — w grze: Ustawienia → USUŃ MOJE KONTO. Usuwa konto, wyniki z tablicy,
Iskry i historię zakupów na naszym serwerze.</li>
<li><strong>Zmiana zgody na reklamy</strong> — Ustawienia → Ustawienia prywatności reklam.</li>
<li><strong>Zwrot pieniędzy</strong> — zwroty obsługuje sklep: Apple (reportaproblem.apple.com) lub Google Play.</li>
</ul>
<p><a href="/privacy">Polityka prywatności</a></p>
<hr>
<h1 id="english">Arco — support</h1>
<p>A question, or a problem with the game, a purchase or your account? Write to us:
<a href="mailto:$supportEmail">$supportEmail</a>. We usually reply within a few days.</p>
<ul>
<li><strong>Restore a purchase</strong> — sign in with the same account, then choose “Restore purchases” in the
in-game shop.</li>
<li><strong>Delete your account and data</strong> — in the game: Settings → DELETE MY ACCOUNT. It removes the
account, your leaderboard scores, Sparks and purchase history from our server.</li>
<li><strong>Change your ad consent</strong> — Settings → Ad privacy settings.</li>
<li><strong>Refunds</strong> — handled by the store: Apple (reportaproblem.apple.com) or Google Play.</li>
</ul>
<p><a href="/privacy#privacy-policy-for-arco">Privacy policy</a></p>
<p class="small">JTA DEVS sp. z o.o., Dąbrowa Górnicza, Poland</p>
''',
  );

  /// A plain, readable page in both colour schemes, with nothing loaded from
  /// anywhere else.
  static String _page({
    required String title,
    required String lang,
    required String body,
  }) =>
      '''
<!doctype html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --dim: #6e6e73; --link: #0a66c2; --rule: #d2d2d7; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0e0f13; --fg: #ececf1; --dim: #a1a1aa; --link: #6cb4ff; --rule: #2a2b31; }
}
body { margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 32px 16px 64px; }
h1 { font-size: 1.7em; line-height: 1.25; margin-top: 1.2em; }
h2 { font-size: 1.25em; margin-top: 1.8em; }
h3 { font-size: 1.05em; margin-top: 1.4em; }
a { color: var(--link); }
hr { border: 0; border-top: 1px solid var(--rule); margin: 48px 0; }
em, .small { color: var(--dim); }
li { margin: 4px 0; }
</style>
</head>
<body><main>
$body
</main></body>
</html>
''';
}
