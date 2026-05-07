import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/magnet_parser.dart';

void main() {
  group('MagnetInfo.parse', () {
    test('parses full magnet link with all fields', () {
      final url = 'magnet:?xt=urn:btih:abc123def456&dn=My+File.iso'
          '&xl=1073741824&tr=udp://tracker.example.com:6969';
      final info = MagnetInfo.parse(url)!;
      expect(info.infoHash, 'abc123def456');
      expect(info.displayName, 'My File.iso');
      expect(info.size, 1073741824);
      expect(info.trackers, ['udp://tracker.example.com:6969']);
    });

    test('parses btmh hash variant', () {
      final url = 'magnet:?xt=urn:btmh:1220abc123';
      final info = MagnetInfo.parse(url)!;
      expect(info.infoHash, '1220abc123');
    });

    test('parses multiple trackers', () {
      final url = 'magnet:?xt=urn:btih:abc123'
          '&tr=udp://tracker1.com:6969'
          '&tr=udp://tracker2.com:6969'
          '&tr=http://tracker3.com/announce';
      final info = MagnetInfo.parse(url)!;
      expect(info.trackers.length, 3);
    });

    test('handles missing display name', () {
      final url = 'magnet:?xt=urn:btih:abc123';
      final info = MagnetInfo.parse(url)!;
      expect(info.displayName, isNull);
    });

    test('handles missing size', () {
      final url = 'magnet:?xt=urn:btih:abc123&dn=Test';
      final info = MagnetInfo.parse(url)!;
      expect(info.size, isNull);
    });

    test('handles missing trackers', () {
      final url = 'magnet:?xt=urn:btih:abc123';
      final info = MagnetInfo.parse(url)!;
      expect(info.trackers, isEmpty);
    });

    test('handles missing hash', () {
      final url = 'magnet:?dn=NoHash';
      final info = MagnetInfo.parse(url)!;
      expect(info.infoHash, isNull);
      expect(info.displayName, 'NoHash');
    });

    test('returns null for non-magnet URLs', () {
      expect(MagnetInfo.parse('https://example.com'), isNull);
      expect(MagnetInfo.parse('http://example.com'), isNull);
      expect(MagnetInfo.parse(''), isNull);
    });

    test('preserves raw URL', () {
      final url = 'magnet:?xt=urn:btih:abc';
      final info = MagnetInfo.parse(url)!;
      expect(info.rawUrl, url);
    });
  });

  group('MagnetInfo.shortHash', () {
    test('truncates long hashes', () {
      final info = MagnetInfo(
        rawUrl: '',
        infoHash: 'abcdef1234567890abcdef1234567890abcdef12',
      );
      expect(info.shortHash, 'abcdef...cdef12');
      expect(info.shortHash.length, 15);
    });

    test('returns short hashes unchanged', () {
      final info = MagnetInfo(rawUrl: '', infoHash: 'abc123');
      expect(info.shortHash, 'abc123');
    });

    test('returns empty for null hash', () {
      final info = MagnetInfo(rawUrl: '');
      expect(info.shortHash, '');
    });
  });

  group('MagnetInfo.formatSize', () {
    test('formats bytes', () {
      expect(MagnetInfo.formatSize(512), '512 B');
    });

    test('formats kilobytes', () {
      expect(MagnetInfo.formatSize(1536), '1.5 KB');
    });

    test('formats megabytes', () {
      expect(MagnetInfo.formatSize(10485760), '10.0 MB');
    });

    test('formats gigabytes', () {
      expect(MagnetInfo.formatSize(1073741824), '1.00 GB');
    });

    test('formats large sizes', () {
      expect(MagnetInfo.formatSize(4831838208), '4.50 GB');
    });
  });
}
