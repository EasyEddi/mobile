import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/perf.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats_controller.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats_storage.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';
import 'package:lichess_mobile/src/styles/lichess_colors.dart';
import 'package:lichess_mobile/src/styles/styles.dart';
import 'package:lichess_mobile/src/tab_navigation.dart';
import 'package:lichess_mobile/src/utils/l10n.dart';
import 'package:lichess_mobile/src/utils/l10n_context.dart';
import 'package:lichess_mobile/src/view/account/account_menu.dart';
import 'package:lichess_mobile/src/widgets/adaptive_choice_picker.dart';
import 'package:lichess_mobile/src/widgets/haptic_refresh_indicator.dart';
import 'package:lichess_mobile/src/widgets/list.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:lichess_mobile/src/widgets/platform_segmented_control.dart';
import 'package:lichess_mobile/src/widgets/stat_card.dart';
import 'package:material_ui/material_ui.dart';

/// How old the last sync can be before the tab syncs again on its own when it is shown.
const _kAutoSyncInterval = Duration(minutes: 10);

/// The statistics of the games of the user: results, accuracy, and the quality of the moves.
class const StatsTabScreen({super.key}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(gameStatsUserProvider);
    return PopScope(
      // As the home of the standalone statistics app, back closes the app.
      canPop: kStatsOnlyApp,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) {
          ref.read(currentBottomTabProvider.notifier).state = BottomTab.home;
        }
      },
      child: PlatformScaffold(
        appBar: PlatformAppBar(
          title: Text(context.l10n.stats),
          centerTitle: false,
          // The standalone statistics app cannot sign in.
          actions: kStatsOnlyApp ? null : const [AccountMenuButton()],
        ),
        body: switch (user) {
          AsyncData(value: final UserId userId) => _Body(key: ValueKey(userId), userId: userId),
          AsyncData() => const _UsernameForm(),
          AsyncError(:final error) => Center(child: Text('Could not load statistics: $error')),
          _ => const Center(child: CircularProgressIndicator.adaptive()),
        },
      ),
    );
  }
}

/// Asks for the username whose games are counted, when no user is signed in.
class const _UsernameForm() extends ConsumerStatefulWidget {
  @override
  ConsumerState<_UsernameForm> createState() => _UsernameFormState();
}

class _UsernameFormState() extends ConsumerState<_UsernameForm> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _controller.text.trim();
    if (username.isEmpty) return;
    final storage = await ref.read(gameStatsStorageProvider.future);
    await storage.saveUsername(username);
    if (mounted) ref.invalidate(gameStatsUserProvider);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: statsScrollController,
      padding: Styles.bodyPadding,
      children: [
        Text(_t(context, 'Your games', 'Deine Partien'), style: Styles.sectionTitle),
        const SizedBox(height: 8),
        Text(
          _t(
            context,
            'Sign in, or enter your lichess username to compute the statistics of your games.',
            'Melde dich an oder gib deinen Lichess-Benutzernamen ein, um die Statistiken deiner '
                'Partien zu berechnen.',
          ),
          style: TextStyle(color: textShade(context, Styles.subtitleOpacity)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: context.l10n.username,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _submit, child: Text(_t(context, 'Show statistics', 'Anzeigen'))),
      ],
    );
  }
}

