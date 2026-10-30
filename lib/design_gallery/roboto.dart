import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// CanvasKit pulls Roboto from fonts.gstatic.com; where that is unreachable it
/// draws no text at all. Serve it from web/fonts (see sync_fonts.js) instead.
Future<void> loadRoboto() async {
  const faces = ['Roboto_400Regular', 'Roboto_500Medium', 'Roboto_700Bold'];
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final face in faces) {
    try {
      // ignore: webspace_lints/raw_http_client
      final res = await http.get(Uri.parse('fonts/$face.ttf'));
      if (res.statusCode != 200) continue;
      loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
      loaded++;
    } on http.ClientException {
      // The face is missing from this build; the rest still load.
    }
  }
  if (loaded > 0) await loader.load();
}
