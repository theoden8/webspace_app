import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';

Uint8List _png(int width) =>
    Uint8List.fromList(image.encodePng(image.Image(width: width, height: 2)));

void main() {
  test('sites look alike when they show the same icon: the same picked one, or '
      'none picked and the same host (WEBSPACE-014)', () {
    final mailA = WebViewModel(initUrl: 'https://mail.example.test/u/0');
    final mailB = WebViewModel(initUrl: 'https://mail.example.test/u/1');
    final www = WebViewModel(initUrl: 'https://www.docs.example.test');
    final bare = WebViewModel(initUrl: 'https://docs.example.test/start');
    final other = WebViewModel(initUrl: 'https://other.example.test');
    final pickedA = WebViewModel(
      initUrl: 'https://one.example.test',
      customIconPng: _png(3),
    );
    final pickedB = WebViewModel(
      initUrl: 'https://two.example.test',
      customIconPng: _png(3),
    );
    final pickedOwn = WebViewModel(
      initUrl: 'https://mail.example.test',
      customIconPng: _png(4),
    );
    final fileA = WebViewModel(initUrl: 'file:///notes.html');
    final fileB = WebViewModel(initUrl: 'file:///recipes.html');
    expect(
      sitesSharingAnIcon([
        mailA,
        mailB,
        www,
        bare,
        other,
        pickedA,
        pickedB,
        pickedOwn,
        fileA,
        fileB,
      ]),
      {
        mailA.siteId,
        mailB.siteId,
        www.siteId,
        bare.siteId,
        pickedA.siteId,
        pickedB.siteId,
      },
      reason:
          'a picked icon is its own, whatever the host; sites with no host '
          'are not alike by it',
    );
    expect(sitesSharingAnIcon([mailA, other]), isEmpty);
  });
}
