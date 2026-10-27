import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An accepted connection as macOS hands over one whose peer reset it before
/// it was served: reads and writes reach the real socket, but the platform
/// refuses a socket option with EINVAL.
class OptionRefusingSocket extends StreamView<Uint8List> implements Socket {
  OptionRefusingSocket(this._real) : super(_real);

  final Socket _real;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      throw const OSError('Invalid argument', 22);

  @override
  Encoding get encoding => _real.encoding;

  @override
  set encoding(Encoding value) => _real.encoding = value;

  @override
  InternetAddress get address => _real.address;

  @override
  int get port => _real.port;

  @override
  InternetAddress get remoteAddress => _real.remoteAddress;

  @override
  int get remotePort => _real.remotePort;

  @override
  Future<void> get done => _real.done;

  @override
  void destroy() => _real.destroy();

  @override
  Uint8List getRawOption(RawSocketOption option) => _real.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _real.setRawOption(option);

  @override
  void add(List<int> data) => _real.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _real.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _real.addStream(stream);

  @override
  Future<void> flush() => _real.flush();

  @override
  Future<void> close() => _real.close();

  @override
  void write(Object? object) => _real.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _real.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _real.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _real.writeln(object);
}

/// A listening socket whose first [refusing] connections are
/// [OptionRefusingSocket]s, the rest the real ones.
class OptionRefusingServer extends StreamView<Socket> implements ServerSocket {
  OptionRefusingServer(this._real, {required int refusing})
      : super(_real.map((s) => refusing-- > 0 ? OptionRefusingSocket(s) : s));

  final ServerSocket _real;

  @override
  InternetAddress get address => _real.address;

  @override
  int get port => _real.port;

  @override
  Future<ServerSocket> close() => _real.close();
}
