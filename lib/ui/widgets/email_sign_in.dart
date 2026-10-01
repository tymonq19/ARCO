/// Signing in with an e-mail address (SPEC §4.5): the form behind the e-mail
/// button, and the one helper every sign-in surface calls so that button
/// behaves like the other two.
///
/// Apple and Google bring their own sheet; e-mail needs ours. It is a bottom
/// sheet rather than a page so it reads as one step of the sign-in the player
/// started, and it stays open on a mistake — a wrong password is retyped in
/// place, not re-entered from the top.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/game_theme.dart';
import '../../app/legal.dart';
import '../../app/strings.dart';
import '../../services/account_service.dart';
import '../../services/native_sign_in.dart';
import 'neon_button.dart';
import 'neon_panel.dart';
import 'privacy_section.dart';

/// Signs in with [provider] the way its button promises: Apple's and Google's
/// own sheets straight away, the e-mail form for e-mail. Backing out of the
/// form is a [SignInCancelled], exactly like closing Apple's sheet.
Future<SignInResult> runSignIn(
  BuildContext context,
  SignInProvider provider,
) async {
  final service = context.read<AccountService>();
  if (provider != SignInProvider.email) return service.signIn(provider);
  return await showEmailSignIn(context) ?? const SignInCancelled();
}

/// The e-mail form. Returns the outcome when the player signed in, null when
/// they closed it.
Future<SignInSucceeded?> showEmailSignIn(BuildContext context) =>
    showModalBottomSheet<SignInSucceeded>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _EmailSheet(),
    );

/// Asks an e-mail account for its password again — what Firebase wants before
/// it deletes the account of somebody who signed in a while ago. Null when the
/// player backed out.
Future<String?> askForPassword(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _PasswordDialog(),
);

/// Firebase's own floor; anything shorter is refused there with `weak-password`.
const int _minPasswordLength = 6;

bool _plausibleEmail(String value) {
  final at = value.indexOf('@');
  return at > 0 && value.indexOf('.', at) > at + 1 && !value.endsWith('.');
}

class _EmailSheet extends StatefulWidget {
  const _EmailSheet();

  @override
  State<_EmailSheet> createState() => _EmailSheetState();
}

class _EmailSheetState extends State<_EmailSheet> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// A new account rather than signing in to one.
  bool _create = false;
  bool _busy = false;
  bool _obscure = true;

  /// The last thing worth saying under the form: a refusal, or that the reset
  /// e-mail went.
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _ready =>
      _plausibleEmail(_email.text.trim()) &&
      _password.text.length >= (_create ? _minPasswordLength : 1);

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    final s = Strings.read(context);
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await context.read<AccountService>().signIn(
      SignInProvider.email,
      email: EmailSignIn(
        email: _email.text.trim(),
        password: _password.text,
        create: _create,
      ),
    );
    if (!mounted) return;
    switch (result) {
      case SignInSucceeded():
        Navigator.of(context).pop(result);
      case SignInCancelled():
        setState(() => _busy = false);
      case SignInFailed(:final code, :final detail):
        setState(() {
          _busy = false;
          _error = s.accountError(code, provider: detail);
        });
    }
  }

  Future<void> _reset() async {
    final s = Strings.read(context);
    final email = _email.text.trim();
    if (!_plausibleEmail(email)) {
      setState(() {
        _notice = null;
        _error = s.t('account.error.email_invalid');
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final code = await context.read<AccountService>().sendPasswordReset(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (code == null) {
        _notice = s.f('account.email.resetSent', {'email': email});
      } else {
        _error = s.accountError(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Padding(
      // Lifts the sheet above the keyboard instead of letting it cover the
      // field being typed in.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: NeonPanel(
            color: theme.accent,
            padding: theme.pad(const EdgeInsets.all(20)),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    theme.heading(
                      s.t(
                        _create
                            ? 'account.email.createTitle'
                            : 'account.email.title',
                      ),
                    ),
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: theme.headingCase == HeadingCase.upper
                          ? 1.5
                          : 0.2,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const ValueKey('email.address'),
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: s.t('account.email.address'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('email.password'),
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: [
                      _create
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: s.t('account.email.password'),
                      helperText: _create
                          ? s.f('account.email.passwordHint', {
                              'count': _minPasswordLength,
                            })
                          : null,
                      suffixIcon: IconButton(
                        tooltip: s.t(
                          _obscure
                              ? 'account.email.showPassword'
                              : 'account.email.hidePassword',
                        ),
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: theme.danger,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  if (_notice case final notice?)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        notice,
                        style: TextStyle(
                          color: theme.success,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  NeonButton(
                    label: s.t(
                      _create ? 'account.email.create' : 'account.email.signIn',
                    ),
                    height: 50,
                    fontSize: 13,
                    onPressed: _ready && !_busy ? _submit : null,
                  ),
                  if (_busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Center(
                        child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.accent,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _create = !_create;
                            _error = null;
                            _notice = null;
                          }),
                    child: Text(
                      s.t(
                        _create
                            ? 'account.email.haveAccount'
                            : 'account.email.noAccount',
                      ),
                      style: TextStyle(color: theme.accent, fontSize: 13),
                    ),
                  ),
                  if (_create)
                    TextButton(
                      onPressed: () =>
                          openLegalLink(context, LegalLinks.privacy),
                      child: Text(
                        s.t('account.email.privacy'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.textDim, fontSize: 12),
                      ),
                    ),
                  if (!_create)
                    TextButton(
                      onPressed: _busy ? null : _reset,
                      child: Text(
                        s.t('account.email.forgot'),
                        style: TextStyle(color: theme.textDim, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_password.text.isEmpty) return;
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: SingleChildScrollView(
        child: NeonPanel(
          color: theme.danger,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.t('account.email.reauthBody'),
                style: TextStyle(
                  color: theme.textDim,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('email.reauthPassword'),
                controller: _password,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _confirm(),
                decoration: InputDecoration(
                  labelText: s.t('account.email.password'),
                ),
              ),
              const SizedBox(height: 16),
              NeonButton(
                label: s.t('account.deleteConfirm'),
                height: 50,
                fontSize: 13,
                color: theme.danger,
                onPressed: _password.text.isEmpty ? null : _confirm,
              ),
              const SizedBox(height: 10),
              NeonButton(
                label: s.t('account.deleteCancel'),
                height: 46,
                fontSize: 12,
                filled: false,
                color: theme.textDim,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
