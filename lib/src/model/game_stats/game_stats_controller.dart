import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats_repository.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats_storage.dart';
import 'package:lichess_mobile/src/model/game_stats/local_game_analyser.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:logging/logging.dart';

final _logger = Logger('GameStatsController');

/// The number of games saved at once while syncing.
const _kSaveBatchSize = 50;

/// The number of games analysed by the local engine in one run, unless asked otherwise.
const kGameStatsAnalysisBatch = 10;

/// The user whose games are counted: the signed in user, else the username entered in the
/// statistics tab, if any.
final gameStatsUserProvider = FutureProvider.autoDispose<UserId?>((Ref ref) async {
  final authUser = ref.watch(authControllerProvider);
  if (authUser != null) return authUser.user.id;
  final storage = await ref.watch(gameStatsStorageProvider.future);
  final username = await storage.fetchUsername();
  return username != null ? UserId.fromUserName(username) : null;
}, name: 'GameStatsUserProvider');

/// The filters chosen in the statistics tab.
final gameStatsFilterProvider = StateProvider<GameStatsFilter>(
  (ref) => const GameStatsFilter(),
  name: 'GameStatsFilterProvider',
);

/// The games of a user stored locally.
final gameStatsEntriesProvider = FutureProvider.family<List<GameStatsEntry>, UserId>((
  Ref ref,
  UserId userId,
) async {
  final storage = await ref.watch(gameStatsStorageProvider.future);
  return await storage.fetchAll(userId);
}, name: 'GameStatsEntriesProvider');

/// The statistics of the games of a user matching the filters.
final gameStatsSummaryProvider = FutureProvider.family<GameStatsSummary, UserId>((
  Ref ref,
  UserId userId,
) async {
  final entries = await ref.watch(gameStatsEntriesProvider(userId).future);
  final filter = ref.watch(gameStatsFilterProvider);
  return GameStatsSummary.compute(entries, filter, DateTime.now());
}, name: 'GameStatsSummaryProvider');

/// The state of the sync and of the local analysis of the games of a user.
class const GameStatsSyncState({
  final bool isSyncing = false,

  /// The number of games fetched by the current sync.
  final int fetchedGames = 0,
  final bool isAnalysing = false,

  /// The number of games analysed, and to analyse, by the current local analysis.
  final int analysedGames = 0,
  final int gamesToAnalyse = 0,

  /// The last sync, if any.
  final DateTime? lastSync,

  /// Until when the lichess API should not be called, after a 429 Too Many Requests.
  final DateTime? rateLimitedUntil,
  final GameStatsError? error,
}) {
  bool get isBusy => isSyncing || isAnalysing;

  GameStatsSyncState copyWith({
    bool? isSyncing,
    int? fetchedGames,
    bool? isAnalysing,
    int? analysedGames,
    int? gamesToAnalyse,
    DateTime? lastSync,
    DateTime? rateLimitedUntil,
    GameStatsError? Function()? error,
  }) => GameStatsSyncState(
    isSyncing: isSyncing ?? this.isSyncing,
    fetchedGames: fetchedGames ?? this.fetchedGames,
    isAnalysing: isAnalysing ?? this.isAnalysing,
    analysedGames: analysedGames ?? this.analysedGames,
    gamesToAnalyse: gamesToAnalyse ?? this.gamesToAnalyse,
    lastSync: lastSync ?? this.lastSync,
    rateLimitedUntil: rateLimitedUntil ?? this.rateLimitedUntil,
    error: error != null ? error() : this.error,
  );
}

enum GameStatsError() {
  /// The user does not exist.
  userNotFound,

  /// The lichess API asked to slow down.
  rateLimited,

  /// The server could not be reached.
  network,

  /// The local engine could not analyse a game.
  engine,
}

final gameStatsControllerProvider =
    NotifierProvider.family<GameStatsController, GameStatsSyncState, UserId>(
      GameStatsController.new,
      name: 'GameStatsControllerProvider',
    );

