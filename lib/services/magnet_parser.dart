class MagnetInfo {
  final String rawUrl;
  final String? infoHash;
  final String? displayName;
  final List<String> trackers;
  final int? size;

  const MagnetInfo({
    required this.rawUrl,
    this.infoHash,
    this.displayName,
    this.trackers = const [],
    this.size,
  });

  String get shortHash {
    if (infoHash == null) return '';
    if (infoHash!.length <= 12) return infoHash!;
    return '${infoHash!.substring(0, 6)}...${infoHash!.substring(infoHash!.length - 6)}';
  }

  static MagnetInfo? parse(String url) {
    if (!url.startsWith('magnet:')) return null;

    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final params = uri.queryParametersAll;

    String? infoHash;
    final xt = params['xt'];
    if (xt != null && xt.isNotEmpty) {
      final xtVal = xt.first;
      if (xtVal.startsWith('urn:btih:')) {
        infoHash = xtVal.substring('urn:btih:'.length);
      } else if (xtVal.startsWith('urn:btmh:')) {
        infoHash = xtVal.substring('urn:btmh:'.length);
      }
    }

    final dn = params['dn'];
    final displayName = (dn != null && dn.isNotEmpty) ? dn.first : null;

    final tr = params['tr'] ?? [];

    int? size;
    final xl = params['xl'];
    if (xl != null && xl.isNotEmpty) {
      size = int.tryParse(xl.first);
    }

    return MagnetInfo(
      rawUrl: url,
      infoHash: infoHash,
      displayName: displayName,
      trackers: tr,
      size: size,
    );
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
