import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/database.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:sqflite/sqflite.dart';

/// A provider for [GameStatsStorage].
final gameStatsStorageProvider = FutureProvider<GameStatsStorage>((Ref ref) async {
  final db = await ref.watch(databaseProvider.future);
  return GameStatsStorage(db);
}, name: 'GameStatsStorageProvider');

const kGameStatsTable = 'game_stats';
const kGameStatsSyncTable = 'game_stats_sync';

/// The key of the row of [kGameStatsSyncTable] holding the username of the statistics, when no
/// user is signed in.
const _kUsernameKey = '**stats-username**';

/// Where the sync of the games of a user from the server is at.
///
/// The server sends the games from the newest to the oldest. The games from [oldest] to [newest]
/// are all stored: a sync fetches the games played after [newest], then, until [backfilled], the
/// games played before [oldest].
class const GameStatsSyncCursor({
  final DateTime? newest,
  final DateTime? oldest,
  final bool backfilled = false,
  final DateTime? lastSync,
}) {
  GameStatsSyncCursor copyWith({
    DateTime? newest,
    DateTime? oldest,
    bool? backfilled,
    DateTime? lastSync,
  }) => GameStatsSyncCursor(
    newest: newest ?? this.newest,
    oldest: oldest ?? this.oldest,
    backfilled: backfilled ?? this.backfilled,
    lastSync: lastSync ?? this.lastSync,
  );

  Map<String, dynamic> toJson() => {
    if (newest != null) 'newest': newest!.millisecondsSinceEpoch,
    if (oldest != null) 'oldest': oldest!.millisecondsSinceEpoch,
    'backfilled': backfilled,
    if (lastSync != null) 'lastSync': lastSync!.millisecondsSinceEpoch,
  };

  factory fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) => switch (json[key]) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    };
    return GameStatsSyncCursor(
      newest: date('newest'),
      oldest: date('oldest'),
      backfilled: json['backfilled'] == true,
      lastSync: date('lastSync'),
    );
  }
}

/// Stores the statistics of the games of the users locally.
class const GameStatsStorage(final Database _db) {
  /// All the games of [userId].
  Future<List<GameStatsEntry>> fetchAll(UserId userId) async {
    final rows = await _db.query(
      kGameStatsTable,
      columns: ['data'],
      where: 'userId = ?',
      whereArgs: [userId.value],
    );
    return rows.map(_entryFromRow).toList();
  }

  /// The newest games of [userId] that await a local analysis.
  Future<List<GameStatsEntry>> fetchAwaitingAnalysis(UserId userId, {int max = 20}) async {
    final rows = await _db.query(
      kGameStatsTable,
      columns: ['data'],
      where: 'userId = ? AND awaitsAnalysis = 1',
      whereArgs: [userId.value],
      orderBy: 'createdAt DESC',
      limit: max,
    );
    return rows.map(_entryFromRow).toList();
  }

  /// Saves [entries] for [userId].
  ///
  /// A game that is already analysed is not replaced by a version that is not, so that an analysis
  /// is never lost.
  Future<void> saveAll(UserId userId, Iterable<GameStatsEntry> entries) async {
    final list = entries.toList();
    if (list.isEmpty) return;
    await _db.transaction((txn) async {
      final notAnalysed = list.where((e) => !e.isAnalysed).map((e) => e.id.value).toList();
      final keep = <String>{};
      // sqlite limits the number of variables of a query: check them by chunks.
      for (var i = 0; i < notAnalysed.length; i += 500) {
        final chunk = notAnalysed.sublist(i, math.min(i + 500, notAnalysed.length));
        final rows = await txn.query(
          kGameStatsTable,
          columns: ['gameId', 'data'],
          where: 'userId = ? AND gameId IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: [userId.value, ...chunk],
        );
        for (final row in rows) {
          if (!_entryFromRow(row).awaitsAnalysis) keep.add(row['gameId']! as String);
        }
      }

      final batch = txn.batch();
      for (final entry in list) {
        if (keep.contains(entry.id.value)) continue;
        batch.insert(kGameStatsTable, {
          'userId': userId.value,
          'gameId': entry.id.value,
          'createdAt': entry.createdAt.millisecondsSinceEpoch,
          'awaitsAnalysis': entry.awaitsAnalysis ? 1 : 0,
          'data': jsonEncode(entry.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<GameStatsSyncCursor> fetchCursor(UserId userId) async {
    final json = await _readSyncRow(userId.value);
    return json != null ? GameStatsSyncCursor.fromJson(json) : const GameStatsSyncCursor();
  }

  Future<void> saveCursor(UserId userId, GameStatsSyncCursor cursor) =>
      _writeSyncRow(userId.value, cursor.toJson());

  /// The username whose games are counted when no user is signed in.
  Future<String?> fetchUsername() async {
    final json = await _readSyncRow(_kUsernameKey);
    return json?['username'] as String?;
  }

  Future<void> saveUsername(String? username) async {
    if (username == null) {
      await _db.delete(kGameStatsSyncTable, where: 'userId = ?', whereArgs: [_kUsernameKey]);
    } else {
      await _writeSyncRow(_kUsernameKey, {'username': username});
    }
  }

  /// Deletes the games and the sync cursor of [userId].
  Future<void> deleteAll(UserId userId) async {
    await _db.transaction((txn) async {
      await txn.delete(kGameStatsTable, where: 'userId = ?', whereArgs: [userId.value]);
      await txn.delete(kGameStatsSyncTable, where: 'userId = ?', whereArgs: [userId.value]);
    });
  }

  Future<Map<String, dynamic>?> _readSyncRow(String key) async {
    final rows = await _db.query(
      kGameStatsSyncTable,
      columns: ['data'],
      where: 'userId = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    final json = jsonDecode(rows.first['data']! as String);
    return json is Map<String, dynamic> ? json : null;
  }

  Future<void> _writeSyncRow(String key, Map<String, dynamic> json) => _db.insert(
    kGameStatsSyncTable,
    {'userId': key, 'data': jsonEncode(json)},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

GameStatsEntry _entryFromRow(Map<String, Object?> row) {
  final json = jsonDecode(row['data']! as String);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('[GameStatsStorage] cannot read game: expected an object');
  }
  return GameStatsEntry.fromJson(json);
}
