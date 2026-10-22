import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'route_export_stub.dart'
    if (dart.library.html) 'route_export_web.dart';

/// Hands a generated report file to the user: a normal browser download on the web, the share
/// sheet on Android (save to Files or Drive, open in Excel or Sheets, or send by e-mail).
class ReportFileSaver {
  static const String xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  /// Returns false only when the platform refused the file.
  static Future<bool> save(Uint8List bytes, String fileName, String mimeType, {String? subject}) async {
    if (kIsWeb) {
      downloadWebFile(bytes, fileName, mimeType);
      return true;
    }
    final ShareResult r = await SharePlus.instance.share(ShareParams(
      files: <XFile>[XFile.fromData(bytes, mimeType: mimeType, name: fileName)],
      fileNameOverrides: <String>[fileName],
      subject: subject,
    ));
    return r.status != ShareResultStatus.unavailable;
  }
}
