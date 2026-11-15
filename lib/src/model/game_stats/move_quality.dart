import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

/// The quality of a move, from the best to the worst.
///
/// Lichess only judges inaccuracies, mistakes and blunders. The other qualities are derived from
/// the evaluations of the positions before and after the move, see [classifyMoves].
enum MoveQuality {
  brilliant,
  great,
  best,
  excellent,
  good,
  book,
  inaccuracy,
  mistake,
  blunder;

  /// Whether the move is an inaccuracy, a mistake or a blunder.
  bool get isError => index >= MoveQuality.inaccuracy.index;

  /// Whether the move is among the best ones: brilliant, great, best or excellent.
  bool get isStrong => index <= MoveQuality.excellent.index;
}

/// The quality matching the name of a lichess server judgment.
MoveQuality? moveQualityFromJudgment(String name) => switch (name) {
  'Inaccuracy' => MoveQuality.inaccuracy,
  'Mistake' => MoveQuality.mistake,
  'Blunder' => MoveQuality.blunder,
  _ => null,
};

/// The maximum loss of winning chances of a move counted as the best one.
const kBestMoveMaxLoss = 0.02;

/// The maximum loss of winning chances of an excellent move.
const kExcellentMoveMaxLoss = 0.05;

/// The losses of winning chances from which a move is an inaccuracy, a mistake or a blunder.
///
/// The same thresholds as the lichess server analysis
/// (https://github.com/lichess-org/lila/blob/master/modules/analyse/src/main/Advice.scala).
const kInaccuracyMinLoss = 0.1;
const kMistakeMinLoss = 0.2;
const kBlunderMinLoss = 0.3;

/// The minimum difference of winning chances between the best and the second best move for the
/// best move to be the only good one.
const kOnlyMoveMinGap = 0.2;

/// The evaluation of the initial position, from white's point of view.
const kInitialPositionCp = 20;

/// The analysis of one ply of a game.
class const PlyAnalysis({
  /// The evaluation in centipawns of the position reached by the move, from white's point of view.
  final int? cp,

  /// The number of moves to mate in the position reached by the move, positive if white mates.
  final int? mate,

  /// The judgment of the move by the lichess server analysis, if any.
  final MoveQuality? judgment,

  /// The best move, in UCI notation, of the position the move was played from, if known.
  final String? bestMove,

  /// Whether the best move of the position the move was played from was the only good one, if
  /// known.
  final bool? onlyMove,
}) {
  bool get hasEval => cp != null || mate != null;

  /// The winning chances of [side] in the position reached by the move, from -1 to 1.
  double? winningChances(Side side) {
    final white = whiteWinningChances(cp: cp, mate: mate);
    if (white == null) return null;
    return side == Side.white ? white : -white;
  }

  Map<String, dynamic> toJson() => {
    if (cp != null) 'cp': cp,
    if (mate != null) 'mate': mate,
    if (judgment != null) 'judgment': judgment!.name,
    if (bestMove != null) 'best': bestMove,
    if (onlyMove != null) 'only': onlyMove,
  };
}

/// The winning chances of white, from -1 to 1, as computed by lichess.
///
/// See https://github.com/lichess-org/lila/pull/11148
double? whiteWinningChances({int? cp, int? mate}) {
  if (mate != null) {
    final mateCp = (21 - math.min(10, mate.abs())) * 100;
    return _rawWinningChances(mate >= 0 ? mateCp : -mateCp);
  }
  if (cp != null) {
    return _rawWinningChances(cp.clamp(-1000, 1000));
  }
  return null;
}

double _rawWinningChances(num cp) {
  const multiplier = -0.00368208;
  return 2 / (1 + math.exp(multiplier * cp)) - 1;
}

/// The result of [classifyMoves].
class const GameClassification({
  /// The qualities of the moves of the player, in order; null for a move that could not be
  /// classified, for want of an evaluation.
  required final List<MoveQuality?> qualities,

  /// The accuracy of the player in the game, from 0 to 100, if it could be computed.
  required final double? accuracy,
}) {
  /// The number of moves of each quality.
  Map<MoveQuality, int> get counts {
    final counts = <MoveQuality, int>{};
    for (final quality in qualities) {
      if (quality != null) counts[quality] = (counts[quality] ?? 0) + 1;
    }
    return counts;
  }
}

