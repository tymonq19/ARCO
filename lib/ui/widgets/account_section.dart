import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import '../../services/account_service.dart';
import '../../services/api_client.dart';
import '../../services/native_sign_in.dart';
import '../../services/player_identity.dart';
import 'neon_button.dart';
import 'neon_panel.dart';
import 'sign_in_buttons.dart';

/// The Account block in Settings (SPEC §4.5).
///
/// Three states, and the section is absent in the fourth:
/// * **signed in** — which provider, since when, sign out on this device, and
///   delete the account;
/// * **not signed in, sign-in available** — the calm version of the offer, for a
///   player who came looking for it rather than being shown it;
/// * **not signed in, nothing advertised, but a player identity exists** — only
///   the deletion, which SPEC §4.5 keeps working for an anonymous player and
///   which Apple requires of any app that can create an account at all;
/// * nothing to say → nothing rendered.
class AccountSection extends StatefulWidget {
  const AccountSection({super.key});

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  List<SignInProvider>? _providers;
  bool _busy = false;
  SignInResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    // The standing carries `provider` and `linkedAt` (SPEC §4.4), which is how
    // this section knows what to show. Cached, never polled.
    context.read<PlayerIdentity>().refreshProfile();
    final providers = await context.read<AccountService>().providers();
    if (!mounted) return;
    setState(() => _providers = providers);
  }

  Future<void> _signIn(SignInProvider provider) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await context.read<AccountService>().signIn(provider);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is! SignInCancelled) _result = result;
    });
    // See [AccountOfferCard]: only the attempt can prove the sheet cannot run
    // here, so the provider list is re-read and the dead button goes.
    if (result is SignInFailed && result.code == 'unavailable') await _load();
  }

  Future<void> _signOut() async {
    final s = Strings.read(context);
    setState(() => _busy = true);
    await context.read<AccountService>().signOutOnThisDevice();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.t('account.signOutDone'))));
  }

  /// Deletion takes two deliberate steps: one that says what disappears, and one
  /// that says it cannot be undone. Neither of them deletes anything by itself.
  Future<void> _delete() async {
    final s = Strings.read(context);
    if (!await _confirmStep(
      title: s.t('account.deleteTitle'),
      body: s.t('account.deleteBody'),
      confirm: s.t('account.deleteContinue'),
      danger: false,
    )) {
      return;
    }
    if (!mounted) return;
    if (!await _confirmStep(
      title: s.t('account.deleteConfirmTitle'),
      body: s.t('account.deleteConfirmBody'),
      confirm: s.t('account.deleteConfirm'),
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final result = await context.read<AccountService>().deleteAccount();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          DeleteSucceeded(scoresAnonymised: final n) when n > 0 => s.f(
            'account.deletedRuns',
            {'count': n},
          ),
          DeleteSucceeded() => s.t('account.deleted'),
          DeleteFailed(code: final code) => s.accountError(code),
        }),
      ),
    );
  }

  Future<bool> _confirmStep({
    required String title,
    required String body,
    required String confirm,
    required bool danger,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDialog(
        title: title,
        body: body,
        confirm: confirm,
        danger: danger,
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final identity = context.watch<PlayerIdentity>();
    final profile = identity.profile;
    final linked = profile?.hasAccount ?? false;
    final providers = _providers ?? const <SignInProvider>[];
    final canDelete = identity.isIdentified;
    if (!linked && providers.isEmpty && !canDelete) {
      return const SizedBox.shrink();
    }
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(s.t('account.title')),
        NeonPanel(
          padding: theme.pad(const EdgeInsets.all(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (linked)
                ..._linked(s, theme, profile!)
              else ...[
                Text(
                  s.t('account.signedOutHint'),
                  style: TextStyle(
                    color: theme.textDim,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                if (providers.isNotEmpty) const SizedBox(height: 14),
                for (final provider in providers) ...[
                  SignInButton(
                    provider: provider,
                    onPressed: _busy ? null : () => _signIn(provider),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.t('account.working'),
                          style: TextStyle(color: theme.textDim, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else if (result is SignInFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    s.accountError(result.code, provider: result.detail),
                    style: TextStyle(
                      color: theme.danger,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              if (canDelete) ...[
                const SizedBox(height: 14),
                NeonButton(
                  label: s.t('account.delete'),
                  height: 46,
                  fontSize: 12,
                  filled: false,
                  color: theme.danger,
                  onPressed: _busy ? null : _delete,
                ),
              ],
            ],
          ),
        ),
        // The trailing gap belongs to the section rather than to the list around
        // it: when there is nothing to show this whole widget is zero-height,
        // and a list that padded it anyway would leave a hole where it was.
        const SizedBox(height: 18),
      ],
    );
  }

  /// "Signed in with Apple" plus the date, then the way out of it on this phone.
  List<Widget> _linked(Strings s, GameTheme theme, PlayerProfile profile) => [
    Row(
      children: [
        Icon(Icons.verified_user, color: theme.success, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.f('account.linkedWith', {
                  'provider': s.accountProvider(profile.provider),
                }),
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (profile.linkedAt case final at?)
                Text(
                  s.f('account.linkedSince', {'date': _formatDate(at)}),
                  style: TextStyle(color: theme.textDim, fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    ),
    const SizedBox(height: 14),
    NeonButton(
      label: s.t('account.signOut'),
      height: 46,
      fontSize: 12,
      filled: false,
      color: theme.textDim,
      onPressed: _busy ? null : _signOut,
    ),
  ];

  /// `2026-09-21` in the device's own zone. Deliberately not a localized long
  /// date: that needs `intl` data the app does not otherwise carry, and an
  /// ISO date reads the same in both languages.
  static String _formatDate(DateTime at) {
    final local = at.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

/// One step of a destructive confirmation, drawn on the theme's own panel so it
/// belongs to the look it appears in.
class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirm,
    required this.danger,
  });

  final String title;
  final String body;
  final String confirm;

  /// The last step is drawn in the theme's danger colour; the first is not, so
  /// the two steps do not look like the same tap twice.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final accent = danger ? theme.danger : theme.accent;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: SingleChildScrollView(
        child: NeonPanel(
          color: accent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                theme.heading(title),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: TextStyle(
                  color: theme.textDim,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              NeonButton(
                label: confirm,
                height: 50,
                fontSize: 13,
                color: accent,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 10),
              NeonButton(
                label: danger
                    ? s.t('account.deleteCancel')
                    : s.t('common.cancel'),
                height: 46,
                fontSize: 12,
                filled: false,
                color: theme.textDim,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
