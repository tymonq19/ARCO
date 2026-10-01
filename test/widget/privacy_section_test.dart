import 'package:arco/ui/widgets/privacy_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_env.dart';

/// The Privacy block in Settings: the policy and support are always there; the
/// way back to the ad consent form only where Google requires one.
void main() {
  Future<void> pump(WidgetTester tester, TestEnv env) async {
    await tester.pumpWidget(
      wrapApp(
        env,
        const Scaffold(body: SingleChildScrollView(child: PrivacySection())),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the policy and support are always offered', (tester) async {
    final env = await createTestEnv();
    await pump(tester, env);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Help and contact'), findsOneWidget);
    expect(find.text('Ad privacy settings'), findsNothing);
  });

  testWidgets('where consent is required, the choice can be revisited', (
    tester,
  ) async {
    final ads = FakeAdsGateway()..privacyOptions = true;
    final env = await createTestEnv(adsGateway: ads);
    await pump(tester, env);

    await tester.tap(find.text('Ad privacy settings'));
    await tester.pump();
    expect(ads.privacyOptionsShown, 1);
  });

  testWidgets('a player with the unlock has no ad choice to revisit', (
    tester,
  ) async {
    final ads = FakeAdsGateway()..privacyOptions = true;
    final env = await createTestEnv(adsGateway: ads, premium: true);
    await pump(tester, env);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Ad privacy settings'), findsNothing);
  });
}
