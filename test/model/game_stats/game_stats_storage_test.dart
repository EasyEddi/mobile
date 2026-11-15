import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/db/database.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/perf.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats_storage.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

GameStatsEntry _entry(String id, DateTime createdAt, GameAnalysisSource source) => GameStatsEntry(
  id: GameId(id),
  createdAt: createdAt,
  perf: Perf.blitz,
  side: Side.white,
  outcome: GameOutcome.win,
  moveCount: 10,
  source: source,
  qualities: source == GameAnalysisSource.local ? const {MoveQuality.best: 10} : const {},
  moves: source == GameAnalysisSource.none ? 'e4 e5' : null,
);

void main() {
  const me = UserId('me');

  Future<GameStatsStorage> makeStorage() async {
    final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    return GameStatsStorage(db);
  }

  test('saves and fetches the games of a user', () async {
    final storage = await makeStorage();
    await storage.saveAll(me, [
      _entry('aaaaaaaa', DateTime(2026, 1, 1), GameAnalysisSource.none),
      _entry('bbbbbbbb', DateTime(2026, 1, 2), GameAnalysisSource.local),
      _entry('cccccccc', DateTime(2026, 1, 3), GameAnalysisSource.none),
    ]);
    expect(await storage.fetchAll(me), hasLength(3));
    expect(await storage.fetchAll(const UserId('someone')), isEmpty);

    final awaiting = await storage.fetchAwaitingAnalysis(me);
    expect(awaiting.map((e) => e.id), [const GameId('cccccccc'), const GameId('aaaaaaaa')]);
  });

  test('never replaces an analysed game with a game awaiting an analysis', () async {
    final storage = await makeStorage();
    await storage.saveAll(me, [_entry('aaaaaaaa', DateTime(2026, 1, 1), GameAnalysisSource.local)]);
    await storage.saveAll(me, [_entry('aaaaaaaa', DateTime(2026, 1, 1), GameAnalysisSource.none)]);
    final games = await storage.fetchAll(me);
    expect(games.single.source, GameAnalysisSource.local);
    expect(await storage.fetchAwaitingAnalysis(me), isEmpty);

    // But an analysis replaces a game awaiting one.
    await storage.saveAll(me, [_entry('bbbbbbbb', DateTime(2026, 1, 2), GameAnalysisSource.none)]);
    await storage.saveAll(me, [_entry('bbbbbbbb', DateTime(2026, 1, 2), GameAnalysisSource.local)]);
    expect(await storage.fetchAwaitingAnalysis(me), isEmpty);
  });

  test('saves the sync cursor and the username', () async {
    final storage = await makeStorage();
    expect((await storage.fetchCursor(me)).newest, isNull);
    await storage.saveCursor(
      me,
      GameStatsSyncCursor(
        newest: DateTime(2026, 2, 1),
        oldest: DateTime(2025, 1, 1),
        backfilled: true,
      ),
    );
    final cursor = await storage.fetchCursor(me);
    expect(cursor.newest, DateTime(2026, 2, 1));
    expect(cursor.oldest, DateTime(2025, 1, 1));
    expect(cursor.backfilled, isTrue);

    expect(await storage.fetchUsername(), isNull);
    await storage.saveUsername('Me');
    expect(await storage.fetchUsername(), 'Me');
    await storage.saveUsername(null);
    expect(await storage.fetchUsername(), isNull);
  });

  test('deletes the games of a user', () async {
    final storage = await makeStorage();
    await storage.saveAll(me, [_entry('aaaaaaaa', DateTime(2026, 1, 1), GameAnalysisSource.none)]);
    await storage.saveCursor(me, GameStatsSyncCursor(newest: DateTime(2026, 1, 1)));
    await storage.deleteAll(me);
    expect(await storage.fetchAll(me), isEmpty);
    expect((await storage.fetchCursor(me)).newest, isNull);
  });
}
