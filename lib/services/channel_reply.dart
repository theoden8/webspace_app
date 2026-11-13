import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// What a platform channel answered; every caller says what each case means.
sealed class ChannelReply<T> {
  const ChannelReply();
}

/// The handler ran and replied [value], null when it sent nothing.
final class Answered<T> extends ChannelReply<T> {
  const Answered(this.value);
  final T? value;
}

/// The handler ran and reported [error].
final class PlatformRefused<T> extends ChannelReply<T> {
  const PlatformRefused(this.error, {required this.stack});
  final PlatformException error;
  final StackTrace stack;
}

/// No handler answers this channel in this engine, as [error] says.
final class NoPlugin<T> extends ChannelReply<T> {
  const NoPlugin(this.error);
  final MissingPluginException error;
}

/// Each `invoke*Method` of [MethodChannel], its two failures as replies.
extension AskChannel on MethodChannel {
  Future<ChannelReply<T>> ask<T>(String method, {Object? arguments}) =>
      _reply(() => invokeMethod<T>(method, arguments));

  Future<ChannelReply<List<T>>> askList<T>(String method,
          {Object? arguments}) =>
      _reply(() => invokeListMethod<T>(method, arguments));

  Future<ChannelReply<Map<K, V>>> askMap<K, V>(String method,
          {Object? arguments}) =>
      _reply(() => invokeMapMethod<K, V>(method, arguments));
}

Future<ChannelReply<T>> _reply<T>(Future<T?> Function() call) async {
  try {
    return Answered<T>(await call());
  } on PlatformException catch (e, stack) {
    return PlatformRefused(e, stack: stack);
  } on MissingPluginException catch (e) {
    return NoPlugin(e);
  }
}
