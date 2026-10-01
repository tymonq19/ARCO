/// The two public pages the stores link to: the privacy policy, rendered from
/// the repository's PRIVACY.md, and the support page.
library;

import 'package:arco_server/arco_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('/privacy is PRIVACY.md, in both languages, as a web page', () async {
    final server = await bootServer();
    final r = await http.get(Uri.parse('${server.baseUrl}/privacy'));
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], startsWith('text/html'));
    expect(r.body, contains('<h1'));
    expect(r.body, contains('Polityka prywatności gry Arco'));
    // The English half, with the anchor the Polish half links to.
    expect(r.body, contains('id="privacy-policy-for-arco"'));
    expect(r.body, contains(supportEmail));
  });

  test('/support names where to write', () async {
    final server = await bootServer();
    final r = await http.get(Uri.parse('${server.baseUrl}/support'));
    expect(r.statusCode, 200);
    expect(r.body, contains('mailto:$supportEmail'));
    expect(r.body, contains('href="/privacy"'));
  });

  test('a missing policy is a 404, not a server that will not start', () {
    final pages = PublicPages();
    expect(
      pages.privacy(Request('GET', Uri.parse('http://x/privacy'))).statusCode,
      404,
    );
  });
}
