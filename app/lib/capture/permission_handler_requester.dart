// lib/capture/permission_handler_requester.dart
//
// Cycle 10a — the real PermissionRequester, wrapping permission_handler. Device
// only; tests use FakePermissionRequester.

import 'package:permission_handler/permission_handler.dart';

import 'ports.dart';

class PermissionHandlerRequester implements PermissionRequester {
  const PermissionHandlerRequester();

  @override
  Future<bool> requestAudio() async =>
      (await Permission.microphone.request()).isGranted;

  @override
  Future<bool> requestLocation() async =>
      (await Permission.locationWhenInUse.request()).isGranted;
}
