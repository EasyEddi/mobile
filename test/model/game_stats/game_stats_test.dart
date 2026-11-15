import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/perf.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';

Map<String, dynamic> _gameJson({
  String id = 'abcdefgh',
  String variant = 'standard',
  String perf = 'blitz',
  String? winner = 'white',
  bool withAnalysis = true,
}) => {
  'id': id,
  'rated': true,
  'variant': variant,
  'speed': perf,
  'perf': perf,
  'createdAt': 1700000000000,
  'lastMoveAt': 1700000300000,
  'status': 'mate',
  'players': {
    'white': {
      'user': {'name': 'Me', 'id': 'me'},
      'rating': 1500,
      if (withAnalysis)
        'analysis': {'inaccuracy': 0, 'mistake': 0, 'blunder': 0, 'acpl': 10, 'accuracy': 91},
    },
    'black': {
      'user': {'name': 'Opponent', 'id': 'opponent'},
      'rating': 1500,
    },
  },
  'winner': ?winner,
  'opening': {'eco': 'C20', 'name': "King's Pawn Game", 'ply': 2},
  'moves': 'e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7#',
  if (withAnalysis)
    'analysis': [
      {'eval': 20},
      {'eval': 20},
      {'eval': 15},
      {'eval': 20},
      {'eval': 0},
      {
        'mate': 1,
        'judgment': {'name': 'Blunder', 'comment': 'Blunder. Nf6 was best.'},
      },
    ],
};

void main() {
  const me = UserId('me');

  group('GameStatsEntry.fromServerJson', () {
    test('reads an analysed game', () {
      final entry = gameStatsEntryFromServerJson(_gameJson(), me)!;
      expect(entry.id, const GameId('abcdefgh'));
      expect(entry.perf, Perf.blitz);
      expect(entry.side, Side.white);
      expect(entry.outcome, GameOutcome.win);
      expect(entry.moveCount, 4);
      expect(entry.source, GameAnalysisSource.server);
      expect(entry.accuracy, 91);
      expect(entry.qualities, {
        MoveQuality.book: 1,
        MoveQuality.best: 1,
        MoveQuality.excellent: 1,
        MoveQuality.great: 1,
      });
      expect(entry.moves, isNull);
    });

    test('keeps the moves of a game awaiting an analysis', () {
      final entry = gameStatsEntryFromServerJson(_gameJson(withAnalysis: false), me)!;
      expect(entry.source, GameAnalysisSource.none);
      expect(entry.awaitsAnalysis, isTrue);
      expect(entry.moves, 'e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7#');
      expect(entry.bookPlies, 2);
    });

    test('reads the outcome from the point of view of the user', () {
      final black = gameStatsEntryFromServerJson(_gameJson(), const UserId('opponent'))!;
      expect(black.side, Side.black);
      expect(black.outcome, GameOutcome.loss);
      expect(black.moveCount, 3);
      final draw = gameStatsEntryFromServerJson(_gameJson(winner: null), me)!;
      expect(draw.outcome, GameOutcome.draw);
    });

    test('skips the games that are not counted', () {
      expect(gameStatsEntryFromServerJson(_gameJson(variant: 'chess960'), me), isNull);
      expect(gameStatsEntryFromServerJson(_gameJson(perf: 'atomic'), me), isNull);
      expect(gameStatsEntryFromServerJson(_gameJson(), const UserId('someone')), isNull);
    });

    test('survives a JSON round trip', () {
      final entry = gameStatsEntryFromServerJson(_gameJson(), me)!;
      final copy = GameStatsEntry.fromJson(entry.toJson());
      expect(copy.toJson(), entry.toJson());
    });
  });

  group('GameStatsSummary', () {
    final now = DateTime(2026, 6, 30);
    final analysed = GameStatsEntry(
      id: const GameId('aaaaaaaa'),
      createdAt: DateTime(2026, 6, 28),
      perf: Perf.blitz,
      side: Side.white,
      outcome: GameOutcome.win,
      moveCount: 30,
      source: GameAnalysisSource.local,
      accuracy: 80,
      qualities: const {MoveQuality.best: 20, MoveQuality.mistake: 10},
    );
    final pending = GameStatsEntry(
      id: const GameId('bbbbbbbb'),
      createdAt: DateTime(2026, 1, 10),
      perf: Perf.rapid,
      side: Side.black,
      outcome: GameOutcome.loss,
      moveCount: 40,
      source: GameAnalysisSource.none,
      moves: 'e4',
    );

    test('counts all the games', () {
      final summary = GameStatsSummary.compute([analysed, pending], const GameStatsFilter(), now);
      expect(summary.games, 2);
      expect(summary.wins, 1);
      expect(summary.losses, 1);
      expect(summary.draws, 0);
      expect(summary.moves, 70);
      expect(summary.analysedGames, 1);
      expect(summary.pendingGames, 1);
      expect(summary.classifiedMoves, 30);
      expect(summary.share(MoveQuality.best), closeTo(2 / 3, 1e-9));
      expect(summary.strongShare, closeTo(2 / 3, 1e-9));
      expect(summary.accuracy, 80);
      expect(summary.rate(summary.wins), 0.5);
    });

    test('filters by perf, side and period', () {
      final entries = [analysed, pending];
      expect(
        GameStatsSummary.compute(entries, const GameStatsFilter(perf: Perf.rapid), now).games,
        1,
      );
      expect(
        GameStatsSummary.compute(entries, const GameStatsFilter(side: Side.white), now).wins,
        1,
      );
      final lastMonth = GameStatsSummary.compute(
        entries,
        const GameStatsFilter(period: StatsPeriod.month),
        now,
      );
      expect(lastMonth.games, 1);
      expect(lastMonth.pendingGames, 0);
    });

    test('builds a timeline of the analysed games', () {
      final older = GameStatsEntry(
        id: const GameId('cccccccc'),
        createdAt: DateTime(2026, 3, 2),
        perf: Perf.blitz,
        side: Side.black,
        outcome: GameOutcome.draw,
        moveCount: 20,
        source: GameAnalysisSource.server,
        accuracy: 60,
        qualities: const {MoveQuality.good: 10, MoveQuality.blunder: 10},
      );
      final summary = GameStatsSummary.compute([analysed, older], const GameStatsFilter(), now);
      expect(summary.bucketSize, StatsBucketSize.month);
      expect(summary.timeline, hasLength(2));
      expect(summary.timeline.first.start, DateTime(2026, 3));
      expect(summary.timeline.first.errorShare, 0.5);
      expect(summary.timeline.last.accuracy, 80);
    });
  });

  test('bucketStart', () {
    // A Wednesday.
    final date = DateTime(2026, 7, 15, 18);
    expect(bucketStart(date, StatsBucketSize.day), DateTime(2026, 7, 15));
    expect(bucketStart(date, StatsBucketSize.week), DateTime(2026, 7, 13));
    expect(bucketStart(date, StatsBucketSize.month), DateTime(2026, 7));
  });
}
