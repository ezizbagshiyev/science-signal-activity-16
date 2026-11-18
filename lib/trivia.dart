import 'dart:convert';

import 'package:http/http.dart' as http;

import 'question.dart';

export 'question.dart';

const triviaUrl =
    'https://opentdb.com/api.php?amount=5&category=17&difficulty=medium&type=boolean&encode=url3986';

class TriviaRepository {
  final Stopwatch _sinceRequest = Stopwatch();

  Future<List<Question>> load({String? fault}) async {
    if (_sinceRequest.isRunning && _sinceRequest.elapsedMilliseconds < 5000) {
      throw StateError('Wait five seconds between trivia requests.');
    }
    _sinceRequest
      ..reset()
      ..start();
    if (fault != null) {
      final row = {
        'category': 'Science%20%26%20Nature',
        'difficulty': 'medium',
        'type': 'boolean',
        'question': fault == 'encoding' ? '%ZZ' : 'Test',
        'correct_answer': 'True',
        'incorrect_answers': ['False'],
      };
      return parseQuestions(
        jsonEncode({
          'response_code': fault == 'api code' ? 1 : 0,
          'results': List.filled(fault == 'four results' ? 4 : 5, row),
        }),
      );
    }
    final response = await http
        .get(Uri.parse(triviaUrl))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw FormatException(
        'Trivia server returned HTTP ${response.statusCode}.',
      );
    }
    return parseQuestions(utf8.decode(response.bodyBytes));
  }
}
