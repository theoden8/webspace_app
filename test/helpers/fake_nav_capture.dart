import 'dart:typed_data';

import 'package:webspace/services/nav_capture.dart';

/// A capture whose webview answers [bytes] (one byte when none is given),
/// running [onRead] during that await as a concurrent handler would, and
/// whose tab always still holds; what it saved is [saved].
final class FakeNavCapture implements NavCapture {
  FakeNavCapture({this.onRead, this.bytes});

  final void Function()? onRead;
  final Uint8List? bytes;
  final List<Uint8List> saved = [];

  @override
  Future<Uint8List?> read() async {
    onRead?.call();
    return bytes ?? Uint8List.fromList([1]);
  }

  @override
  bool stillHolds() => true;

  @override
  Future<bool> save(Uint8List bytes) async {
    saved.add(bytes);
    return true;
  }
}
