import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/server_config.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../game/input/tilt_input.dart';
import '../services/api_client.dart';
import '../services/audio_service.dart';
import '../services/haptics.dart';
import '../services/shop_service.dart';
import 'shop_screen.dart';
import 'widgets/account_section.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/shop_card.dart';
import 'widgets/theme_preview.dart';

/// Look, language, sound, haptics, control scheme and the advanced server URL.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static const String route = '/settings';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Gap between theme previews.
  static const double _previewGap = 10;

  /// Preview card width in the picker. Four of these are wider than a phone, so
  /// the row scrolls sideways; on a wide viewport they are centred instead.
  static const double _previewWidth = 124;

  late final TextEditingController _serverUrl;

  /// Horizontal scroll of the theme picker, opened on the current look.
  late final ScrollController _themeScroll;
  String? _serverStatus;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<Settings>();
    _serverUrl = TextEditingController(text: settings.serverUrl);
    // Four cards are wider than a phone, so on a narrow screen the picker
    // opens on Neon and Glass sits entirely off the right edge: a player who
    // runs Glass would open Settings and see nothing selected. Start scrolled
    // to the current look instead. An offset past the end is clamped to the
    // maximum when the viewport reports its extent, and a viewport wide enough
    // to hold all four never scrolls at all.
    _themeScroll = ScrollController(
      initialScrollOffset:
          GameThemes.all
              .indexWhere((t) => t.id == settings.themeId)
              .clamp(0, GameThemes.themeCount - 1) *
          (_previewWidth + _previewGap),
    );
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _themeScroll.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final s = Strings.read(context);
    final api = context.read<ApiClient>();
    setState(() {
      _testing = true;
      _serverStatus = s.t('settings.serverTesting');
    });
    try {
      final health = await api.health();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _serverStatus = s.f('settings.serverOk', {
          'version': health.version,
          'rooms': health.rooms,
        });
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _serverStatus = s.t('settings.serverFail');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final settings = context.watch<Settings>();
    final haptics = context.read<Haptics>();
    final audio = context.read<AudioService>();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('settings.title'))),
      body: NeonBackground(
        child: SafeArea(
          child: ListView(
            // Generous bottom padding so the last control is never stuck
            // against the home indicator on a tall phone.
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 64),
            // The whole list is short enough to keep laid out at once, which
            // matters now that the theme previews sit above everything else:
            // the controls below them stay built while the player scrolls.
            cacheExtent: 900,
            children: [
              _section(theme, s.t('settings.theme')),
              _themePicker(s, settings),
              const SizedBox(height: 10),
              // The looks that cost sparks live in the shop (SPEC 4.8), and the
              // picker above says which ones those are — so this is the way from
              // "I want that one" to the place it can be had.
              NeonButton(
                label: s.t('settings.shop'),
                icon: Icons.auto_awesome,
                color: theme.star,
                filled: false,
                height: 48,
                fontSize: 13,
                onPressed: () =>
                    Navigator.of(context).pushNamed(ShopScreen.route),
              ),
              const SizedBox(height: 18),
              _section(theme, s.t('settings.language')),
              NeonPanel(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    _choice(
                      theme: theme,
                      label: s.t('settings.langSystem'),
                      selected: settings.language == AppLanguage.system,
                      onTap: () => settings.language = AppLanguage.system,
                    ),
                    _choice(
                      theme: theme,
                      label: s.t('settings.langEn'),
                      selected: settings.language == AppLanguage.en,
                      onTap: () => settings.language = AppLanguage.en,
                    ),
                    _choice(
                      theme: theme,
                      label: s.t('settings.langPl'),
                      selected: settings.language == AppLanguage.pl,
                      onTap: () => settings.language = AppLanguage.pl,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              NeonPanel(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  children: [
                    SwitchListTile(
                      value: settings.sound,
                      title: Text(s.t('settings.sound')),
                      secondary: const Icon(Icons.volume_up),
                      onChanged: (v) {
                        settings.sound = v;
                        audio.muted = !v;
                        if (v) audio.play(Sfx.click);
                      },
                    ),
                    SwitchListTile(
                      value: settings.haptics,
                      title: Text(s.t('settings.haptics')),
                      secondary: const Icon(Icons.vibration),
                      onChanged: (v) {
                        settings.haptics = v;
                        if (v) haptics.selection();
                      },
                    ),
                    // The drifting ball behind the title screen. Off means off:
                    // no ticker and no accelerometer (see `MenuBallBackdrop`),
                    // which is why this is a setting and not a style.
                    SwitchListTile(
                      value: settings.menuMotion,
                      title: Text(s.t('settings.menuMotion')),
                      subtitle: Text(s.t('settings.menuMotionDesc')),
                      secondary: const Icon(Icons.motion_photos_on),
                      onChanged: (v) => settings.menuMotion = v,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _section(theme, s.t('settings.controls')),
              NeonPanel(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    _controlTile(
                      theme,
                      settings,
                      ControlMode.joystick,
                      Icons.gamepad,
                      s.t('settings.controlJoystick'),
                      s.t('settings.controlJoystickDesc'),
                    ),
                    _controlTile(
                      theme,
                      settings,
                      ControlMode.tilt,
                      Icons.screen_rotation,
                      s.t('settings.controlTilt'),
                      s.t('settings.controlTiltDesc'),
                    ),
                    _controlTile(
                      theme,
                      settings,
                      ControlMode.follow,
                      Icons.touch_app,
                      s.t('settings.controlFollow'),
                      s.t('settings.controlFollowDesc'),
                    ),
                  ],
                ),
              ),
              if (settings.controlMode == ControlMode.joystick) ...[
                const SizedBox(height: 18),
                _section(theme, s.t('settings.joystickSide')),
                NeonPanel(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      _choice(
                        theme: theme,
                        label: s.t('settings.sideFloat'),
                        selected: settings.joystickSide == JoystickSide.float,
                        onTap: () => settings.joystickSide = JoystickSide.float,
                      ),
                      _choice(
                        theme: theme,
                        label: s.t('settings.sideLeft'),
                        selected: settings.joystickSide == JoystickSide.left,
                        onTap: () => settings.joystickSide = JoystickSide.left,
                      ),
                      _choice(
                        theme: theme,
                        label: s.t('settings.sideRight'),
                        selected: settings.joystickSide == JoystickSide.right,
                        onTap: () => settings.joystickSide = JoystickSide.right,
                      ),
                    ],
                  ),
                ),
              ],
              if (settings.controlMode == ControlMode.tilt) ...[
                const SizedBox(height: 18),
                _section(theme, s.t('settings.tiltSensitivity')),
                NeonPanel(child: TiltCalibrationPanel(settings: settings)),
              ],
              const SizedBox(height: 18),
              // The account block (SPEC 4.5). It renders nothing at all when
              // the deployment accepts no sign-in and this device has no player
              // identity to delete, so a build with accounts off looks exactly
              // as it did before.
              const AccountSection(),
              NeonPanel(
                padding: EdgeInsets.zero,
                glow: false,
                child: Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    title: Text(s.t('settings.advanced')),
                    leading: const Icon(Icons.dns),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      TextField(
                        controller: _serverUrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: (v) => settings.serverUrl = v,
                        decoration: InputDecoration(
                          labelText: s.t('settings.serverUrl'),
                          hintText: s.t('settings.serverHint'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        settings.effectiveBaseUrl,
                        style: TextStyle(color: theme.textDim, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: NeonButton(
                              label: s.t('settings.testConnection'),
                              height: 48,
                              fontSize: 13,
                              onPressed: _testing ? null : _testConnection,
                            ),
                          ),
                          const SizedBox(width: 10),
                          NeonIconButton(
                            icon: Icons.restart_alt,
                            tooltip: s.t('settings.serverReset'),
                            color: theme.textDim,
                            onPressed: () {
                              _serverUrl.text = '';
                              settings.serverUrl = '';
                              setState(() => _serverStatus = null);
                            },
                          ),
                        ],
                      ),
                      if (_serverStatus != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _serverStatus!,
                          style: TextStyle(color: theme.textDim, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        ServerConfig.defaultBaseUrl,
                        style: TextStyle(color: theme.textDim, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The four looks side by side as live previews of the real arena. Tapping one
  /// the player owns applies it instantly, persists it and tells the server
  /// (SPEC 4.8), so the look follows the account to another device; tapping one
  /// they do not own goes to the shop, where it has a price.
  Widget _themePicker(Strings s, Settings settings) {
    const height =
        _previewWidth * ThemePreview.defaultHeight / ThemePreview.defaultWidth;
    final shop = context.watch<ShopService>();
    return NeonPanel(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final row = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in GameThemes.all) ...[
                if (option != GameThemes.all.first)
                  const SizedBox(width: _previewGap),
                _themeCard(s, settings, shop, option, height),
              ],
            ],
          );
          const total =
              GameThemes.themeCount * _previewWidth +
              (GameThemes.themeCount - 1) * _previewGap;
          if (total <= constraints.maxWidth) return Center(child: row);
          // Narrower than the four cards: scroll them sideways rather than
          // shrinking the illustrations into unreadable thumbnails.
          return SizedBox(
            height: height,
            child: SingleChildScrollView(
              controller: _themeScroll,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: row,
            ),
          );
        },
      ),
    );
  }

  /// One look in the picker, locked when it has not been bought.
  ///
  /// Ownership is the server's answer (`ShopService`), never this screen's: what
  /// is shown here is the last thing the server said, plus the looks that cost
  /// nothing — and a look that turns out not to be owned is refused by the server
  /// when the choice is pushed, which costs one request and no free item.
  Widget _themeCard(
    Strings s,
    Settings settings,
    ShopService shop,
    GameTheme option,
    double height,
  ) {
    final itemId = ShopSnapshot.idOfTheme(option);
    final owned = shop.snapshot.owns(itemId);
    final card = ThemePreview(
      theme: option,
      width: _previewWidth,
      height: height,
      label: s.t(option.nameKey),
      selected: option.id == settings.themeId,
      onTap: owned
          ? () => _wearTheme(settings, shop, option)
          : () => Navigator.of(context).pushNamed(ShopScreen.route),
    );
    if (owned) return card;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        const Positioned(top: 6, left: 6, child: LockBadge()),
      ],
    );
  }

  /// Applies a look now and stores it on the server.
  ///
  /// Both, in that order: the picker must answer the tap on the same frame, and
  /// the slot has to reach the account so another device wears it too. A choice
  /// the server cannot be told about right now is kept and pushed later.
  void _wearTheme(Settings settings, ShopService shop, GameTheme option) {
    settings.theme = option;
    shop.equip(ShopSnapshot.idOfTheme(option));
  }

  /// Kept as a one-liner over [SectionLabel] so the account block of SPEC 4.5,
  /// which owns its own heading, is set identically.
  Widget _section(GameTheme theme, String title) => SectionLabel(title);

  Widget _choice({
    required GameTheme theme,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: selected
                ? theme.accent.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(theme.radius(0.55)),
            border: Border.all(color: selected ? theme.accent : theme.outline),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? theme.textPrimary : theme.textDim,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlTile(
    GameTheme theme,
    Settings settings,
    ControlMode mode,
    IconData icon,
    String title,
    String description,
  ) {
    final selected = settings.controlMode == mode;
    return ListTile(
      onTap: () => settings.controlMode = mode,
      leading: Icon(icon, color: selected ? theme.accent : theme.textDim),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: selected ? theme.textPrimary : theme.textDim,
        ),
      ),
      subtitle: Text(
        description,
        style: TextStyle(color: theme.textDim, fontSize: 12),
      ),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? theme.accent : theme.outline,
      ),
    );
  }
}

