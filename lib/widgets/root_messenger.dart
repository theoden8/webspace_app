import 'package:flutter/material.dart';

/// Global key for the root [ScaffoldMessenger] so snackbars can be shown from
/// contexts that may be deactivating (e.g. immediately after popping a route).
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
