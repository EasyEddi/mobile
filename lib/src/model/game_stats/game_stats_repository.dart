import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' show Client, Request, StreamedResponse;
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/network/http.dart';

/// A provider for the [GameStatsRepository].
final gameStatsRepositoryProvider = Provider<GameStatsRepository>((ref) {
  return GameStatsRepository(ref.watch(lichessClientProvider));
}, name: 'GameStatsRepositoryProvider');

/// Thrown when the server answers 429 Too Many Requests.
///
/// The lichess API asks to wait a full minute before making any other request.
class const GameStatsRateLimitException() implements Exception {
  static const waitFor = Duration(seconds: 61);

  @override
  String toString() => 'GameStatsRateLimitException';
}

/// The parameters of the game export API needed to compute the statistics.
const _exportParams = {
  'moves': 'true',
  'evals': 'true',
  'accuracy': 'true',
  'opening': 'true',
  'clocks': 'false',
  'pgnInJson': 'false',
};

/// The maximum number of games of a request to the export by ids API.
const kMaxExportIds = 300;

/// Fetches the games of a user with their analysis, for the statistics.
///
/// The games are streamed by the server (ND-JSON), so that thousands of them can be read without
/// holding them all in memory, and with a single request: the lichess API asks for requests to be
/// made one at a time.
class const GameStatsRepository(final Client client) {
  /// The games of [userId] played between [since] and [until], from the newest to the oldest.
  Stream<GameStatsEntry> userGames(UserId userId, {DateTime? since, DateTime? until}) async* {
    final uri = lichessUri('/api/games/user/${userId.value}', {
      ..._exportParams,
      'perfType': kGameStatsPerfs.map((perf) => perf.name).join(','),
      if (since != null) 'since': since.millisecondsSinceEpoch.toString(),
      if (until != null) 'until': until.millisecondsSinceEpoch.toString(),
    });
    final request = Request('GET', uri)..headers['Accept'] = 'application/x-ndjson';
    final response = await client.send(request);
    yield* _readEntries(uri, response, userId);
  }

  /// The games of [ids], as seen by [userId].
  ///
  /// Used to check whether the games awaiting an analysis have been analysed by the server since
  /// they were fetched, before analysing them locally.
  Stream<GameStatsEntry> gamesByIds(UserId userId, List<GameId> ids) async* {
    assert(ids.length <= kMaxExportIds);
    if (ids.isEmpty) return;
    final uri = lichessUri('/api/games/export/_ids', _exportParams);
    final request = Request('POST', uri)
      ..headers['Accept'] = 'application/x-ndjson'
      ..headers['Content-Type'] = 'text/plain'
      ..body = ids.map((id) => id.value).join(',');
    final response = await client.send(request);
    yield* _readEntries(uri, response, userId);
  }

  Stream<GameStatsEntry> _readEntries(Uri uri, StreamedResponse response, UserId userId) async* {
    if (response.statusCode == 429) {
      await response.stream.drain<void>();
      throw const GameStatsRateLimitException();
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
      throw ServerException(
        response.statusCode,
        'Request to $uri failed with status ${response.statusCode}',
        uri,
        null,
      );
    }
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final json = jsonDecode(line);
      if (json is! Map<String, dynamic>) continue;
      final entry = gameStatsEntryFromServerJson(json, userId);
      if (entry != null) yield entry;
    }
  }
}
