import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attempts.dart';
import 'firebase_options.dart';
import 'trivia.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    runApp(const MaterialApp(title: 'Science Signal', home: Quiz()));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Firebase setup is required. See the project README.'),
          ),
        ),
      ),
    );
  }
}

enum Phase {
  signedOut,
  authError,
  idle,
  loading,
  requestError,
  playing,
  readyToSubmit,
  submitting,
  verifying,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
  cloudVerified,
  retrieving,
}

class Quiz extends StatefulWidget {
  const Quiz({super.key});
  @override
  State<Quiz> createState() => _QuizState();
}

class _QuizState extends State<Quiz> {
  final email = TextEditingController();
  final password = TextEditingController();
  final lookup = TextEditingController();
  final probeUid = TextEditingController();
  final trivia = TriviaRepository();
  final repository = AttemptRepository();
  late final StreamSubscription<User?> auth;
  String? uid, roundId, triviaFault, verificationFault;
  Phase phase = Phase.signedOut;
  String status = '';
  List<Question> questions = [];
  final answers = <String>[];
  int page = 0, session = 0;
  bool active = false, acknowledged = false;
  Map<String, dynamic>? verified;

  int get score => answers
      .asMap()
      .entries
      .where((answer) => answer.value == questions[answer.key].correct)
      .length;
  bool get unresolved => {
    Phase.submitting,
    Phase.verifying,
    Phase.saveUnknown,
    Phase.permissionDenied,
    Phase.verificationUnavailable,
  }.contains(phase);