/// Syncs the games of a user from the lichess API into the local storage, and analyses the games
/// that are not analysed with the local engine.
///
/// To respect the API limits, the requests are made one at a time, and none is made for a minute
/// after a 429 Too Many Requests. A game is fetched once: later syncs only fetch the games played
/// since the last one. A game analysed by the server or the local engine is never analysed again.
class GameStatsController(final UserId userId) extends Notifier<GameStatsSyncState> {
  LocalGameAnalyser? _analyser;
  bool _stopAnalysisRequested = false;

  @override
  GameStatsSyncState build() {
    ref.onDispose(() => _analyser?.dispose());
    unawaited(_loadLastSync());
    return const GameStatsSyncState();
  }

  Future<void> _loadLastSync() async {
    final storage = await ref.read(gameStatsStorageProvider.future);
    final cursor = await storage.fetchCursor(userId);
    if (ref.mounted && cursor.lastSync != null) {
      state = state.copyWith(lastSync: cursor.lastSync);
    }
  }

  bool get _isRateLimited =>
      state.rateLimitedUntil != null && DateTime.now().isBefore(state.rateLimitedUntil!);

  /// Fetches the new games, then the older ones not fetched yet, then checks whether the games
  /// awaiting an analysis have been analysed by the server meanwhile.
  Future<void> sync() async {
    if (state.isSyncing) return;
    if (_isRateLimited) {
      state = state.copyWith(error: () => GameStatsError.rateLimited);
      return;
    }
    state = state.copyWith(isSyncing: true, fetchedGames: 0, error: () => null);
    final storage = await ref.read(gameStatsStorageProvider.future);
    final repository = ref.read(gameStatsRepositoryProvider);
    try {
      var cursor = await storage.fetchCursor(userId);

      if (cursor.newest == null) {
        // First sync: from the newest game to the oldest one.
        cursor = await _fetch(storage, repository.userGames(userId), cursor, backfill: true);
        cursor = cursor.copyWith(backfilled: true);
      } else {
        // The games played since the last sync. The cursor only moves once they are all saved:
        // the server sends the newest first, so an interrupted sync would leave a gap.
        cursor = await _fetch(
          storage,
          repository.userGames(userId, since: cursor.newest!.add(const Duration(milliseconds: 1))),
          cursor,
          backfill: false,
        );
        if (!cursor.backfilled) {
          cursor = await _fetch(
            storage,
            repository.userGames(
              userId,
              until: cursor.oldest!.subtract(const Duration(milliseconds: 1)),
            ),
            cursor,
            backfill: true,
          );
          cursor = cursor.copyWith(backfilled: true);
        }
      }
      cursor = cursor.copyWith(lastSync: DateTime.now());
      await storage.saveCursor(userId, cursor);
      if (!ref.mounted) return;
      state = state.copyWith(lastSync: cursor.lastSync);

      await _refreshAwaitingAnalysis(storage, repository);
    } on GameStatsRateLimitException {
      _logger.info('Rate limited by the server, waiting before the next request');
      if (ref.mounted) {
        state = state.copyWith(
          rateLimitedUntil: DateTime.now().add(GameStatsRateLimitException.waitFor),
          error: () => GameStatsError.rateLimited,
        );
      }
    } on ServerException catch (e) {
      _logger.warning('Could not sync the games of $userId: $e');
      if (ref.mounted) {
        state = state.copyWith(
          error: () => e.statusCode == 404 ? GameStatsError.userNotFound : GameStatsError.network,
        );
      }
    } on Exception catch (e) {
      // No connectivity, timeouts, malformed responses.
      _logger.warning('Could not sync the games of $userId: $e');
      if (ref.mounted) state = state.copyWith(error: () => GameStatsError.network);
    } finally {
      if (ref.mounted) {
        state = state.copyWith(isSyncing: false);
        ref.invalidate(gameStatsEntriesProvider(userId));
      }
    }
  }

