/// The saved icon size of one site or webspace in the launcher.
enum LauncherItemSize {
  small,
  medium,
  large;

  static LauncherItemSize fromJson(Object? raw) =>
      values.where((size) => size.name == raw).firstOrNull ?? medium;
}
