import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/game_theme.dart';
import '../../app/legal.dart';
import '../../app/strings.dart';
import '../../services/ads_service.dart';
import '../../services/shop_service.dart';
import 'neon_panel.dart';

/// Opens one of the public pages in the system's in-app browser, saying so in a
/// snackbar when it cannot rather than doing nothing.
Future<void> openLegalLink(BuildContext context, Uri uri) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failed = Strings.read(context).t('privacy.openFailed');
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  } on Object {
    opened = false;
  }
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text(failed)));
}

/// The Privacy block in Settings: the policy, the support page, and — where
/// Google requires it (the EEA, the UK, Switzerland) — the way back to the ad
/// consent form, so a choice can be withdrawn as easily as it was given.
class PrivacySection extends StatefulWidget {
  const PrivacySection({super.key});

  @override
  State<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<PrivacySection> {
  bool _adChoices = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final ads = context.read<AdsService>();
      // A player with the unlock sees no ads, so there is no choice to revisit —
      // by the shop's word or the ad server's.
      final premium = ads.premium || context.read<ShopService>().premium;
      final required = !premium && await ads.gateway.privacyOptionsRequired();
      if (mounted) setState(() => _adChoices = required);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(s.t('privacy.title')),
        NeonPanel(
          padding: EdgeInsets.zero,
          glow: false,
          child: Column(
            children: [
              _row(
                theme,
                icon: Icons.privacy_tip_outlined,
                label: s.t('privacy.policy'),
                onTap: () => openLegalLink(context, LegalLinks.privacy),
              ),
              if (_adChoices)
                _row(
                  theme,
                  icon: Icons.tune,
                  label: s.t('privacy.adChoices'),
                  onTap: () =>
                      context.read<AdsService>().gateway.showPrivacyOptions(),
                ),
              _row(
                theme,
                icon: Icons.help_outline,
                label: s.t('privacy.support'),
                onTap: () => openLegalLink(context, LegalLinks.support),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _row(
    GameTheme theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => ListTile(
    leading: Icon(icon, color: theme.textDim),
    title: Text(label, style: TextStyle(color: theme.textPrimary)),
    trailing: Icon(Icons.chevron_right, color: theme.textDim),
    onTap: onTap,
  );
}
