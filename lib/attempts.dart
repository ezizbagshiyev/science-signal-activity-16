import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

class AttemptRepository {
  CollectionReference<Map<String, dynamic>> attempts(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('attempts');

  Map<String, dynamic> fields(int score) => {
    'schemaVersion': 1,
    'variant': 'B',
    'categoryId': 17,
    'questionCount': 5,
    'correctCount': score,
  };

  bool matches(Map<String, dynamic> data, Map<String, dynamic> expected) =>
      expected.entries.every(
        (entry) =>
            data[entry.key] == entry.value &&
            (entry.value is! int || data[entry.key] is int),
      );

  Future<void> commit(String uid, String id, int score) async {
    final ref = attempts(uid).doc(id);
    final expected = fields(score);
    final payload = {...expected, 'submittedAt': FieldValue.serverTimestamp()};
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      if (!snapshot.exists) {
        transaction.set(ref, payload);
      } else if (!matches(snapshot.data()!, expected)) {
        throw StateError(
          'Round ID collision. The existing record was preserved.',
        );
      }
    }, maxAttempts: 3);
  }

  Future<Map<String, dynamic>?> verify(
    String uid,
    String id, {
    int? score,
    String? fault,
  }) async {
    if (fault != null) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: fault,
        message: 'Development injection',
      );
    }
    final snapshot = await attempts(uid)
        .doc(id)
        .get(const GetOptions(source: Source.server));
    if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
      throw StateError('The read did not confirm a settled server record.');
    }
    if (!snapshot.exists) return null;
    final data = snapshot.data()!;
    final actual = data['correctCount'];
    if (data.length != 6 ||
        data['submittedAt'] is! Timestamp ||
        actual is! int ||
        actual < 0 ||
        actual > 5 ||
        !matches(data, fields(score ?? actual))) {
      throw StateError('The server record did not match the expected round.');
    }
    return data;
  }

  Future<String> probe(
    String uid,
    String id, {
    required bool crossOwner,
  }) async {
    final collection = attempts(uid);
    final existing = collection.doc(id);
    final results = <String>[];
    final valid = {...fields(2), 'submittedAt': FieldValue.serverTimestamp()};

    Future<void> check(String label, Future<void> Function() action) async {
      try {
        await action().timeout(const Duration(seconds: 10));
        results.add('$label: unexpectedly allowed');
      } on FirebaseException catch (error) {
        results.add('$label: ${error.code}');
      } on TimeoutException {
        results.add('$label: timeout');
      }
    }

    if (crossOwner) {
      await check('Cross-owner read', () async {
        await existing.get(const GetOptions(source: Source.server));
      });
      await check('Cross-owner create', () => collection.doc().set(valid));
    } else {
      await check(
        'Score 6',
        () => collection.doc().set({...valid, 'correctCount': 6}),
      );
      await check(
        'Extra field',
        () => collection.doc().set({...valid, 'unexpected': true}),
      );
      await check('Update', () => existing.update({'correctCount': 4}));
    }
    return results.join('\n');
  }
}