/// Live tilt readout plus the CALIBRATE button. Subscribes to the
/// accelerometer only while it is on screen.
class TiltCalibrationPanel extends StatefulWidget {
  const TiltCalibrationPanel({super.key, required this.settings});

  final Settings settings;

  @override
  State<TiltCalibrationPanel> createState() => _TiltCalibrationPanelState();
}

class _TiltCalibrationPanelState extends State<TiltCalibrationPanel> {
  late final TiltInput _tilt;

  @override
  void initState() {
    super.initState();
    _tilt = TiltInput(settings: widget.settings);
  }

  @override
  void dispose() {
    _tilt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final theme = GameTheme.of(context);
    final settings = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.speed, color: theme.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Slider(
                value: settings.tiltSensitivity,
                min: Settings.minTiltSensitivity,
                max: Settings.maxTiltSensitivity,
                divisions: 8,
                label: settings.tiltSensitivity.toStringAsFixed(1),
                onChanged: (v) => settings.tiltSensitivity = v,
              ),
            ),
            SizedBox(
              width: 38,
              child: Text(
                settings.tiltSensitivity.toStringAsFixed(1),
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          s.t('settings.tiltPreview'),
          style: TextStyle(color: theme.textDim, fontSize: 12),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: _tilt,
          builder: (context, _) {
            if (!_tilt.available) {
              return Text(
                s.t('settings.tiltUnavailable'),
                style: TextStyle(color: theme.danger, fontSize: 12),
              );
            }
            final value = _tilt.hasSample ? _tilt.normalized : 0.0;
            return SizedBox(
              height: 26,
              child: LayoutBuilder(
                builder: (context, c) {
                  final half = c.maxWidth / 2;
                  return Stack(
                    children: [
                      Center(
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: theme.surfaceHigh,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      Positioned(
                        left: half + value * half - 11,
                        top: 1,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: theme.accent,
                            shape: BoxShape.circle,
                            boxShadow: theme.hasGlow
                                ? [
                                    BoxShadow(
                                      color: theme.accent.withValues(
                                        alpha: 0.5 * theme.glow,
                                      ),
                                      blurRadius: 14,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        NeonButton(
          label: s.t('settings.calibrate'),
          height: 48,
          fontSize: 14,
          onPressed: () {
            _tilt.calibrate();
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(s.t('settings.calibrated'))));
          },
        ),
      ],
    );
  }
}
