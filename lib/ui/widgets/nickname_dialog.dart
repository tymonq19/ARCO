import 'package:arco_core/arco_core.dart';
import 'package:flutter/material.dart';

import '../../app/game_theme.dart';
import '../../app/strings.dart';
import 'neon_button.dart';
import 'neon_panel.dart';

/// Asks for a nickname and returns it **normalized** (SPEC §4.2), or null when
/// the player backs out.
///
/// This is the way out of the one refusal a player can do something about: the
/// filter of SPEC §4.7 turned a name down, the run itself was verified and is
/// still stored, so all that is missing is another name. [message] is shown
/// above the field and is where that gets explained.
Future<String?> showNicknameDialog(
  BuildContext context, {
  required String initial,
  String? message,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NicknameDialog(initial: initial, message: message),
  );
}

class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial, this.message});

  final String initial;
  final String? message;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The name as the server would store it, or null while it is invalid.
  String? get _valid => normalizeName(_name.text);

  void _save() {
    final name = _valid;
    if (name == null) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final valid = _valid != null;
    return Dialog(
      // The panel carries the theme's own fill, edge, corner shape and glow, so
      // the dialog belongs to the look it is shown in rather than to Material's
      // default surface - which on the light Modernist theme is a different
      // white than its paper.
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SingleChildScrollView(
        child: NeonPanel(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                theme.heading(s.t('name.title')),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              if (widget.message != null) ...[
                const SizedBox(height: 12),
                Text(
                  widget.message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.textDim, fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
                textAlign: TextAlign.center,
                maxLength: nameMaxLength,
                textInputAction: TextInputAction.done,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
                decoration: InputDecoration(
                  labelText: s.t('home.nickname'),
                  helperText: s.t('home.nicknameHint'),
                  helperMaxLines: 2,
                  errorText: valid ? null : s.t('home.nicknameHint'),
                  errorMaxLines: 2,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              NeonButton(
                label: s.t('name.save'),
                height: 50,
                fontSize: 14,
                onPressed: valid ? _save : null,
              ),
              const SizedBox(height: 10),
              NeonButton(
                label: s.t('common.cancel'),
                height: 46,
                fontSize: 13,
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
