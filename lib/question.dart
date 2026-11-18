import 'dart:convert';

class Question {
  const Question(this.prompt, this.correct);
  final String prompt;
  final String correct;
}

List<Question> parseQuestions(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map ||
      decoded['response_code'] != 0 ||
      decoded['results'] is! List ||
      (decoded['results'] as List).length != 5) {
    throw const FormatException('Expected five successful trivia results.');
  }
  return (decoded['results'] as List)
      .map((item) {
        if (item is! Map ||
            item['incorrect_answers'] is! List ||
            (item['incorrect_answers'] as List).length != 1) {
          throw const FormatException('Missing question or answers.');
        }
        String decode(Object? value) {
          if (value is! String) throw const FormatException('Expected text.');
          return Uri.decodeComponent(value);
        }

        final prompt = decode(item['question']);
        final correct = decode(item['correct_answer']);
        final wrong = decode((item['incorrect_answers'] as List).single);
        if (prompt.trim().isEmpty ||
            decode(item['category']) != 'Science & Nature' ||
            item['difficulty'] != 'medium' ||
            item['type'] != 'boolean' ||
            !{'True', 'False'}.containsAll([correct, wrong]) ||
            correct == wrong) {
          throw const FormatException(
            'Invalid science question or answer set.',
          );
        }
        return Question(prompt, correct);
      })
      .toList(growable: false);
}
