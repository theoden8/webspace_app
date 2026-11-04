import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/bundled_notices_io.dart';

/// The libraries a Linux package bundles reach the licences page from the
/// notices the package carries (LICENSE-003): linux/install_notices.sh lays
/// out a built library's, a staged Debian package brings its own.
void main() {
  test(
    'a snap and a flatpak are read where each keeps its notices (LICENSE-003)',
    () {
      expect(
        bundledDocsDir(environment: {'SNAP': '/snap/webspace-app/33'}),
        '/snap/webspace-app/33/usr/share/doc',
      );
      expect(
        bundledDocsDir(
          environment: {'FLATPAK_ID': 'org.codeberg.theoden8.webspace'},
        ),
        '/app/share/doc',
      );
      expect(
        bundledDocsDir(environment: {'HOME': '/home/u'}),
        isNull,
        reason:
            'a tarball runs on the system libraries, whose notices are the system\'s',
      );
    },
  );

  group('the notices under a doc directory (LICENSE-003)', () {
    late Directory docs;
    setUp(
      () async =>
          docs = await Directory.systemTemp.createTemp('bundled-notices-'),
    );
    tearDown(() => docs.delete(recursive: true));

    Future<void> write(String rel, {required String text}) async {
      final file = File('${docs.path}/$rel');
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }

    test(
      'each library is one entry: its copyright, then every licence file beside it',
      () async {
        await write(
          'wpewebkit/copyright',
          text: 'Upstream-Name: WPE WebKit\nLicense: LGPL-2.1+\n',
        );
        await write(
          'wpewebkit/licences/Source/WebCore/LICENSE-LGPL-2.1',
          text: 'GNU LESSER GENERAL PUBLIC LICENSE\n',
        );
        await write(
          'wpewebkit/licences/COPYRIGHT-HOLDERS.txt',
          text: 'Copyright (C) 2015 Igalia S.L.\n',
        );
        await write(
          'libavif16/copyright',
          text: 'Upstream-Name: libavif\nLicense: BSD-2-Clause\n',
        );
        await write('README', text: 'not a library');
        await write('nodoc/changelog.gz', text: 'no copyright file');

        final notices = await bundledNoticesIn(docs: docs.path);
        expect(notices.map((n) => n.$1), [
          'libavif16 (bundled library)',
          'wpewebkit (bundled library)',
        ]);
        final webkit = notices.last.$2;
        expect(webkit, startsWith('Upstream-Name: WPE WebKit'));
        expect(
          webkit,
          contains(
            '--- Source/WebCore/LICENSE-LGPL-2.1 ---\n\nGNU LESSER GENERAL PUBLIC LICENSE',
          ),
        );
        expect(
          webkit,
          contains(
            '--- COPYRIGHT-HOLDERS.txt ---\n\nCopyright (C) 2015 Igalia S.L.',
          ),
        );
        expect(
          webkit.indexOf('COPYRIGHT-HOLDERS'),
          lessThan(webkit.indexOf('Source/WebCore')),
          reason: 'licence files come in path order',
        );
      },
    );

    test('nothing where there is no doc directory', () async {
      expect(await bundledNoticesIn(docs: null), isEmpty);
      expect(await bundledNoticesIn(docs: '${docs.path}/absent'), isEmpty);
    });
  });
}
