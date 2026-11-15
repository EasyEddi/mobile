import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/game_stats/move_quality.dart';

void main() {
  group('whiteWinningChances', () {
    test('is 0 for an equal position and symmetric', () {
      expect(whiteWinningChances(cp: 0), 0.0);
      expect(whiteWinningChances(cp: 150), closeTo(-whiteWinningChances(cp: -150)!, 1e-9));
    });

    test('clamps centipawns and ranks mates above them', () {
      expect(whiteWinningChances(cp: 1000), whiteWinningChances(cp: 5000));
      expect(whiteWinningChances(mate: 1), greaterThan(whiteWinningChances(cp: 1000)!));
      expect(whiteWinningChances(mate: -1), lessThan(whiteWinningChances(cp: -1000)!));
    });

    test('is null without an eval', () {
      expect(whiteWinningChances(), isNull);
    });
  });

  group('isSacrifice', () {
    // After 1. Nc3 d5
    final position = Chess.fromSetup(
      Setup.parseFen('rnbqkbnr/ppp1pppp/8/3p4/8/2N5/PPPPPPPP/R1BQKBNR w KQkq - 0 2'),
    );

    test('a knight taking a pawn defended by the queen is a sacrifice', () {
      expect(isSacrifice(position, Move.parse('c3d5')!), isTrue);
    });

    test('a knight moving to a square nobody attacks is not a sacrifice', () {
      expect(isSacrifice(position, Move.parse('c3b5')!), isFalse);
    });

    test('a pawn move is never a sacrifice', () {
      expect(isSacrifice(position, Move.parse('e2e4')!), isFalse);
    });
  });

  group('classifyMoves', () {
    test('keeps the judgments of the server', () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5', 'Nf3', 'Nc6'],
        analysis: const [
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 25),
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 300, judgment: MoveQuality.blunder),
        ],
        pov: Side.black,
      );
      expect(result.qualities, [MoveQuality.best, MoveQuality.blunder]);
      expect(result.counts, {MoveQuality.best: 1, MoveQuality.blunder: 1});
    });

    test('the first plies are book moves', () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5', 'Nf3', 'Nc6'],
        analysis: const [
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 25),
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 300, judgment: MoveQuality.blunder),
        ],
        pov: Side.black,
        bookPlies: 2,
      );
      expect(result.qualities, [MoveQuality.book, MoveQuality.blunder]);
    });

    test("classifies the moves of the scholar's mate", () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5', 'Bc4', 'Nc6', 'Qh5', 'Nf6', 'Qxf7#'],
        analysis: const [
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 15),
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 0),
          PlyAnalysis(mate: 1, judgment: MoveQuality.blunder),
        ],
        pov: Side.white,
      );
      expect(result.qualities, [
        MoveQuality.best,
        MoveQuality.best,
        // Loses about 0.037 winning chances.
        MoveQuality.excellent,
        // Punishes the blunder of black.
        MoveQuality.great,
      ]);
      expect(result.accuracy, isNotNull);
      expect(result.accuracy, greaterThan(90));
    });

    test('judges the moves itself for a local analysis', () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5'],
        analysis: const [PlyAnalysis(cp: 20), PlyAnalysis(cp: 400)],
        pov: Side.black,
        computeJudgments: true,
      );
      expect(result.qualities, [MoveQuality.blunder]);
    });

    test('an only move found is great', () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5'],
        analysis: const [
          PlyAnalysis(cp: 20),
          PlyAnalysis(cp: 20, bestMove: 'e7e5', onlyMove: true),
        ],
        pov: Side.black,
        computeJudgments: true,
      );
      expect(result.qualities, [MoveQuality.great]);
    });

    test('a move without eval is not classified', () {
      final result = classifyMoves(
        initialPosition: Chess.initial,
        sanMoves: ['e4', 'e5', 'Nf3'],
        analysis: const [PlyAnalysis(cp: 20)],
        pov: Side.white,
      );
      expect(result.qualities, [MoveQuality.best, null]);
    });
  });

  group('moveAccuracy', () {
    test('is 100 when the move does not lose anything', () {
      expect(moveAccuracy(50, 50), 100);
      expect(moveAccuracy(50, 60), 100);
    });

    test('decreases with the loss', () {
      expect(moveAccuracy(50, 40), greaterThan(moveAccuracy(50, 20)));
      expect(moveAccuracy(100, 0), 0);
    });
  });

  test('gameAccuracy', () {
    expect(gameAccuracy([]), isNull);
    expect(gameAccuracy([100, 100]), 100);
    expect(gameAccuracy([100, 50]), lessThan(75));
  });
}
