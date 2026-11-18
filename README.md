# Science Signal · Activity 16 Class B

Android Flutter quiz using Open Trivia Database, Firebase Authentication, and Cloud Firestore. This source snapshot needs a Firebase project configuration and deployed rules before it can demonstrate cloud behavior.

## Configure and build

1. Use an approved or dedicated Firebase project. Create a Standard Native Firestore database in production mode, enable Email/Password authentication, and create test accounts A and B.
2. From this directory run `flutter pub get`, `firebase login`, and `dart pub global activate flutterfire_cli`. Run `flutterfire configure --platforms=android --android-package-name=edu.gsu.bagshiyev.science_signal` and select the matching project. Allow it to replace the checked-in setup placeholder.
3. Run `firebase deploy --only firestore:rules --project YOUR_PROJECT_ID` against the dedicated project. Keep test passwords out of Git, recordings, and screenshots.
4. Run `flutter analyze` and `flutter run` on Android. Run `flutter build apk --release`, install-test the resulting release APK, and rename it to `ICA16_B_Eziz_Bagshiyev.apk`.
5. Commit the configured source and dependencies to a repository the instructor can access. Share test-account access only through an approved private channel.

## Walkthrough

Sign in as A, start a round, complete all questions, and select Submit. Compare the displayed round ID, score, and UTC timestamp with the same document in the Firestore console. Restart the app, sign in as A if prompted, and paste that ID into Previous round ID. The retrieval uses the server directly.

Use a debug build for fault injection. For the permission-denied experiment, select that fault after answering all five questions. Submit runs the real transaction first. The first verification then injects a denial and clears the fault. Retry verification reads the same ID from the real server. The unavailable and resource-exhausted injections follow the same procedure. For an offline submission, disconnect after answering five questions, tap Submit, reconnect, and use Reconcile original round.

The debug rules probe runs quiet authenticated client requests under the signed-in identity. For T10, sign in as B, enter A's UID and verified ID, and run the cross-owner probe. For T11, sign in as A and enter A's UID and original verified ID. Probe results show each actual outcome. The write probe uses a fresh generated ID for cross-owner or invalid create attempts. If a write unexpectedly succeeds, keep the result as evidence of a rules failure. Never run probes against a shared production project.

Use the evidence document to record and attach actual results. No live Firebase evidence is included in this source snapshot.