/// Classifies the moves of [pov] in a game.
///
/// [analysis] has one entry per ply, the one at index `i` being the analysis of the position
/// reached by the move at index `i` of [sanMoves].
///
/// The moves judged by the lichess server keep its judgment. When [computeJudgments] is true (an
/// analysis by the local engine, which does not judge moves), inaccuracies, mistakes and blunders
/// are computed from the loss of winning chances, with the thresholds of the server.
///
/// Among the other moves:
/// - the [bookPlies] first plies are book moves;
/// - a move losing at most [kBestMoveMaxLoss] winning chances, or the best move of the engine, is:
///   - brilliant if it sacrifices material without spoiling the position;
///   - great if it was the only good move, or if it punishes a mistake or a blunder of the
///     opponent;
///   - best otherwise;
/// - a move losing at most [kExcellentMoveMaxLoss] winning chances is excellent;
/// - any other move is good.
GameClassification classifyMoves({
  required Position initialPosition,
  required List<String> sanMoves,
  required List<PlyAnalysis> analysis,
  required Side pov,
  int bookPlies = 0,
  bool computeJudgments = false,
}) {
  final qualities = <MoveQuality?>[];
  final moveAccuracies = <double>[];
  Position position = initialPosition;
  MoveQuality? previousQuality;

  for (var ply = 0; ply < sanMoves.length; ply++) {
    final move = position.parseSan(sanMoves[ply]);
    if (move == null) break;
    final mover = position.turn;
    final after = position.playUnchecked(move);
    final plyAnalysis = ply < analysis.length ? analysis[ply] : null;

    final before = ply == 0
        ? _initialWinningChances(mover)
        : (ply - 1 < analysis.length ? analysis[ply - 1].winningChances(mover) : null);
    final afterChances = _winningChancesAfter(after, plyAnalysis, mover);

    MoveQuality? quality;
    if (before != null && afterChances != null) {
      final loss = math.max(0.0, before - afterChances);
      final judgment =
          plyAnalysis?.judgment ?? (computeJudgments ? _judgmentFromLoss(loss) : null);
      final playedBest = plyAnalysis?.bestMove != null && plyAnalysis!.bestMove == move.uci;

      if (judgment != null) {
        quality = judgment;
      } else if (ply < bookPlies) {
        quality = MoveQuality.book;
      } else if (loss <= kBestMoveMaxLoss || playedBest) {
        if (afterChances > -0.1 && before < 0.9 && isSacrifice(position, move)) {
          quality = MoveQuality.brilliant;
        } else if (plyAnalysis?.onlyMove == true ||
            previousQuality == MoveQuality.mistake ||
            previousQuality == MoveQuality.blunder) {
          quality = MoveQuality.great;
        } else {
          quality = MoveQuality.best;
        }
      } else if (loss <= kExcellentMoveMaxLoss) {
        quality = MoveQuality.excellent;
      } else {
        quality = MoveQuality.good;
      }

      if (mover == pov && ply >= bookPlies) {
        moveAccuracies.add(moveAccuracy(_winPercent(before), _winPercent(afterChances)));
      }
    } else if (plyAnalysis?.judgment != null) {
      quality = plyAnalysis!.judgment;
    } else if (ply < bookPlies) {
      quality = MoveQuality.book;
    }

    if (mover == pov) qualities.add(quality);
    previousQuality = quality;
    position = after;
  }

  return GameClassification(qualities: qualities, accuracy: gameAccuracy(moveAccuracies));
}

double _initialWinningChances(Side side) {
  final white = whiteWinningChances(cp: kInitialPositionCp)!;
  return side == Side.white ? white : -white;
}

/// The winning chances of [mover] in the position reached by its move.
double? _winningChancesAfter(Position after, PlyAnalysis? analysis, Side mover) {
  if (after.isCheckmate) return 1.0;
  if (after.isStalemate || after.isInsufficientMaterial) return 0.0;
  return analysis?.winningChances(mover);
}

MoveQuality? _judgmentFromLoss(double loss) {
  if (loss >= kBlunderMinLoss) return MoveQuality.blunder;
  if (loss >= kMistakeMinLoss) return MoveQuality.mistake;
  if (loss >= kInaccuracyMinLoss) return MoveQuality.inaccuracy;
  return null;
}

/// Whether the move gives material away: a piece moves to a square where it can be taken by a
/// cheaper piece, or where it is not defended, for less than it is worth.
bool isSacrifice(Position position, Move move) {
  if (move is! NormalMove || move.promotion != null) return false;
  final piece = position.board.pieceAt(move.from);
  if (piece == null || piece.role == Role.pawn || piece.role == Role.king) return false;
  final movedValue = _pieceValue(piece.role);
  final capturedRole = position.board.roleAt(move.to);
  final capturedValue = capturedRole != null ? _pieceValue(capturedRole) : 0;
  if (movedValue - capturedValue < 2) return false;

  final after = position.playUnchecked(move);
  final attackers = after.board.attacksTo(move.to, piece.color.opposite);
  if (attackers.isEmpty) return false;
  final defenders = after.board.attacksTo(move.to, piece.color);
  final cheapestAttacker = attackers.squares
      .map((square) => _pieceValue(after.board.roleAt(square) ?? Role.king))
      .reduce(math.min);
  return defenders.isEmpty || cheapestAttacker < movedValue;
}

int _pieceValue(Role role) => switch (role) {
  Role.pawn => 1,
  Role.knight => 3,
  Role.bishop => 3,
  Role.rook => 5,
  Role.queen => 9,
  Role.king => 100,
};

/// The winning chances of a side, from 0 to 100.
double _winPercent(double winningChances) => 50 + 50 * winningChances;

/// The accuracy of a move, from 0 to 100, as computed by lichess.
///
/// See https://lichess.org/page/accuracy
double moveAccuracy(double winPercentBefore, double winPercentAfter) {
  if (winPercentAfter >= winPercentBefore) return 100;
  final loss = winPercentBefore - winPercentAfter;
  final raw = 103.1668 * math.exp(-0.04354 * loss) - 3.1669;
  return raw.clamp(0, 100).toDouble();
}

/// The accuracy of a game, from 0 to 100: the average of the arithmetic and harmonic means of the
/// accuracies of its moves, a simplification of the lichess formula.
double? gameAccuracy(List<double> moveAccuracies) {
  if (moveAccuracies.isEmpty) return null;
  final mean = moveAccuracies.reduce((a, b) => a + b) / moveAccuracies.length;
  final harmonic =
      moveAccuracies.length / moveAccuracies.map((a) => 1 / math.max(a, 1)).reduce((a, b) => a + b);
  return (mean + harmonic) / 2;
}
