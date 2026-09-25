import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/game_theme.dart';
import '../app/settings.dart';
import '../app/strings.dart';
import '../services/api_client.dart';
import '../services/player_identity.dart';
import '../services/score_submitter.dart';
import '../services/storage.dart';
import 'widgets/account_offer_card.dart';
import 'widgets/neon_button.dart';
import 'widgets/neon_panel.dart';
import 'widgets/nickname_dialog.dart';

/// One tab: a period, and the country it is restricted to (SPEC §4.6) — null
/// for the global board. A record, so two boards compare by value and can key
/// the caches below.
typedef _Board = (LeaderboardPeriod period, String? country);

/// Global top 100 for three periods plus the player's own country, with
/// pull-to-refresh and an offline state. Own entries are highlighted by player
/// id, falling back to the submissions this device remembers.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  static const String route = '/leaderboard';

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with TickerProviderStateMixin {
  late PlayerIdentity _identity;
  late List<_Board> _boards;
  late TabController _tabs;

  final Map<_Board, List<LeaderboardEntry>> _entries = {};
  final Map<_Board, bool> _loading = {};
  final Map<_Board, bool> _failed = {};

  @override
  void initState() {
    super.initState();
    _identity = context.read<PlayerIdentity>();
    _identity.addListener(_onIdentityChanged);
    _boards = _boardsFor(_identity.country);
    _tabs = _newController(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reads the stored credential (never issues one) so the rows this player
      // owns can be recognised by id; the listener above repaints when it
      // arrives.
      _identity.load();
      _retryPending();
      _load(_boards[_tabs.index]);
    });
  }

  @override
  void dispose() {
    _identity.removeListener(_onIdentityChanged);
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// The three global periods, plus an all-time board for the player's own
  /// country when one is known (SPEC §4.6). Nothing national is shown to a
  /// player whose device names no country — an empty tab would be worse than
  /// no tab.
  static List<_Board> _boardsFor(String? country) => <_Board>[
    for (final period in LeaderboardPeriod.values) (period, null),
    if (country != null) (LeaderboardPeriod.all, country),
  ];

  TabController _newController(int index) =>
      TabController(length: _boards.length, initialIndex: index, vsync: this)
        ..addListener(_onTabChanged);

  /// The player's country can arrive (or be refused) while this screen is up,
  /// and their id can arrive with the first submission, so both the tab strip
  /// and the highlighting follow [PlayerIdentity].
  void _onIdentityChanged() {
    if (!mounted) return;
    final next = _boardsFor(_identity.country);
    if (listEquals(next, _boards)) {
      setState(() {}); // the owner of a row may have become known
      return;
    }
    final index = math.min(_tabs.index, next.length - 1);
    final previous = _tabs;
    setState(() {
      _boards = next;
      _tabs = _newController(index);
    });
    // Disposed after the frame that swaps it out: a TabBar still holding the
    // old controller must not find it disposed while it detaches.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.removeListener(_onTabChanged);
      previous.dispose();
    });
    _load(next[index]);
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging || !mounted) return;
    // Rebuilt even when the new board is already loaded: whether the account
    // offer belongs on screen is a question about the open tab.
    setState(() {});
    _load(_boards[_tabs.index]);
  }

  Future<void> _load(_Board board, {bool force = false}) async {
    if (!force && (_loading[board] == true || _entries[board] != null)) {
      return;
    }
    setState(() {
      _loading[board] = true;
      _failed[board] = false;
    });
    final (period, country) = board;
    try {
      final entries = await context.read<ApiClient>().leaderboard(
        period,
        country: country,
      );
      if (!mounted) return;
      setState(() {
        _entries[board] = entries;
        _loading[board] = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // SPEC §4.6 refuses a country it cannot read rather than answering with
      // the whole world's board. The device is reporting something that is not
      // an ISO 3166-1 code, so the national tab goes away instead of showing an
      // error the player can do nothing about.
      if (country != null && e.errorCode == 'invalid_country') {
        _identity.countryRefused(country);
        return;
      }
      setState(() {
        _loading[board] = false;
        _failed[board] = true;
      });
    }
  }

  /// A solo score that could not be uploaded is retried whenever the
  /// leaderboard is opened (SPEC §5.1).
  Future<void> _retryPending() async {
    final storage = context.read<Storage>();
    if (storage.pendingReplay == null) return;
    final s = Strings.read(context);
    final submitter = ScoreSubmitter(
      api: context.read<ApiClient>(),
      storage: storage,
      identity: _identity,
    );
    final outcome = await submitter.retryPending();
    if (!mounted) return;
    if (outcome is SubmitRejected && outcome.canRetryUnderNewName) {
      _offerRename(s, submitter, outcome);
      return;
    }
    if (outcome is! SubmitAccepted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.f('solo.pendingSent', {'rank': outcome.rank}))),
    );
    await _load(_boards[_tabs.index], force: true);
  }

  /// The stored game was refused only because of the nickname on it (SPEC §4.7):
  /// the run is still stored, so a different name is all it takes.
  void _offerRename(
    Strings s,
    ScoreSubmitter submitter,
    SubmitRejected rejection,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.submitError(rejection.error)),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: s.t('solo.changeName'),
          onPressed: () => _renameAndRetry(submitter),
        ),
      ),
    );
  }

  Future<void> _renameAndRetry(ScoreSubmitter submitter) async {
    final s = Strings.read(context);
    final settings = context.read<Settings>();
    final name = await showNicknameDialog(
      context,
      initial: settings.playerName,
      message: s.t('error.offensive_name'),
    );
    if (name == null || !mounted) return;
    settings.playerName = name;
    final outcome = await submitter.retryPendingAs(name);
    if (!mounted || outcome is! SubmitAccepted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.f('solo.pendingSent', {'rank': outcome.rank}))),
    );
    await _load(_boards[_tabs.index], force: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('lb.title')),
        bottom: TabBar(
          controller: _tabs,
          // The tabs split the width evenly, and Material's own `Tab(text:)`
          // fades a label that does not fit off mid-word -- which is what
          // Polish's "Wszech czasow" did on a 393 pt phone. A tighter label
          // padding plus [_tab]'s scale-down keeps every label whole at any
          // width, including with the national tab added.
          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
          tabs: [for (final board in _boards) _tab(_label(s, board))],
        ),
      ),
      body: NeonBackground(
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                // The second moment the account offer belongs to (SPEC 4.5):
                // the player is on this board, so "keep your place on it" is
                // about something they are looking at. Only when a row on the
                // open tab is theirs — a player who is not on the board is not
                // being promised anything — and it draws nothing when there is
                // no sign-in to offer or they have already said no.
                //
                // Capped at 60 % of the height and scrollable inside that: at a
                // large text scale on a 320 pt phone the card is tall enough to
                // leave the board no room at all, and the board is what the
                // player came here for.
                if (_hasOwnEntry(_boards[_tabs.index]))
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.6,
                    ),
                    child: const SingleChildScrollView(
                      child: AccountOfferCard(
                        margin: EdgeInsets.fromLTRB(12, 12, 12, 0),
                        bodyKey: 'account.offerBodyBoard',
                      ),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      for (final board in _boards) _buildList(s, board),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether one of the rows on [board] belongs to this player (SPEC §4.4):
  /// their id on the row, or a submission this device remembers making.
  bool _hasOwnEntry(_Board board) {
    final entries = _entries[board];
    if (entries == null) return false;
    for (final entry in entries) {
      if (_identity.owns(entry)) return true;
    }
    return false;
  }

  /// A national board is labelled with the country itself — its flag and code —
  /// rather than with a period, because that is what makes it a different board.
  String _label(Strings s, _Board board) {
    final (period, country) = board;
    if (country != null) return s.country(country);
    return switch (period) {
      LeaderboardPeriod.all => s.t('lb.all'),
      LeaderboardPeriod.week => s.t('lb.week'),
      LeaderboardPeriod.day => s.t('lb.day'),
    };
  }

  /// A tab whose label shrinks to fit instead of being clipped.
  Widget _tab(String label) => Tab(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    ),
  );

  Widget _buildList(Strings s, _Board board) {
    final theme = GameTheme.of(context);
    final entries = _entries[board];
    if (_loading[board] == true && entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed[board] == true && entries == null) {
      return Center(
        child: NeonPanel(
          margin: const EdgeInsets.all(24),
          color: theme.danger,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, color: theme.danger, size: 38),
              const SizedBox(height: 12),
              Text(s.t('lb.offline'), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              NeonButton(
                label: s.t('lb.retry'),
                height: 48,
                fontSize: 14,
                onPressed: () => _load(board, force: true),
              ),
            ],
          ),
        ),
      );
    }
    final myName = context.read<Settings>().playerName;
    final list = entries ?? const <LeaderboardEntry>[];
    final country = board.$2;
    return RefreshIndicator(
      onRefresh: () => _load(board, force: true),
      color: theme.accent,
      backgroundColor: theme.panelFill,
      child: list.isEmpty
          ? ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 60),
                Text(
                  country == null
                      ? s.t('lb.empty')
                      : s.f('lb.countryEmpty', {'country': s.country(country)}),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.textDim),
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final e = list[i];
                return _row(s, e, _identity.owns(e), e.name == myName);
              },
            ),
    );
  }

  Widget _row(Strings s, LeaderboardEntry e, bool mine, bool sameName) {
    final theme = GameTheme.of(context);
    final color = mine
        ? theme.accent
        : (e.rank <= 3 ? theme.accentLeaderboard : theme.outline);
    // A plain decorated row rather than a NeonPanel: a hundred of these scroll
    // past, and a BackdropFilter per row would blur the list at 100 sigma-wide
    // passes a frame.
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: ShapeDecoration(
        color: mine
            ? theme.accent.withValues(alpha: 0.12)
            : theme.panelFill.withValues(alpha: 0.7),
        shape: theme.border(
          theme.radius(0.64),
          color: color.withValues(alpha: mine ? 0.9 : 0.4),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              '${e.rank}',
              style: TextStyle(
                color: e.rank <= 3 ? theme.accentLeaderboard : theme.textDim,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (mine || sameName)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '(${s.t('lb.you')})',
                          style: TextStyle(
                            color: theme.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  s.f('lb.seconds', {'s': e.seconds}),
                  style: TextStyle(color: theme.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            '${e.score}',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
              color: theme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
