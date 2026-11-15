import 'package:dartchess/dartchess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/perf.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';

/// The perfs counted in the statistics: the standard chess speeds.
const kGameStatsPerfs = [
  Perf.ultraBullet,
  Perf.bullet,
  Perf.blitz,
  Perf.rapid,
  Perf.classical,
  Perf.correspondence,
];

enum GameOutcome { win, draw, loss }

/// Where the analysis of a game comes from.
enum GameAnalysisSource {
  /// Not analysed yet.
  none,

  /// The lichess server analysis.
  server,

  /// The local engine of the app.
  local,

  /// The game cannot be analysed (no moves, unreadable moves...): it is never tried again.
  unavailable,
}

/// The statistics of one game of the user, as stored locally.
class const GameStatsEntry({
  required final GameId id,
  required final DateTime createdAt,
  required final Perf perf,
  required final Side side,
  required final GameOutcome outcome,

  /// The number of moves played by the user.
  required final int moveCount,
  required final GameAnalysisSource source,

  /// The accuracy of the user, from 0 to 100, if the game is analysed.
  final int? accuracy,

  /// The number of moves of the user of each quality, if the game is analysed.
  final Map<MoveQuality, int> qualities = const {},

  /// The moves of the game in SAN, kept only while the game awaits a local analysis.
  final String? moves,

  /// The number of plies of the game in the opening book, kept with [moves].
  final int? bookPlies,
}) {
  bool get isAnalysed => source == GameAnalysisSource.server || source == GameAnalysisSource.local;

  bool get awaitsAnalysis => source == GameAnalysisSource.none;

  GameStatsEntry copyWith({
    GameAnalysisSource? source,
    int? accuracy,
    Map<MoveQuality, int>? qualities,
    bool clearMoves = false,
  }) => GameStatsEntry(
    id: id,
    createdAt: createdAt,
    perf: perf,
    side: side,
    outcome: outcome,
    moveCount: moveCount,
    source: source ?? this.source,
    accuracy: accuracy ?? this.accuracy,
    qualities: qualities ?? this.qualities,
    moves: clearMoves ? null : moves,
    bookPlies: clearMoves ? null : bookPlies,
  );

  Map<String, dynamic> toJson() => {
    'id': id.value,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'perf': perf.name,
    'side': side.name,
    'outcome': outcome.name,
    'moveCount': moveCount,
    'source': source.name,
    if (accuracy != null) 'accuracy': accuracy,
    if (qualities.isNotEmpty) 'qualities': {for (final e in qualities.entries) e.key.name: e.value},
    if (moves != null) 'moves': moves,
    if (bookPlies != null) 'bookPlies': bookPlies,
  };

  factory fromJson(Map<String, dynamic> json) {
    final qualities = json['qualities'] as Map<String, dynamic>?;
    return GameStatsEntry(
      id: GameId(json['id'] as String),
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      perf: Perf.values.byName(json['perf'] as String),
      side: Side.values.byName(json['side'] as String),
      outcome: GameOutcome.values.byName(json['outcome'] as String),
      moveCount: json['moveCount'] as int,
      source: GameAnalysisSource.values.byName(json['source'] as String),
      accuracy: json['accuracy'] as int?,
      qualities: {
        if (qualities != null)
          for (final e in qualities.entries) MoveQuality.values.byName(e.key): e.value as int,
      },
      moves: json['moves'] as String?,
      bookPlies: json['bookPlies'] as int?,
    );
  }
}

