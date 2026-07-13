// lib/upload/firebase_token_source.dart
//
// Cycle 10e — the real TokenSource. Returns the current user's Firebase ID token
// for the ingest API's Bearer header. Degrades GRACEFULLY: if Firebase isn't
// configured/initialized (google-services.json / GoogleService-Info.plist are
// pending from Person C) it returns '' with a warning — the app still launches
// and captures; uploads just get 401 until Firebase is wired.

import 'dart:developer' as developer;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../capture/ports.dart';

class FirebaseTokenSource implements TokenSource {
  const FirebaseTokenSource();

  @override
  Future<String> idToken() async {
    if (Firebase.apps.isEmpty) {
      developer.log(
        'Firebase not initialized — uploads will get 401 until configured.',
        name: 'auth',
      );
      return '';
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return '';
    return await user.getIdToken() ?? '';
  }
}