class const _Body({required final UserId userId, super.key}) extends ConsumerStatefulWidget {
  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState() extends ConsumerState<_Body> {
  @override
  void initState() {
    super.initState();
    statsTabInteraction.addListener(_onTabInteraction);
    // The providers cannot be changed while the tree is built.
    unawaited(Future.microtask(_autoSync));
  }

  @override
  void dispose() {
    statsTabInteraction.removeListener(_onTabInteraction);
    super.dispose();
  }

  void _onTabInteraction() => unawaited(_sync());

  Future<void> _autoSync() async {
    if (!mounted) return;
    final state = ref.read(gameStatsControllerProvider(widget.userId));
    final lastSync = state.lastSync;
    if (lastSync == null || DateTime.now().difference(lastSync) > _kAutoSyncInterval) {
      await _sync();
    }
  }

  Future<void> _sync() => ref.read(gameStatsControllerProvider(widget.userId).notifier).sync();

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(gameStatsSummaryProvider(widget.userId));
    final syncState = ref.watch(gameStatsControllerProvider(widget.userId));
    final isSignedIn = ref.watch(isLoggedInProvider);

    return HapticRefreshIndicator(
      onRefresh: _sync,
      child: ListView(
        controller: statsScrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const _Filters(),
          _SyncSection(
            userId: widget.userId,
            state: syncState,
            pendingGames: summary.value?.pendingGames ?? 0,
            isSignedIn: isSignedIn,
          ),
          switch (summary) {
            AsyncData(:final value) when value.games == 0 => Padding(
              padding: Styles.bodySectionPadding,
              child: Center(
                child: Text(
                  syncState.isSyncing
                      ? _t(context, 'Loading your games…', 'Deine Partien werden geladen…')
                      : _t(context, 'No games to show.', 'Keine Partien vorhanden.'),
                  style: Styles.noResultTextStyle,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            AsyncData(:final value) => _Stats(value),
            AsyncError(:final error) => Padding(
              padding: Styles.bodySectionPadding,
              child: Text('Could not load statistics: $error'),
            ),
            _ => const Padding(
              padding: Styles.bodySectionPadding,
              child: Center(child: CircularProgressIndicator.adaptive()),
            ),
          },
        ],
      ),
    );
  }
}

/// The side filter choices: [Side] is not nullable in a [PlatformSegmentedControl].
enum _SideChoice() { both, white, black }

class const _Filters() extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(gameStatsFilterProvider);
    void update(GameStatsFilter newFilter) =>
        ref.read(gameStatsFilterProvider.notifier).state = newFilter;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: _FilterButton(
                  icon: Icons.timer_outlined,
                  label:
                      filter.perf?.label(context.l10n) ??
                      _t(context, 'All time controls', 'Alle Bedenkzeiten'),
                  onPressed: () => showChoicePicker<Perf?>(
                    context,
                    choices: [null, ...kGameStatsPerfs],
                    selectedItem: filter.perf,
                    labelBuilder: (perf) => Text(
                      perf?.label(context.l10n) ??
                          _t(context, 'All time controls', 'Alle Bedenkzeiten'),
                    ),
                    onSelectedItemChanged: (perf) => update(filter.copyWith(perf: () => perf)),
                  ),
                ),
              ),
              Expanded(
                child: _FilterButton(
                  icon: Icons.date_range,
                  label: _periodLabel(context, filter.period),
                  onPressed: () => showChoicePicker<StatsPeriod>(
                    context,
                    choices: StatsPeriod.values,
                    selectedItem: filter.period,
                    labelBuilder: (period) => Text(_periodLabel(context, period)),
                    onSelectedItemChanged: (period) => update(filter.copyWith(period: period)),
                  ),
                ),
              ),
            ],
          ),
          PlatformSegmentedControl<_SideChoice>(
            segments: [
              (_SideChoice.both, _t(context, 'Both colors', 'Beide Farben')),
              (_SideChoice.white, context.l10n.white),
              (_SideChoice.black, context.l10n.black),
            ],
            selected: switch (filter.side) {
              null => _SideChoice.both,
              Side.white => _SideChoice.white,
              Side.black => _SideChoice.black,
            },
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onChanged: (choice) => update(
              filter.copyWith(
                side: () => switch (choice) {
                  _SideChoice.both => null,
                  _SideChoice.white => Side.white,
                  _SideChoice.black => Side.black,
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class const _FilterButton({
  required final IconData icon,
  required final String label,
  required final VoidCallback onPressed,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// The state of the sync and of the local analysis, with the buttons to start them.
class const _SyncSection({
  required final UserId userId,
  required final GameStatsSyncState state,
  required final int pendingGames,
  required final bool isSignedIn,
}) extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(gameStatsControllerProvider(userId).notifier);
    final subtitleStyle = TextStyle(color: textShade(context, Styles.subtitleOpacity));

    final status = state.isSyncing
        ? _t(
            context,
            'Loading games… ${state.fetchedGames}',
            'Partien werden geladen… ${state.fetchedGames}',
          )
        : state.isAnalysing
        ? _t(
            context,
            'Analysing with Stockfish… ${state.analysedGames}/${state.gamesToAnalyse}',
            'Analyse mit Stockfish… ${state.analysedGames}/${state.gamesToAnalyse}',
          )
        : state.lastSync != null
        ? _t(
            context,
            'Updated ${relativeDate(context.l10n, state.lastSync!)}',
            'Aktualisiert: ${relativeDate(context.l10n, state.lastSync!)}',
          )
        : null;

    return ListSection(
      header: Text(isSignedIn ? _t(context, 'Your games', 'Deine Partien') : userId.value),
      headerTrailing: isSignedIn
          ? null
          : TextButton(
              onPressed: state.isBusy
                  ? null
                  : () async {
                      final storage = await ref.read(gameStatsStorageProvider.future);
                      await storage.saveUsername(null);
                      if (context.mounted) ref.invalidate(gameStatsUserProvider);
                    },
              child: Text(_t(context, 'Change', 'Ändern')),
            ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              if (state.isBusy)
                LinearProgressIndicator(
                  value: state.isAnalysing && state.gamesToAnalyse > 0
                      ? state.analysedGames / state.gamesToAnalyse
                      : null,
                ),
              if (status != null) Text(status, style: subtitleStyle),
              if (state.error != null)
                Text(
                  _errorMessage(context, state.error!),
                  style: TextStyle(color: ColorScheme.of(context).error),
                ),
              if (pendingGames > 0 && !state.isAnalysing)
                Text(
                  _t(
                    context,
                    '$pendingGames games have no computer analysis yet. They are analysed on this '
                        'device, $kGameStatsAnalysisBatch at a time.',
                    '$pendingGames Partien haben noch keine Computeranalyse. Sie werden auf diesem '
                        'Gerät analysiert, jeweils $kGameStatsAnalysisBatch.',
                  ),
                  style: subtitleStyle,
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (state.isAnalysing)
                    OutlinedButton.icon(
                      onPressed: controller.stopAnalysis,
                      icon: const Icon(Icons.stop),
                      label: Text(context.l10n.stop),
                    )
                  else if (pendingGames > 0)
                    FilledButton.tonalIcon(
                      onPressed: state.isSyncing ? null : controller.analyse,
                      icon: const Icon(Icons.memory),
                      label: Text(
                        _t(
                          context,
                          'Analyse ${math.min(pendingGames, kGameStatsAnalysisBatch)} games',
                          '${math.min(pendingGames, kGameStatsAnalysisBatch)} Partien analysieren',
                        ),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: state.isBusy ? null : controller.sync,
                    icon: const Icon(Icons.refresh),
                    label: Text(_t(context, 'Update', 'Aktualisieren')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class const _Stats(final GameStatsSummary summary) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    String percent(double share) => '${(share * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListSection(
          header: Text(_t(context, 'Overview', 'Übersicht')),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  StatCardRow([
                    StatCard(
                      context.l10n.gamesPlayed,
                      value: NumberFormat.decimalPattern().format(summary.games),
                    ),
                    StatCard(
                      _t(context, 'Moves', 'Züge'),
                      value: NumberFormat.decimalPattern().format(summary.moves),
                    ),
                    StatCard(
                      context.l10n.accuracy,
                      value: summary.accuracy != null ? '${summary.accuracy!.round()}%' : '–',
                    ),
                  ]),
                  StatCardRow([
                    StatCard(context.l10n.wins, value: percent(summary.rate(summary.wins))),
                    StatCard(context.l10n.draws, value: percent(summary.rate(summary.draws))),
                    StatCard(context.l10n.losses, value: percent(summary.rate(summary.losses))),
                  ]),
                  const SizedBox(height: 4),
                  _ResultsBar(summary),
                ],
              ),
            ),
          ],
        ),
        if (summary.analysedGames > 0) ...[
          _MoveQualitySection(summary),
          if (summary.timeline.length >= 2) _TimelineSection(summary),
        ],
      ],
    );
  }
}

/// The shares of wins, draws and losses, as one bar.
class const _ResultsBar(final GameStatsSummary summary) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final parts = [
      (summary.wins, LichessColors.green, context.l10n.wins),
      (summary.draws, LichessColors.grey, context.l10n.draws),
      (summary.losses, LichessColors.red, context.l10n.losses),
    ].where((part) => part.$1 > 0);
    return Semantics(
      label: parts.map((p) => '${p.$3} ${p.$1}').join(', '),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: SizedBox(
          height: 10,
          child: Row(
            children: [
              for (final (count, color, _) in parts)
                Expanded(
                  flex: count,
                  child: ColoredBox(color: color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class const _MoveQualitySection(final GameStatsSummary summary) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final total = summary.classifiedMoves;
    return ListSection(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_t(context, 'Move quality', 'Zugqualität')),
          Text(
            _t(
              context,
              '${summary.analysedGames} analysed games, $total moves',
              '${summary.analysedGames} analysierte Partien, $total Züge',
            ),
            style: Styles.subtitle.copyWith(color: textShade(context, Styles.subtitleOpacity)),
          ),
        ],
      ),
      children: [
        if (total > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SizedBox(
              height: 180,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 1,
                      centerSpaceRadius: 56,
                      startDegreeOffset: -90,
                      sections: [
                        for (final quality in MoveQuality.values)
                          if (summary.count(quality) > 0)
                            PieChartSectionData(
                              value: summary.count(quality).toDouble(),
                              color: moveQualityColor(quality),
                              radius: 28,
                              showTitle: false,
                            ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${(summary.strongShare * 100).round()}%', style: Styles.title),
                      Text(
                        _t(context, 'strong moves', 'starke Züge'),
                        style: TextStyle(
                          fontSize: 12,
                          color: textShade(context, Styles.subtitleOpacity),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        for (final quality in MoveQuality.values)
          _MoveQualityRow(
            quality: quality,
            count: summary.count(quality),
            share: summary.share(quality),
          ),
      ],
    );
  }
}

class const _MoveQualityRow({
  required final MoveQuality quality,
  required final int count,
  required final double share,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final color = moveQualityColor(quality);
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: color,
        child: Text(
          moveQualitySymbol(quality),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ),
      title: Text(moveQualityLabel(context, quality)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(2)),
          child: LinearProgressIndicator(
            value: share,
            minHeight: 4,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(NumberFormat.decimalPattern().format(count), style: Styles.bold),
          Text(
            '${(share * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 12, color: textShade(context, Styles.subtitleOpacity)),
          ),
        ],
      ),
    );
  }
}

class const _TimelineSection(final GameStatsSummary summary) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final gridColor = colorScheme.onSurface.withValues(alpha: 0.1);
    final axisLabelStyle = TextStyle(fontSize: 10, color: textShade(context, 0.6));
    final timeline = summary.timeline;
    final dateFormat = switch (summary.bucketSize) {
      StatsBucketSize.month => DateFormat.yMMM(),
      _ => DateFormat.MMMd(),
    };
    final series = [
      (
        _t(context, 'Accuracy', 'Genauigkeit'),
        Styles.chartColor(context),
        [
          for (final (i, bucket) in timeline.indexed)
            if (bucket.accuracy != null) FlSpot(i.toDouble(), bucket.accuracy!),
        ],
      ),
      (
        _t(context, 'Strong moves', 'Starke Züge'),
        moveQualityColor(MoveQuality.best),
        [
          for (final (i, bucket) in timeline.indexed)
            FlSpot(i.toDouble(), bucket.strongShare * 100),
        ],
      ),
      (
        _t(context, 'Errors', 'Fehler'),
        LichessColors.blunder,
        [for (final (i, bucket) in timeline.indexed) FlSpot(i.toDouble(), bucket.errorShare * 100)],
      ),
    ];

    return ListSection(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_t(context, 'Progress', 'Entwicklung')),
          Text(
            _t(context, 'In percent, by ', 'In Prozent, pro ') +
                switch (summary.bucketSize) {
                  StatsBucketSize.day => _t(context, 'day', 'Tag'),
                  StatsBucketSize.week => _t(context, 'week', 'Woche'),
                  StatsBucketSize.month => _t(context, 'month', 'Monat'),
                },
            style: Styles.subtitle.copyWith(color: textShade(context, Styles.subtitleOpacity)),
          ),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (timeline.length - 1).toDouble(),
                minY: 0,
                maxY: 100,
                lineBarsData: [
                  for (final (_, color, spots) in series)
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: color,
                      barWidth: 2,
                      dotData: FlDotData(show: timeline.length <= 12),
                    ),
                ],
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  horizontalInterval: 25,
                  getDrawingHorizontalLine: (value) =>
                      FlLine(color: gridColor, strokeWidth: 1, dashArray: const [4, 4]),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => colorScheme.surfaceContainerHighest,
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => [
                      for (final spot in spots)
                        LineTooltipItem(
                          '${series[spot.barIndex].$1}: ${spot.y.round()}%',
                          TextStyle(color: series[spot.barIndex].$2, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      interval: 25,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(value.toInt().toString(), style: axisLabelStyle),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: math.max(1.0, (timeline.length / 4).ceilToDouble()),
                      getTitlesWidget: (value, meta) {
                        final index = value.round();
                        if (index < 0 || index >= timeline.length || value != index) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          meta: meta,
                          child: Text(
                            dateFormat.format(timeline[index].start),
                            style: axisLabelStyle,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              for (final (label, color, _) in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Container(width: 12, height: 3, color: color),
                    Text(label, style: const TextStyle(fontSize: 12)),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The color of a move quality, in the style of the move annotations of the analysis board.
Color moveQualityColor(MoveQuality quality) => switch (quality) {
  MoveQuality.brilliant => const Color(0xFF1BACA6),
  MoveQuality.great => const Color(0xFF5C8BB0),
  MoveQuality.best => const Color(0xFF81B64C),
  MoveQuality.excellent => const Color(0xFF96BC4B),
  MoveQuality.good => const Color(0xFF97AF8B),
  MoveQuality.book => const Color(0xFFA88865),
  MoveQuality.inaccuracy => LichessColors.inaccuracy,
  MoveQuality.mistake => LichessColors.mistake,
  MoveQuality.blunder => LichessColors.blunder,
};

String moveQualitySymbol(MoveQuality quality) => switch (quality) {
  MoveQuality.brilliant => '!!',
  MoveQuality.great => '!',
  MoveQuality.best => '★',
  MoveQuality.excellent => '👍',
  MoveQuality.good => '✓',
  MoveQuality.book => '📖',
  MoveQuality.inaccuracy => '?!',
  MoveQuality.mistake => '?',
  MoveQuality.blunder => '??',
};

String moveQualityLabel(BuildContext context, MoveQuality quality) => switch (quality) {
  MoveQuality.brilliant => _t(context, 'Brilliant', 'Brillant'),
  MoveQuality.great => _t(context, 'Great', 'Großartig'),
  MoveQuality.best => _t(context, 'Best', 'Bester Zug'),
  MoveQuality.excellent => _t(context, 'Excellent', 'Exzellent'),
  MoveQuality.good => _t(context, 'Good', 'Gut'),
  MoveQuality.book => _t(context, 'Book', 'Buchzug'),
  MoveQuality.inaccuracy => _t(context, 'Inaccuracy', 'Ungenauigkeit'),
  MoveQuality.mistake => _t(context, 'Mistake', 'Fehler'),
  MoveQuality.blunder => _t(context, 'Blunder', 'Patzer'),
};

String _periodLabel(BuildContext context, StatsPeriod period) => switch (period) {
  StatsPeriod.week => context.l10n.nbDays(7),
  StatsPeriod.month => context.l10n.nbDays(30),
  StatsPeriod.threeMonths => context.l10n.nbDays(90),
  StatsPeriod.year => context.l10n.nbDays(365),
  StatsPeriod.all => _t(context, 'All time', 'Gesamter Zeitraum'),
};

String _errorMessage(BuildContext context, GameStatsError error) => switch (error) {
  GameStatsError.userNotFound => _t(context, 'User not found.', 'Benutzer nicht gefunden.'),
  GameStatsError.rateLimited => _t(
    context,
    'Lichess asked to slow down. Try again in a minute.',
    'Lichess bittet um eine Pause. Versuche es in einer Minute erneut.',
  ),
  GameStatsError.network => _t(
    context,
    'Could not reach lichess.',
    'Lichess ist nicht erreichbar.',
  ),
  GameStatsError.engine => _t(
    context,
    'The engine could not analyse the game.',
    'Die Engine konnte die Partie nicht analysieren.',
  ),
};

// TODO: move the strings of this screen to translation/source/mobile.xml once it is stable.
String _t(BuildContext context, String english, String german) =>
    Localizations.localeOf(context).languageCode == 'de' ? german : english;
