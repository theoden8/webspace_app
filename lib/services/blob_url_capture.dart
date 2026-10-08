import 'package:webspace/services/page_js.dart';

/// The blob download of [blobUrl], evaluated in the main frame when
/// `onDownloadStartRequest` fires with scheme `blob:`, reporting under
/// [taskId].
String buildBlobDownloadIife({
  required String blobUrl,
  required String taskId,
  String? suggestedFilename,
}) =>
    PageJs.blobDownload.withConfig({
      'blobUrl': blobUrl,
      'suggestedFilename': suggestedFilename ?? '',
      'taskId': taskId,
    });
