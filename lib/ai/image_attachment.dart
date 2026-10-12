import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Encapsulates a processed image attachment ready for model context.
class ImageAttachment {
  final String mimeType;
  final String base64Data;
  final int width;
  final int height;
  final String? originalPath;

  const ImageAttachment({
    required this.mimeType,
    required this.base64Data,
    required this.width,
    required this.height,
    this.originalPath,
  });

  Map<String, dynamic> toJson() => {
    'mime_type': mimeType,
    'base64_data': base64Data,
    'width': width,
    'height': height,
    if (originalPath != null) 'original_path': originalPath,
  };

  factory ImageAttachment.fromJson(Map<String, dynamic> json) =>
      ImageAttachment(
        mimeType: json['mime_type'] as String? ?? 'image/png',
        base64Data: json['base64_data'] as String? ?? '',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        originalPath: json['original_path'] as String?,
      );

  /// Sniffs the image format from magic bytes.
  static String? sniffMimeType(List<int> bytes) {
    if (bytes.length < 2) return null;

    // BMP: BM
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'image/bmp';
    }

    if (bytes.length < 4) return null;

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }

    // TIFF: II*. or MM.*
    if ((bytes[0] == 0x49 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x2A &&
            bytes[3] == 0x00) ||
        (bytes[0] == 0x4D &&
            bytes[1] == 0x4D &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x2A)) {
      return 'image/tiff';
    }

    // ICO: 00 00 01 00
    if (bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x01 &&
        bytes[3] == 0x00) {
      return 'image/x-icon';
    }

    if (bytes.length < 8) return null;

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }

    // GIF: GIF87a or GIF89a
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return 'image/gif';
    }

    if (bytes.length < 12) return null;

    // WEBP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    return null;
  }

  /// Processes raw image bytes: checks bounds, downsizes if > 2000px, converts BMP to PNG,
  /// and returns an [ImageAttachment].
  static Future<ImageAttachment?> processBytes(
    Uint8List rawBytes, {
    String? originalPath,
    int maxDimension = 2000,
    int maxBytes = 5 * 1024 * 1024, // 5 MB
  }) async {
    final mime = sniffMimeType(rawBytes);
    if (mime == null) return null;

    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) return null;

    var current = decoded;
    var outMime = mime;

    // Convert BMP to PNG
    if (mime == 'image/bmp') {
      outMime = 'image/png';
    }

    // Resize if width or height exceeds maxDimension (2000 px safe harbour)
    if (current.width > maxDimension || current.height > maxDimension) {
      if (current.width >= current.height) {
        current = img.copyResize(current, width: maxDimension);
      } else {
        current = img.copyResize(current, height: maxDimension);
      }
    }

    List<int> encodedBytes;
    if (outMime == 'image/jpeg') {
      encodedBytes = img.encodeJpg(current, quality: 85);
    } else {
      encodedBytes = img.encodePng(current);
      outMime = 'image/png';
    }

    // If still over 5 MB, step down quality / size
    if (encodedBytes.length > maxBytes) {
      var scale = 0.8;
      for (var attempt = 0; attempt < 5; attempt++) {
        final w = (current.width * scale).toInt();
        final h = (current.height * scale).toInt();
        if (w < 100 || h < 100) break;
        current = img.copyResize(current, width: w, height: h);
        encodedBytes = img.encodeJpg(current, quality: 75);
        outMime = 'image/jpeg';
        if (encodedBytes.length <= maxBytes) break;
        scale *= 0.8;
      }
    }

    final b64 = base64Encode(encodedBytes);
    return ImageAttachment(
      mimeType: outMime,
      base64Data: b64,
      width: current.width,
      height: current.height,
      originalPath: originalPath,
    );
  }

  /// Processes a local image file.
  static Future<ImageAttachment?> fromFile(File file) async {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return processBytes(bytes, originalPath: file.path);
  }

  /// Formats this attachment into OpenAI image_url content block.
  Map<String, dynamic> toOpenAiBlock() => {
    'type': 'image_url',
    'image_url': {'url': 'data:$mimeType;base64,$base64Data'},
  };

  /// Formats this attachment into Anthropic image content block.
  Map<String, dynamic> toAnthropicBlock() => {
    'type': 'image',
    'source': {'type': 'base64', 'media_type': mimeType, 'data': base64Data},
  };

  /// Checks if a file path has a recognized image extension.
  static bool isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.tiff') ||
        lower.endsWith('.tif') ||
        lower.endsWith('.ico');
  }

  /// Attempts to grab an image from system clipboard (Tier 2).
  /// Supports Linux (wl-paste, xclip), macOS (pngpaste), and Windows (PowerShell).
  static Future<ImageAttachment?> fromClipboard() async {
    try {
      if (Platform.isLinux) {
        // Try wl-paste with standard image MIME types
        for (final target in ['image/png', 'image/jpeg', 'image/webp']) {
          try {
            final res = await Process.run('wl-paste', [
              '-t',
              target,
            ], stdoutEncoding: null);
            if (res.exitCode == 0 && res.stdout is List<int>) {
              final bytes = Uint8List.fromList(res.stdout as List<int>);
              if (bytes.isNotEmpty) {
                final att = await processBytes(
                  bytes,
                  originalPath: 'clipboard',
                );
                if (att != null) return att;
              }
            }
          } catch (_) {}
        }

        // Try xclip
        for (final target in ['image/png', 'image/jpeg']) {
          try {
            final res = await Process.run('xclip', [
              '-selection',
              'clipboard',
              '-t',
              target,
              '-o',
            ], stdoutEncoding: null);
            if (res.exitCode == 0 && res.stdout is List<int>) {
              final bytes = Uint8List.fromList(res.stdout as List<int>);
              if (bytes.isNotEmpty) {
                final att = await processBytes(
                  bytes,
                  originalPath: 'clipboard',
                );
                if (att != null) return att;
              }
            }
          } catch (_) {}
        }
        // Try wl-paste text/uri-list (when copying image files in file managers)
        try {
          final res = await Process.run('wl-paste', [
            '-t',
            'text/uri-list',
          ], stdoutEncoding: utf8);
          if (res.exitCode == 0 && res.stdout is String) {
            final lines = (res.stdout as String).split(RegExp(r'[\r\n]+'));
            for (final line in lines) {
              var uri = line.trim();
              if (uri.startsWith('file://')) {
                uri = Uri.decodeFull(uri.substring(7));
                final f = File(uri);
                if (isImageFile(uri) && await f.exists()) {
                  final att = await fromFile(f);
                  if (att != null) return att;
                }
              }
            }
          }
        } catch (_) {}
      } else if (Platform.isMacOS) {
        try {
          final tmpPath =
              '${Directory.systemTemp.path}/nib_clip_${DateTime.now().millisecondsSinceEpoch}.png';
          final res = await Process.run('pngpaste', [tmpPath]);
          final f = File(tmpPath);
          if (res.exitCode == 0 && await f.exists()) {
            final att = await fromFile(f);
            try {
              await f.delete();
            } catch (_) {}
            return att;
          }
        } catch (_) {}
      } else if (Platform.isWindows) {
        try {
          final tmpPath =
              '${Directory.systemTemp.path}\\nib_clip_${DateTime.now().millisecondsSinceEpoch}.png';
          final script =
              'Add-Type -AssemblyName System.Windows.Forms; '
              '\$img = [System.Windows.Forms.Clipboard]::GetImage(); '
              'if (\$img) { \$img.Save("$tmpPath", [System.Drawing.Imaging.ImageFormat]::Png) }';
          final res = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            script,
          ]);
          final f = File(tmpPath);
          if (res.exitCode == 0 && await f.exists()) {
            final att = await fromFile(f);
            try {
              await f.delete();
            } catch (_) {}
            return att;
          }
        } catch (_) {}
      }

      // If no raw image bytes found, check if clipboard text contains an image file path
      final text = await fromClipboardText();
      if (text != null && text.isNotEmpty) {
        var path = text.trim();
        if (path.startsWith('file://')) {
          try {
            path = Uri.decodeFull(path.substring(7));
          } catch (_) {}
        }
        if ((path.startsWith('"') && path.endsWith('"')) ||
            (path.startsWith("'") && path.endsWith("'"))) {
          path = path.substring(1, path.length - 1);
        }
        if (isImageFile(path)) {
          final f = File(path);
          if (await f.exists()) {
            final att = await fromFile(f);
            if (att != null) return att;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Attempts to grab plain text from system clipboard.
  static Future<String?> fromClipboardText() async {
    try {
      if (Platform.isLinux) {
        // Try wl-paste
        try {
          final res = await Process.run('wl-paste', [
            '-t',
            'text/plain',
          ], stdoutEncoding: utf8);
          if (res.exitCode == 0 && res.stdout is String) {
            final text = res.stdout as String;
            if (text.isNotEmpty) return text;
          }
        } catch (_) {}

        // Try xclip
        try {
          final res = await Process.run('xclip', [
            '-selection',
            'clipboard',
            '-o',
          ], stdoutEncoding: utf8);
          if (res.exitCode == 0 && res.stdout is String) {
            final text = res.stdout as String;
            if (text.isNotEmpty) return text;
          }
        } catch (_) {}
      } else if (Platform.isMacOS) {
        try {
          final res = await Process.run(
            'pbpaste',
            const [],
            stdoutEncoding: utf8,
          );
          if (res.exitCode == 0 && res.stdout is String) {
            final text = res.stdout as String;
            if (text.isNotEmpty) return text;
          }
        } catch (_) {}
      } else if (Platform.isWindows) {
        try {
          final res = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            'Get-Clipboard',
          ], stdoutEncoding: utf8);
          if (res.exitCode == 0 && res.stdout is String) {
            final text = res.stdout as String;
            if (text.isNotEmpty) return text;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// Scans [prompt] for image paths (Tier 1 & Tier 3: `@file`, raw file path, or `file://` URI).
  /// Extracts valid images and returns an [ImageExtractionResult].
  static Future<ImageExtractionResult> extractFromPrompt(String prompt) async {
    final pattern = RegExp(
      r'''(?:["'](?:file://)?([^"'\r\n\x1B]+\.(?:png|jpg|jpeg|gif|webp|bmp|tiff|tif|ico))["']|(?:@|file://)?([^\s\x1B\(\)\[\]"'`]+\.(?:png|jpg|jpeg|gif|webp|bmp|tiff|tif|ico)))''',
      caseSensitive: false,
    );

    final matches = pattern.allMatches(prompt);
    if (matches.isEmpty) {
      return ImageExtractionResult(cleanedPrompt: prompt, images: const []);
    }

    final images = <ImageAttachment>[];
    final processedPaths = <String>{};
    var cleaned = prompt;

    for (final match in matches) {
      var rawPath = (match.group(1) ?? match.group(2))!;
      // Strip file:// prefix if present
      if (rawPath.startsWith('file://')) {
        rawPath = rawPath.substring(7);
      }
      try {
        rawPath = Uri.decodeFull(rawPath);
      } catch (_) {}
      if (processedPaths.contains(rawPath)) continue;

      final file = File(rawPath);
      if (await file.exists()) {
        final attachment = await fromFile(file);
        if (attachment != null) {
          images.add(attachment);
          processedPaths.add(rawPath);
        }
      }
    }

    return ImageExtractionResult(cleanedPrompt: cleaned, images: images);
  }
}

/// Result of extracting image attachments from a user prompt.
class ImageExtractionResult {
  final String cleanedPrompt;
  final List<ImageAttachment> images;

  const ImageExtractionResult({
    required this.cleanedPrompt,
    required this.images,
  });
}