  /// Saves the games of [games] by batches, and returns the cursor moved over them.
  ///
  /// When [backfill] is true the games are older than the ones stored, and the cursor moves with
  /// every batch saved: an interrupted backfill goes on from where it stopped. Otherwise the cursor
  /// moves once the stream is done.
  Future<GameStatsSyncCursor> _fetch(
    GameStatsStorage storage,
    Stream<GameStatsEntry> games,
    GameStatsSyncCursor cursor, {
    required bool backfill,
  }) async {
    var current = cursor;
    var newest = cursor.newest;
    var oldest = cursor.oldest;
    final batch = <GameStatsEntry>[];

    Future<void> flush() async {
      await storage.saveAll(userId, batch);
      batch.clear();
      if (backfill) {
        current = current.copyWith(newest: newest, oldest: oldest);
        await storage.saveCursor(userId, current);
      }
      if (ref.mounted) ref.invalidate(gameStatsEntriesProvider(userId));
    }

    await for (final entry in games) {
      if (!ref.mounted) break;
      if (newest == null || entry.createdAt.isAfter(newest)) newest = entry.createdAt;
      if (oldest == null || entry.createdAt.isBefore(oldest)) oldest = entry.createdAt;
      batch.add(entry);
      state = state.copyWith(fetchedGames: state.fetchedGames + 1);
      if (batch.length >= _kSaveBatchSize) await flush();
    }
    await flush();
    return current.copyWith(newest: newest, oldest: oldest);
  }

  /// Fetches again the newest games awaiting an analysis, in case they were analysed on the
  /// server since they were fetched (an analysis requested on the website, for instance).
  Future<void> _refreshAwaitingAnalysis(
    GameStatsStorage storage,
    GameStatsRepository repository,
  ) async {
    final awaiting = await storage.fetchAwaitingAnalysis(userId, max: kMaxExportIds);
    if (awaiting.isEmpty) return;
    final analysed = await repository
        .gamesByIds(userId, awaiting.map((e) => e.id).toList())
        .where((e) => e.isAnalysed)
        .toList();
    await storage.saveAll(userId, analysed);
  }

  /// Analyses up to [maxGames] of the newest games awaiting an analysis with the local engine.
  Future<void> analyse({int maxGames = kGameStatsAnalysisBatch}) async {
    if (state.isAnalysing) return;
    _stopAnalysisRequested = false;
    final storage = await ref.read(gameStatsStorageProvider.future);
    final games = await storage.fetchAwaitingAnalysis(userId, max: maxGames);
    if (games.isEmpty || !ref.mounted) return;

    state = state.copyWith(
      isAnalysing: true,
      analysedGames: 0,
      gamesToAnalyse: games.length,
      error: () => null,
    );
    final analyser = _analyser ??= LocalGameAnalyser(ref);
    analyser.start();
    try {
      for (final game in games) {
        if (_stopAnalysisRequested || !ref.mounted) break;
        final analysed = await analyser.analyse(game);
        if (!ref.mounted) break;
        if (analysed == null) {
          if (!_stopAnalysisRequested) state = state.copyWith(error: () => GameStatsError.engine);
          break;
        }
        await storage.saveAll(userId, [analysed]);
        if (!ref.mounted) break;
        state = state.copyWith(analysedGames: state.analysedGames + 1);
        ref.invalidate(gameStatsEntriesProvider(userId));
      }
    } finally {
      analyser.dispose();
      if (ref.mounted) state = state.copyWith(isAnalysing: false);
    }
  }

  /// Stops the local analysis after the game being analysed, which is dropped.
  void stopAnalysis() {
    _stopAnalysisRequested = true;
    _analyser?.cancel();
  }

  /// Deletes the stored games of the user, to fetch them all again.
  Future<void> reset() async {
    if (state.isBusy) return;
    final storage = await ref.read(gameStatsStorageProvider.future);
    await storage.deleteAll(userId);
    if (!ref.mounted) return;
    state = const GameStatsSyncState();
    ref.invalidate(gameStatsEntriesProvider(userId));
  }
}