/// Reads a game of the export API (`GET /api/games/user/{username}` or
/// `POST /api/games/export/_ids`, with `moves`, `evals`, `accuracy` and `opening`) from the point
/// of view of [userId].
///
/// Returns null for a game that is not counted: not standard chess, not finished, or not played
/// by [userId].
GameStatsEntry? gameStatsEntryFromServerJson(Map<String, dynamic> json, UserId userId) {
  if (json['variant'] != 'standard') return null;
  final perfName = json['perf'] as String?;
  final perf = perfName != null ? Perf.nameMap[perfName] : null;
  if (perf == null || !kGameStatsPerfs.contains(perf)) return null;
  final status = json['status'];
  if (status is! String || _unfinishedStatuses.contains(status)) return null;

  final players = json['players'] as Map<String, dynamic>?;
  if (players == null) return null;
  Side? side;
  for (final s in Side.values) {
    final player = players[s.name] as Map<String, dynamic>?;
    final user = player?['user'] as Map<String, dynamic>?;
    if (user != null && user['id'] == userId.value) side = s;
  }
  if (side == null) return null;

  final winner = json['winner'] as String?;
  final outcome = winner == null
      ? GameOutcome.draw
      : winner == side.name
      ? GameOutcome.win
      : GameOutcome.loss;

  final moves = (json['moves'] as String?) ?? '';
  final sanMoves = moves.isEmpty ? const <String>[] : moves.split(' ');
  final moveCount = side == Side.white ? (sanMoves.length + 1) ~/ 2 : sanMoves.length ~/ 2;
  final opening = json['opening'] as Map<String, dynamic>?;
  final bookPlies = (opening?['ply'] as int?) ?? 0;

  final rawAnalysis = json['analysis'] as List<dynamic>?;
  final player = players[side.name] as Map<String, dynamic>;
  final playerAnalysis = player['analysis'] as Map<String, dynamic>?;

  final base = GameStatsEntry(
    id: GameId(json['id'] as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    perf: perf,
    side: side,
    outcome: outcome,
    moveCount: moveCount,
    source: moveCount == 0 ? GameAnalysisSource.unavailable : GameAnalysisSource.none,
    moves: moveCount == 0 ? null : moves,
    bookPlies: moveCount == 0 ? null : bookPlies,
  );

  if (rawAnalysis == null || rawAnalysis.isEmpty || moveCount == 0) return base;

  final analysis = [
    for (final ply in rawAnalysis.cast<Map<String, dynamic>>())
      PlyAnalysis(
        cp: ply['eval'] as int?,
        mate: ply['mate'] as int?,
        judgment: switch (ply['judgment']) {
          {'name': final String name} => moveQualityFromJudgment(name),
          _ => null,
        },
      ),
  ];
  // The server analysis may still be running: its evals are then missing.
  if (!analysis.any((ply) => ply.hasEval)) return base;

  final classification = classifyMoves(
    initialPosition: Chess.initial,
    sanMoves: sanMoves,
    analysis: analysis,
    pov: side,
    bookPlies: bookPlies,
  );
  return base.copyWith(
    source: GameAnalysisSource.server,
    accuracy: (playerAnalysis?['accuracy'] as int?) ?? classification.accuracy?.round(),
    qualities: classification.counts,
    clearMoves: true,
  );
}

const _unfinishedStatuses = {'created', 'started', 'aborted', 'noStart', 'unknownFinish'};

/// A period of time the statistics are filtered on.
enum StatsPeriod {
  week(7),
  month(30),
  threeMonths(90),
  year(365),
  all(null);

  const StatsPeriod(this.days);

  final int? days;
}

/// The filters of the statistics.
class const GameStatsFilter({
  /// The perf of the games, or null for all of them.
  final Perf? perf,

  /// The side of the user, or null for both.
  final Side? side,
  final StatsPeriod period = StatsPeriod.all,
}) {
  bool matches(GameStatsEntry entry, DateTime now) =>
      (perf == null || entry.perf == perf) &&
      (side == null || entry.side == side) &&
      (period.days == null || entry.createdAt.isAfter(now.subtract(Duration(days: period.days!))));

  GameStatsFilter copyWith({
    Perf? Function()? perf,
    Side? Function()? side,
    StatsPeriod? period,
  }) => GameStatsFilter(
    perf: perf != null ? perf() : this.perf,
    side: side != null ? side() : this.side,
    period: period ?? this.period,
  );

  @override
  bool operator ==(Object other) =>
      other is GameStatsFilter &&
      other.perf == perf &&
      other.side == side &&
      other.period == period;

  @override
  int get hashCode => Object.hash(perf, side, period);
}

/// How long a [StatsBucket] of the timeline lasts.
enum StatsBucketSize { day, week, month }

/// The statistics of the analysed games of one period of the timeline.
class const StatsBucket({
  required final DateTime start,
  required final int games,
  required final int moves,

  /// The average accuracy of the games, if any of them has one.
  required final double? accuracy,

  /// The share of brilliant, great, best and excellent moves, from 0 to 1.
  required final double strongShare,

  /// The share of inaccuracies, mistakes and blunders, from 0 to 1.
  required final double errorShare,
});

/// The statistics of the games matching a [GameStatsFilter].
class const GameStatsSummary({
  required final int games,
  required final int wins,
  required final int draws,
  required final int losses,

  /// The number of moves of the user in all the games.
  required final int moves,
  required final int analysedGames,

  /// The number of games awaiting a local analysis.
  required final int pendingGames,

  /// The number of moves of the user of each quality, in the analysed games.
  required final Map<MoveQuality, int> qualities,

  /// The average accuracy of the analysed games.
  required final double? accuracy,
  required final List<StatsBucket> timeline,
  required final StatsBucketSize bucketSize,
}) {
  /// The number of classified moves.
  int get classifiedMoves => qualities.values.fold(0, (a, b) => a + b);

  int count(MoveQuality quality) => qualities[quality] ?? 0;

  /// The share of [quality] among the classified moves, from 0 to 1.
  double share(MoveQuality quality) =>
      classifiedMoves == 0 ? 0 : count(quality) / classifiedMoves;

  /// The share of brilliant, great, best and excellent moves among the classified moves.
  double get strongShare => classifiedMoves == 0
      ? 0
      : qualities.entries.where((e) => e.key.isStrong).fold(0, (a, e) => a + e.value) /
            classifiedMoves;

  /// The share of [value] games among all the games, from 0 to 1.
  double rate(int value) => games == 0 ? 0 : value / games;

  /// The maximum number of buckets of the timeline.
  static const maxBuckets = 24;

  factory compute(
    Iterable<GameStatsEntry> entries,
    GameStatsFilter filter,
    DateTime now,
  ) {
    var games = 0;
    var wins = 0;
    var draws = 0;
    var losses = 0;
    var moves = 0;
    var analysed = 0;
    var pending = 0;
    var accuracySum = 0;
    var accuracyCount = 0;
    final qualities = <MoveQuality, int>{};
    final analysedEntries = <GameStatsEntry>[];

    for (final entry in entries) {
      if (!filter.matches(entry, now)) continue;
      games++;
      moves += entry.moveCount;
      switch (entry.outcome) {
        case GameOutcome.win:
          wins++;
        case GameOutcome.draw:
          draws++;
        case GameOutcome.loss:
          losses++;
      }
      if (entry.awaitsAnalysis) pending++;
      if (entry.isAnalysed) {
        analysed++;
        analysedEntries.add(entry);
        for (final e in entry.qualities.entries) {
          qualities[e.key] = (qualities[e.key] ?? 0) + e.value;
        }
        if (entry.accuracy != null) {
          accuracySum += entry.accuracy!;
          accuracyCount++;
        }
      }
    }

    final (timeline, bucketSize) = _timeline(analysedEntries);

    return GameStatsSummary(
      games: games,
      wins: wins,
      draws: draws,
      losses: losses,
      moves: moves,
      analysedGames: analysed,
      pendingGames: pending,
      qualities: qualities,
      accuracy: accuracyCount == 0 ? null : accuracySum / accuracyCount,
      timeline: timeline,
      bucketSize: bucketSize,
    );
  }

  static (List<StatsBucket>, StatsBucketSize) _timeline(List<GameStatsEntry> entries) {
    if (entries.isEmpty) return (const [], StatsBucketSize.month);
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final span = entries.last.createdAt.difference(entries.first.createdAt);
    final size = span.inDays <= 14
        ? StatsBucketSize.day
        : span.inDays <= 120
        ? StatsBucketSize.week
        : StatsBucketSize.month;

    final groups = <DateTime, List<GameStatsEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(bucketStart(entry.createdAt, size), () => []).add(entry);
    }

    final buckets = [
      for (final MapEntry(key: start, value: group) in groups.entries)
        _bucket(start, group),
    ];
    final skip = buckets.length > maxBuckets ? buckets.length - maxBuckets : 0;
    return (buckets.sublist(skip), size);
  }

  static StatsBucket _bucket(DateTime start, List<GameStatsEntry> group) {
    var moves = 0;
    var strong = 0;
    var errors = 0;
    var accuracySum = 0;
    var accuracyCount = 0;
    for (final entry in group) {
      for (final MapEntry(key: quality, value: count) in entry.qualities.entries) {
        moves += count;
        if (quality.isStrong) strong += count;
        if (quality.isError) errors += count;
      }
      if (entry.accuracy != null) {
        accuracySum += entry.accuracy!;
        accuracyCount++;
      }
    }
    return StatsBucket(
      start: start,
      games: group.length,
      moves: moves,
      accuracy: accuracyCount == 0 ? null : accuracySum / accuracyCount,
      strongShare: moves == 0 ? 0 : strong / moves,
      errorShare: moves == 0 ? 0 : errors / moves,
    );
  }
}

/// The start of the bucket of [size] that [date] falls in, in local time.
DateTime bucketStart(DateTime date, StatsBucketSize size) {
  final local = date.toLocal();
  return switch (size) {
    StatsBucketSize.day => DateTime(local.year, local.month, local.day),
    StatsBucketSize.week => DateTime(local.year, local.month, local.day - (local.weekday - 1)),
    StatsBucketSize.month => DateTime(local.year, local.month),
  };
}
