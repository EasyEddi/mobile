import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/engine/engine_budget.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_context.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_preferences.dart';
import 'package:lichess_mobile/src/model/engine/position_evaluator.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/model/game_stats/game_stats.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';
import 'package:logging/logging.dart';

final _logger = Logger('LocalGameAnalyser');

/// How long the engine searches each position of a game.
///
/// A compromise between the accuracy of the statistics and the time and battery a game costs: a
/// game of 40 moves takes about half a minute.
const kStatsSearchTime = Duration(milliseconds: 350);

/// How long the first position waits for the engine to start.
const _kEngineStartTimeout = Duration(seconds: 20);

/// The context of the evaluator analysing the games of the statistics.
const kGameStatsEvaluationContext = EvaluationContext(
  id: StringId('game-stats'),
  variant: Variant.standard,
  initialPosition: Chess.initial,
);

/// Analyses the games awaiting an analysis with the local engine of the app, one position after
/// the other.
///
/// The engine is the one of the analysis screens ([positionEvaluatorProvider]), with the cores the
/// user chose for them, and two lines per position: the second one tells whether the best move was
/// the only good one.
class LocalGameAnalyser(final Ref _ref) {
  ProviderSubscription<EngineEvaluationState>? _subscription;
  bool _cancelled = false;

  PositionEvaluator get _evaluator =>
      _ref.read(positionEvaluatorProvider(kGameStatsEvaluationContext).notifier);

  /// Keeps the evaluator alive until [dispose].
  void start() {
    _cancelled = false;
    _subscription ??= _ref.listen(
      positionEvaluatorProvider(kGameStatsEvaluationContext),
      (_, _) {},
    );
  }

  /// Stops the analysis of the current game, which then returns null.
  void cancel() {
    _cancelled = true;
    if (_subscription != null) _evaluator.stop();
  }

  void dispose() {
    if (_subscription != null) {
      _evaluator.stop();
      _subscription!.close();
      _subscription = null;
    }
  }

  /// Analyses [entry] and returns it analysed, or with [GameAnalysisSource.unavailable] if its
  /// moves cannot be read, or null if the analysis was cancelled or the engine failed.
  Future<GameStatsEntry?> analyse(GameStatsEntry entry) async {
    assert(_subscription != null, 'start() must be called first');
    final moves = entry.moves;
    if (moves == null || moves.isEmpty) {
      return entry.copyWith(source: GameAnalysisSource.unavailable, clearMoves: true);
    }
    final sanMoves = moves.split(' ');

    // The positions of the game, with the moves leading to them.
    final steps = <Step>[];
    Position position = Chess.initial;
    for (final san in sanMoves) {
      final move = position.parseSan(san);
      if (move == null) {
        return entry.copyWith(source: GameAnalysisSource.unavailable, clearMoves: true);
      }
      position = position.playUnchecked(move);
      steps.add(Step(position: position, sanMove: SanMove(san, move)));
    }

    // The eval of every position, from the initial one to the last one.
    final evals = <ClientEval?>[];
    for (var i = 0; i <= steps.length; i++) {
      if (_cancelled) return null;
      final reached = i == 0 ? Chess.initial : steps[i - 1].position;
      if (reached.isGameOver) {
        evals.add(null);
        continue;
      }
      final eval = await _evaluate(IList(steps.sublist(0, i)), first: i == 0);
      if (_cancelled) return null;
      if (eval == null) {
        _logger.warning('No eval for ply $i of game ${entry.id}');
        return null;
      }
      evals.add(eval);
    }

    // Analysis of ply `i`: the eval of the position reached by its move, and the best moves of the
    // position it was played from.
    final analysis = <PlyAnalysis>[
      for (var i = 0; i < steps.length; i++)
        PlyAnalysis(
          cp: evals[i + 1]?.cp,
          mate: evals[i + 1]?.mate,
          bestMove: evals[i]?.bestMove?.uci,
          onlyMove: _isOnlyMove(evals[i]),
        ),
    ];

    final classification = classifyMoves(
      initialPosition: Chess.initial,
      sanMoves: sanMoves,
      analysis: analysis,
      pov: entry.side,
      bookPlies: entry.bookPlies ?? 0,
      computeJudgments: true,
    );

    return entry.copyWith(
      source: GameAnalysisSource.local,
      accuracy: classification.accuracy?.round(),
      qualities: classification.counts,
      clearMoves: true,
    );
  }

  /// Whether the best move of the position evaluated by [eval] is much better than the second one.
  bool? _isOnlyMove(ClientEval? eval) {
    if (eval == null) return null;
    final best = eval.bestMoves;
    if (best.length < 2) return null;
    return best[0].winningChances - best[1].winningChances >= kOnlyMoveMinGap;
  }

  Future<LocalEval?> _evaluate(IList<Step> steps, {required bool first}) async {
    final evaluationPrefs = _ref.read(engineEvaluationPreferencesProvider);
    final budget = _ref.read(engineBudgetProvider);
    final work = EvalWork(
      id: kGameStatsEvaluationContext.id,
      variant: Variant.standard,
      threads: budget.analysisThreads(evaluationPrefs.numEngineCores),
      searchTime: kStatsSearchTime,
      multiPv: 2,
      threatMode: false,
      initialPosition: Chess.initial,
      steps: steps,
    );

    LocalEval? latest;
    final subscription = _evaluator.evaluate(work).listen((result) => latest = result.$2);
    try {
      final started = DateTime.now();
      final startTimeout = first ? _kEngineStartTimeout : const Duration(seconds: 5);
      // Waits for the engine to start searching, then for the search to end.
      while (!_cancelled && DateTime.now().difference(started) < startTimeout + kStatsSearchTime) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final state = _ref.read(positionEvaluatorProvider(kGameStatsEvaluationContext));
        if (state.engine case AsyncError()) return null;
        if (latest != null &&
            !state.isComputing &&
            DateTime.now().difference(started) >= kStatsSearchTime) {
          break;
        }
      }
      return latest ?? _ref.read(positionEvaluatorProvider(kGameStatsEvaluationContext)).eval;
    } finally {
      await subscription.cancel();
    }
  }
}
