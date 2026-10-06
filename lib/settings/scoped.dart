/// A per-site setting that either follows the app-wide one or holds its own
/// value. Stored as `T?`, null meaning "follow"; this type is how the UI
/// handles it, so "back to following the app" is a value a picker can offer
/// rather than a null a switch cannot produce.
sealed class Scoped<T extends Object> {
  const Scoped();

  factory Scoped.fromStored(T? stored) =>
      stored == null ? FollowApp<T>() : Own<T>(stored);

  /// The persisted form.
  T? get stored;

  T resolve(T appValue);
}

final class FollowApp<T extends Object> extends Scoped<T> {
  const FollowApp();

  @override
  T? get stored => null;

  @override
  T resolve(T appValue) => appValue;

  @override
  bool operator ==(Object other) => other is FollowApp<T>;

  @override
  int get hashCode => T.hashCode;
}

final class Own<T extends Object> extends Scoped<T> {
  const Own(this.value);

  final T value;

  @override
  T get stored => value;

  @override
  T resolve(T appValue) => value;

  @override
  bool operator ==(Object other) => other is Own<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);
}
