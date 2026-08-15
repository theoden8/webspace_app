import 'dart:convert';

import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/microphone.dart';

typedef VirtualMicrophonePickResult
    = VirtualMediaPickResult<VirtualMicrophoneSource>;

/// Picks the audio clip a site is served in [MicrophoneAccessMode.virtual].
class VirtualMicrophoneService {
  /// Hard cap on the inlined source. The shim decodes the whole clip into an
  /// `AudioBuffer` up front (it has to, to loop it seamlessly), so the cap
  /// bounds both the persisted model JSON and the page's decoded PCM
  /// footprint. 8 MiB is a few minutes of compressed audio, well past what a
  /// looped microphone substitute needs.
  static const int maxBytes = 8 * 1024 * 1024;

  static const _audioExts = [
    'mp3',
    'm4a',
    'aac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'flac',
    'weba',
  ];

  static Future<VirtualMicrophonePickResult> pickSource() async {
    final outcome = await VirtualMediaPicker.pick(
      allowedExtensions: _audioExts,
      maxBytes: maxBytes,
    );
    if (outcome.cancelled) return const VirtualMicrophonePickResult.cancelled();
    if (outcome.error != null) {
      return VirtualMicrophonePickResult.error(outcome.error!);
    }
    final dataUrl =
        'data:${mimeForExtension(outcome.extension)};base64,'
        '${base64Encode(outcome.bytes!)}';
    return VirtualMicrophonePickResult.picked(VirtualMicrophoneSource(
      dataUrl: dataUrl,
      fileName: outcome.fileName,
    ));
  }

  /// MIME type for a picked extension. `decodeAudioData` sniffs the container
  /// itself, so this only has to be honest enough for the `data:` URL to be
  /// well-formed.
  static String mimeForExtension(String ext) {
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'opus':
        return 'audio/ogg; codecs=opus';
      case 'flac':
        return 'audio/flac';
      case 'weba':
        return 'audio/webm';
      default:
        return 'audio/mpeg';
    }
  }
}
