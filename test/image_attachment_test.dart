import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:nib/ai/chat_message.dart';
import 'package:nib/ai/image_attachment.dart';

void main() {
  group('ImageAttachment Magic Byte Sniffing', () {
    test('sniffs PNG correctly', () {
      final bytes = [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
      ];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/png'));
    });

    test('sniffs JPEG correctly', () {
      final bytes = [
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0x00,
        0x01,
      ];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/jpeg'));
    });

    test('sniffs GIF correctly', () {
      final bytes = [
        0x47,
        0x49,
        0x46,
        0x38,
        0x39,
        0x61,
        0x01,
        0x00,
        0x01,
        0x00,
        0x80,
        0x00,
      ];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/gif'));
    });

    test('sniffs WEBP correctly', () {
      final bytes = [
        0x52,
        0x49,
        0x46,
        0x46,
        0x24,
        0x00,
        0x00,
        0x00,
        0x57,
        0x45,
        0x42,
        0x50,
      ];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/webp'));
    });

    test('sniffs BMP correctly', () {
      final bytes = [
        0x42,
        0x4D,
        0x36,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x36,
        0x00,
      ];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/bmp'));
    });

    test('returns null for short or invalid bytes', () {
      expect(ImageAttachment.sniffMimeType([1, 2, 3]), isNull);
      expect(ImageAttachment.sniffMimeType(List.filled(16, 0)), isNull);
    });
  });

  group('ImageAttachment Bounds, Downscaling, and Format Conversion', () {
    test(
      'downscales image exceeding 2000px max dimension proportionally',
      () async {
        final testImage = img.Image(width: 2400, height: 1200);
        final rawPng = Uint8List.fromList(img.encodePng(testImage));

        final attachment = await ImageAttachment.processBytes(rawPng);
        expect(attachment, isNotNull);
        expect(attachment!.width, equals(2000));
        expect(attachment.height, equals(1000));
        expect(attachment.mimeType, equals('image/png'));
      },
    );

    test('converts BMP to PNG', () async {
      final testImage = img.Image(width: 50, height: 50);
      final rawBmp = Uint8List.fromList(img.encodeBmp(testImage));

      final attachment = await ImageAttachment.processBytes(rawBmp);
      expect(attachment, isNotNull);
      expect(attachment!.mimeType, equals('image/png'));
      expect(attachment.width, equals(50));
      expect(attachment.height, equals(50));
    });

    test('preserves dimension if within 2000px', () async {
      final testImage = img.Image(width: 800, height: 600);
      final rawPng = Uint8List.fromList(img.encodePng(testImage));

      final attachment = await ImageAttachment.processBytes(rawPng);
      expect(attachment, isNotNull);
      expect(attachment!.width, equals(800));
      expect(attachment.height, equals(600));
    });
  });

  group('Provider Content Block Serialization', () {
    test('formats OpenAI image_url content block correctly', () async {
      final testImage = img.Image(width: 10, height: 10);
      final rawPng = Uint8List.fromList(img.encodePng(testImage));
      final attachment = (await ImageAttachment.processBytes(rawPng))!;

      final block = attachment.toOpenAiBlock();
      expect(block['type'], equals('image_url'));
      expect(block['image_url']['url'], startsWith('data:image/png;base64,'));
    });

    test('formats Anthropic image content block correctly', () async {
      final testImage = img.Image(width: 10, height: 10);
      final rawPng = Uint8List.fromList(img.encodePng(testImage));
      final attachment = (await ImageAttachment.processBytes(rawPng))!;

      final block = attachment.toAnthropicBlock();
      expect(block['type'], equals('image'));
      final source = block['source'] as Map<String, dynamic>;
      expect(source['type'], equals('base64'));
      expect(source['media_type'], equals('image/png'));
      expect(source['data'], isNotEmpty);
    });
  });

  group('Image Extraction from Prompt (Tiers 1 & 3)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nib_img_test_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'extracts @file mention and direct file path to existing images',
      () async {
        final imgFile = File('${tempDir.path}/screenshot.png');
        final image = img.Image(width: 100, height: 100);
        await imgFile.writeAsBytes(img.encodePng(image));

        final prompt = 'Please check @${imgFile.path} and analyze this bug';
        final result = await ImageAttachment.extractFromPrompt(prompt);

        expect(result.images.length, equals(1));
        expect(result.images.first.width, equals(100));
        expect(result.images.first.height, equals(100));
        expect(result.images.first.mimeType, equals('image/png'));
      },
    );

    test('ignores non-existent or non-image files in prompt', () async {
      final prompt = 'Look at nonexistent.png and @code.dart';
      final result = await ImageAttachment.extractFromPrompt(prompt);
      expect(result.images, isEmpty);
    });

    test('extracts quoted image paths and paths with spaces', () async {
      final imgFile = File('${tempDir.path}/my screenshot.png');
      final image = img.Image(width: 50, height: 50);
      await imgFile.writeAsBytes(img.encodePng(image));

      final promptDouble = '"${imgFile.path}"';
      final resDouble = await ImageAttachment.extractFromPrompt(promptDouble);
      expect(resDouble.images.length, equals(1));
      expect(resDouble.images.first.width, equals(50));

      final promptSingle = "'${imgFile.path}'";
      final resSingle = await ImageAttachment.extractFromPrompt(promptSingle);
      expect(resSingle.images.length, equals(1));
      expect(resSingle.images.first.width, equals(50));
    });
  });

  group('Standard Image Types and Serialization', () {
    test('sniffs TIFF correctly', () {
      final bytesLE = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00];
      final bytesBE = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08];
      expect(ImageAttachment.sniffMimeType(bytesLE), equals('image/tiff'));
      expect(ImageAttachment.sniffMimeType(bytesBE), equals('image/tiff'));
    });

    test('sniffs ICO correctly', () {
      final bytes = [0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x20, 0x20];
      expect(ImageAttachment.sniffMimeType(bytes), equals('image/x-icon'));
    });

    test('isImageFile identifies all standard image extensions', () {
      final valid = [
        'photo.png',
        'picture.jpg',
        'image.jpeg',
        'animation.gif',
        'graphic.webp',
        'bitmap.bmp',
        'scan.tiff',
        'scan2.tif',
        'favicon.ico',
      ];
      for (final path in valid) {
        expect(
          ImageAttachment.isImageFile(path),
          isTrue,
          reason: '$path should be image',
        );
      }

      final invalid = ['code.dart', 'readme.md', 'archive.tar', 'doc.pdf'];
      for (final path in invalid) {
        expect(
          ImageAttachment.isImageFile(path),
          isFalse,
          reason: '$path should not be image',
        );
      }
    });

    test('serializes and deserializes ImageAttachment to/from JSON', () {
      const att = ImageAttachment(
        mimeType: 'image/png',
        base64Data: 'iVBORw0KGgoAAAANSUhEUgAAAAIA...',
        width: 640,
        height: 480,
        originalPath: 'test/path.png',
      );

      final json = att.toJson();
      final restored = ImageAttachment.fromJson(json);

      expect(restored.mimeType, equals(att.mimeType));
      expect(restored.base64Data, equals(att.base64Data));
      expect(restored.width, equals(att.width));
      expect(restored.height, equals(att.height));
      expect(restored.originalPath, equals(att.originalPath));
    });

    test('ChatMessage.toolResult roundtrips images through JSON', () {
      const att = ImageAttachment(
        mimeType: 'image/png',
        base64Data: 'abcd1234',
        width: 100,
        height: 100,
      );

      final msg = ChatMessage.toolResult(
        toolCallId: 'call_1',
        toolName: 'read_file',
        content: 'Read image "foo.png" (100x100, image/png).',
        images: [att],
      );

      final json = msg.toJson();
      final restored = ChatMessage.fromJson(json);

      expect(restored.role, equals(Role.tool));
      expect(restored.toolCallId, equals('call_1'));
      expect(restored.toolName, equals('read_file'));
      expect(restored.content, equals(msg.content));
      expect(restored.images, isNotNull);
      expect(restored.images!.length, equals(1));
      expect(restored.images!.first.mimeType, equals('image/png'));
      expect(restored.images!.first.base64Data, equals('abcd1234'));

      // OpenAI formatting includes image_url block for tool role
      final openAi = msg.toOpenAiJson();
      expect(openAi['role'], equals('tool'));
      expect(openAi['content'], isA<List>());
      final parts = openAi['content'] as List;
      expect(parts.any((p) => p['type'] == 'image_url'), isTrue);
    });

    test('isImageFile identifies standard image extensions', () {
      expect(ImageAttachment.isImageFile('foo.png'), isTrue);
      expect(ImageAttachment.isImageFile('path/to/bar.jpeg'), isTrue);
      expect(ImageAttachment.isImageFile('test.jpg'), isTrue);
      expect(ImageAttachment.isImageFile('test.webp'), isTrue);
      expect(ImageAttachment.isImageFile('test.gif'), isTrue);
      expect(ImageAttachment.isImageFile('test.bmp'), isTrue);
      expect(ImageAttachment.isImageFile('test.tiff'), isTrue);
      expect(ImageAttachment.isImageFile('test.ico'), isTrue);
      expect(ImageAttachment.isImageFile('test.txt'), isFalse);
      expect(ImageAttachment.isImageFile('test.dart'), isFalse);
    });

    test('extractFromPrompt finds bare, quoted, and file:// paths', () async {
      final tmpDir = await Directory.systemTemp.createTemp('nib_extract_test_');
      try {
        final imgFile = File('${tmpDir.path}/test.png');
        final image = img.Image(width: 10, height: 10);
        await imgFile.writeAsBytes(img.encodePng(image));

        final res1 = await ImageAttachment.extractFromPrompt(
          'Check "${imgFile.path}" now',
        );
        expect(res1.images.length, equals(1));

        final res2 = await ImageAttachment.extractFromPrompt(
          'Check file://${imgFile.path} now',
        );
        expect(res2.images.length, equals(1));

        final res3 = await ImageAttachment.extractFromPrompt(
          'Check @${imgFile.path} now',
        );
        expect(res3.images.length, equals(1));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });
}
