/// True in the F-Droid build. `flutter build --flavor fdroid` sets
/// `FLUTTER_APP_FLAVOR`.
const bool isFdroidFlavor =
    String.fromEnvironment('FLUTTER_APP_FLAVOR') == 'fdroid';
