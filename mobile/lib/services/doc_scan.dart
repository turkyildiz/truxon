import 'dart:io';
import 'dart:typed_data';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'diag.dart';

/// Tablet-day capture path: edge-detected, deskewed document scans instead of
/// raw photos, with on-device OCR so the text rides along with the upload.
/// Falls back to the plain camera if the scanner is unavailable — capture
/// must never be blocked by the fancy path failing.
class DocScan {
  static final ImagePicker _picker = ImagePicker();

  /// Scan (or photograph) one document. Returns image bytes + best-effort OCR
  /// text (empty string when OCR finds nothing or fails).
  static Future<({Uint8List bytes, String name, String ocrText})?> capture() async {
    String? path;
    try {
      final pages = await CunningDocumentScanner.getPictures(
        noOfPages: 1,
        isGalleryImportAllowed: false,
      );
      if (pages != null && pages.isNotEmpty) path = pages.first;
    } catch (e) {
      Diag.log('scan: scanner unavailable, falling back to camera: $e');
    }
    if (path == null) {
      final shot = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 2200,
      );
      if (shot == null) return null;
      path = shot.path;
    }

    final bytes = await File(path).readAsBytes();
    var ocr = '';
    try {
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final result = await recognizer.processImage(InputImage.fromFilePath(path));
      ocr = result.text;
      await recognizer.close();
    } catch (e) {
      Diag.log('scan: ocr failed (upload continues without text): $e');
    }
    final name = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
    return (bytes: bytes, name: name, ocrText: ocr);
  }
}