  @override
  void initState() {
    super.initState();
    auth = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || user?.uid == uid) return;
      setState(() {
        session++;
        uid = user?.uid;
        active = false;
        status = '';
        lookup.clear();
        probeUid.clear();
        triviaFault = verificationFault = null;
        resetRound();
        phase = uid == null ? Phase.signedOut : Phase.idle;
      });
    });
  }

  @override
  void dispose() {
    unawaited(auth.cancel());
    email.dispose();
    password.dispose();
    lookup.dispose();
    probeUid.dispose();
    super.dispose();
  }

  void resetRound() {
    roundId = null;
    acknowledged = false;
    verified = null;
    questions = [];
    answers.clear();
    page = 0;
  }

  bool current(int generation, String? owner, [String? id]) =>
      mounted &&
      session == generation &&
      uid == owner &&
      FirebaseAuth.instance.currentUser?.uid == owner &&
      (id == null || id == roundId);

  String describe(Object error) {
    if (error is TimeoutException) return 'Timed out after 10 seconds.';
    if (error is FirebaseException) {
      return switch (error.code) {
        'permission-denied' => 'Permission denied.',
        'unavailable' => 'Cloud service unavailable.',
        'resource-exhausted' => 'Cloud quota exhausted.',
        'unauthenticated' => 'Authentication required.',
        _ => 'Firebase error: ${error.code}.',
      };
    }
    if (error is ArgumentError) return 'Invalid percent encoding.';
    return error.toString();
  }

  Future<void> signIn() async {
    if (active) return;
    setState(() {
      active = true;
      status = '';
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.text.trim(),
        password: password.text,
      );
      if (mounted) password.clear();
    } catch (error) {
      if (mounted && uid == null) {
        setState(() {
          phase = Phase.authError;
          status = describe(error);
        });
      }
    } finally {
      if (mounted && uid == null) setState(() => active = false);
    }
  }

  Future<void> load() async {
    final owner = uid;
    if (owner == null || active || unresolved) return;
    final generation = session;
    setState(() {
      resetRound();
      phase = Phase.loading;
      active = true;
      status = '';
    });
    try {
      final loaded = await trivia.load(fault: triviaFault);
      if (!current(generation, owner)) return;
      setState(() {
        questions = loaded;
        roundId = repository.attempts(owner).doc().id;
        phase = Phase.playing;
      });
    } catch (error) {
      if (current(generation, owner)) {
        setState(() {
          phase = Phase.requestError;
          status = describe(error);
        });
      }
    } finally {
      if (current(generation, owner)) setState(() => active = false);
    }
  }

  void answer(String value) {
    if (phase != Phase.playing || answers.length != page) return;
    setState(() => answers.add(value));
  }

  Future<void> save({bool reconcile = false}) async {
    final owner = uid;
    final id = roundId;
    if (owner == null || id == null || active || answers.length != 5) return;
    final generation = session;
    final frozenScore = score;
    bool valid() => current(generation, owner, id);
    setState(() {
      active = true;
      status = '';
      phase = reconcile ? Phase.verifying : Phase.submitting;
    });
    var checkingServer = reconcile;
    try {
      if (reconcile) {
        final record = await repository
            .verify(owner, id, score: frozenScore)
            .timeout(const Duration(seconds: 10));
        if (!valid()) return;
        if (record != null) {
          showVerified(record);
          return;
        }
        if (acknowledged) throw StateError('Acknowledged record is missing.');
        checkingServer = false;
        setState(() => phase = Phase.submitting);
      }
      final operation = repository.commit(owner, id, frozenScore);
      try {
        await operation.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        if (!valid()) return;
        setState(() {
          phase = Phase.saveUnknown;
          status = 'Save outcome unknown. Waiting for the original operation to settle.';
        });
        try {
          await operation;
        } catch (_) {
          // Reconciliation determines whether the exact document exists.
        }
        if (valid()) {
          setState(
            () =>
                status = 'Save outcome unknown. Reconcile the original round.',
          );
        }
        return;
      }
      if (!valid()) return;
      final fault = verificationFault;
      checkingServer = true;
      setState(() {
        acknowledged = true;
        verificationFault = null;
        phase = Phase.verifying;
      });
      final record = await repository
          .verify(owner, id, score: frozenScore, fault: fault)
          .timeout(const Duration(seconds: 10));
      if (!valid()) return;
      if (record == null) throw StateError('Acknowledged record is missing.');
      showVerified(record);
    } catch (error) {
      if (!valid()) return;
      final denied =
          error is FirebaseException && error.code == 'permission-denied';
      final injected =
          error is FirebaseException &&
          error.message == 'Development injection';
      setState(() {
        phase = denied
            ? Phase.permissionDenied
            : checkingServer
            ? Phase.verificationUnavailable
            : Phase.saveUnknown;
        final prefix = acknowledged
            ? 'Write acknowledged; verification unavailable.'
            : 'Save outcome unknown.';
        status =
            '$prefix ${describe(error)}${injected ? " (development injection)" : ""}';
      });
    } finally {
      if (valid()) setState(() => active = false);
    }
  }

  void showVerified(Map<String, dynamic> record) {
    setState(() {
      verified = record;
      phase = Phase.cloudVerified;
      status = 'Cloud verified';
    });
  }

  Future<void> retrieve() async {
    final owner = uid;
    final id = lookup.text.trim();
    if (owner == null || !RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(id)) {
      setState(() => status = 'Enter a 20-character round ID.');
      return;
    }
    final generation = session;
    setState(() {
      active = true;
      phase = Phase.retrieving;
      status = '';
    });
    try {
      final record = await repository
          .verify(owner, id)
          .timeout(const Duration(seconds: 10));
      if (!current(generation, owner)) return;
      if (record == null)
        throw StateError('No server record for this round ID.');
      setState(() => roundId = id);
      showVerified(record);
    } catch (error) {
      if (current(generation, owner)) {
        setState(() {
          phase = Phase.idle;
          status = describe(error);
        });
      }
    } finally {
      if (current(generation, owner)) setState(() => active = false);
    }
  }

  Future<void> probe({required bool crossOwner}) async {
    final owner = uid;
    final target = probeUid.text.trim();
    final id = lookup.text.trim();
    if (active ||
        owner == null ||
        target.isEmpty ||
        target.contains('/') ||
        !RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(id) ||
        (crossOwner ? target == owner : target != owner)) {
      setState(
        () => status = 'Use the appropriate owner UID and a verified round ID.',
      );
      return;
    }
    final generation = session;
    setState(() {
      active = true;
      status = 'Running development rules probe.';
    });
    try {
      final result = await repository.probe(target, id, crossOwner: crossOwner);
      if (current(generation, owner)) setState(() => status = result);
    } finally {
      if (current(generation, owner)) setState(() => active = false);
    }
  }

  Widget button(String text, VoidCallback? action) =>
      FilledButton(onPressed: action, child: Text(text));

  Widget faultPicker(
    String label,
    List<String> values,
    String? selected,
    ValueChanged<String?> update,
  ) => DropdownButton<String>(
    hint: Text(label),
    value: selected,
    onChanged: active
        ? null
        : (value) => setState(() => update(value == '' ? null : value)),
    items: ['', ...values]
        .map(
          (value) => DropdownMenuItem(
            value: value,
            child: Text(value.isEmpty ? 'No injection' : value),
          ),
        )
        .toList(),
  );

  List<Widget> content() {
    if (uid == null) {
      return [
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        TextField(
          controller: password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        button('Sign in', active ? null : signIn),
      ];
    }
    if (phase == Phase.playing) {
      final question = questions[page];
      final selected = answers.length > page;
      final correct = selected && answers[page] == question.correct;
      return [
        Text('Question ${page + 1} of 5'),
        LinearProgressIndicator(value: answers.length / 5),
        Text(question.prompt, style: Theme.of(context).textTheme.headlineSmall),
        for (final option in ['True', 'False'])
          button(option, selected ? null : () => answer(option)),
        if (selected)
          Text(
            correct ? 'Correct' : 'Incorrect. Answer: ${question.correct}',
            style: TextStyle(
              color: correct ? Colors.green.shade800 : Colors.red.shade800,
            ),
          ),
        button(
          page == 4 ? 'Review' : 'Continue',
          selected
              ? () => setState(() {
                  if (page == 4) {
                    phase = Phase.readyToSubmit;
                  } else {
                    page++;
                  }
                })
              : null,
        ),
      ];
    }
    if (answers.length == 5 || verified != null) {
      return [
        if (answers.length == 5) ...[
          Text(
            'Score $score / 5',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          for (var i = 0; i < questions.length; i++)
            ListTile(
              title: Text(questions[i].prompt),
              subtitle: Text(
                'Selected ${answers[i]} · Correct ${questions[i].correct}',
              ),
            ),
        ],
        SelectableText('Round ID: $roundId'),
        if (verified != null)
          Text(
            'Server score: ${verified!["correctCount"]} / 5\n'
            'Server timestamp: ${verified!["submittedAt"].toDate().toUtc()}',
          ),
        if (phase == Phase.readyToSubmit) ...[
          if (kDebugMode)
            faultPicker(
              'Development verification injection',
              ['permission-denied', 'unavailable', 'resource-exhausted'],
              verificationFault,
              (value) => verificationFault = value,
            ),
          button('Submit', active ? null : save),
        ],
        if (unresolved)
          button(
            acknowledged ? 'Retry verification' : 'Reconcile original round',
            active ? null : () => save(reconcile: true),
          ),
        button('Replay', unresolved || active ? null : load),
      ];
    }
    return [
      if (kDebugMode)
        faultPicker(
          'Development trivia injection',
          ['encoding', 'api code', 'four results'],
          triviaFault,
          (value) => triviaFault = value,
        ),
      button(
        phase == Phase.requestError ? 'Retry questions' : 'Start round',
        active ? null : load,
      ),
      TextField(
        controller: lookup,
        decoration: const InputDecoration(labelText: 'Previous round ID'),
      ),
      button('Retrieve server record', active ? null : retrieve),
      if (kDebugMode) ...[
        TextField(
          controller: probeUid,
          decoration: const InputDecoration(
            labelText: 'Development probe target UID',
          ),
        ),
        button(
          'Probe cross-owner rules',
          active ? null : () => probe(crossOwner: true),
        ),
        button(
          'Probe schema and immutability',
          active ? null : () => probe(crossOwner: false),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Science Signal'),
      actions: [
        if (uid != null)
          TextButton(
            onPressed: active || unresolved
                ? null
                : () => FirebaseAuth.instance.signOut(),
            child: const Text('Sign out'),
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (uid != null)
          SelectableText(
            'Signed in as ${FirebaseAuth.instance.currentUser?.email ?? uid}',
          ),
        if (active) const LinearProgressIndicator(),
        if (status.isNotEmpty)
          ListTile(
            leading: Icon(
              phase == Phase.cloudVerified
                  ? Icons.cloud_done
                  : Icons.info_outline,
            ),
            title: Text(status),
          ),
        for (final widget in content())
          Padding(padding: const EdgeInsets.only(bottom: 12), child: widget),
      ],
    ),
  );
}
