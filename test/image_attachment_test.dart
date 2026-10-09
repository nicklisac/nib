import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
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
  });
}
