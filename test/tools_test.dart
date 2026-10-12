import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:nib/tools/bash_tool.dart';
import 'package:nib/tools/edit_file_tool.dart';
import 'package:nib/tools/list_dir_tool.dart';
import 'package:nib/tools/read_file_tool.dart';
import 'package:nib/tools/search_files_tool.dart';
import 'package:nib/tools/write_file_tool.dart';

void main() {
  group('Agent Tools Test', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tau_dart_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'WriteFileTool creates file and ReadFileTool reads with line numbers',
      () async {
        final writeTool = WriteFileTool(workingDirectory: tempDir.path);
        final readTool = ReadFileTool(workingDirectory: tempDir.path);

        final writeRes = await writeTool.execute({
          'path': 'hello.txt',
          'content': 'Line 1\nLine 2\nLine 3',
        });
        expect(writeRes.content, contains('Successfully wrote 3 lines'));

        final readRes = await readTool.execute({
          'path': 'hello.txt',
          'start_line': 1,
          'end_line': 2,
        });
        expect(readRes.content, contains('1 | Line 1'));
        expect(readRes.content, contains('2 | Line 2'));
        expect(readRes.content, isNot(contains('Line 3')));
      },
    );

    test('EditFileTool replaces targeted block cleanly', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final editTool = EditFileTool(workingDirectory: tempDir.path);
      final readTool = ReadFileTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'code.txt',
        'content': 'hello world\nfoo bar\ngoodbye',
      });

      final editRes = await editTool.execute({
        'path': 'code.txt',
        'target_content': 'foo bar',
        'replacement_content': 'qux baz',
      });
      expect(editRes.content, contains('Successfully updated'));

      final readRes = await readTool.execute({'path': 'code.txt'});
      expect(readRes.content, contains('qux baz'));
      expect(readRes.content, isNot(contains('foo bar')));
    });

    test('ListDirTool lists directory contents', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final listTool = ListDirTool(workingDirectory: tempDir.path);

      await writeTool.execute({'path': 'a.txt', 'content': 'sample'});
      await writeTool.execute({'path': 'b.txt', 'content': 'sample 2'});

      final listRes = await listTool.execute({'path': '.'});
      expect(listRes.content, contains('a.txt'));
      expect(listRes.content, contains('b.txt'));
    });

    test('SearchFilesTool locates matching lines', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final searchTool = SearchFilesTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'search_sample.dart',
        'content': 'void main() {\n  print("Tau Agent");\n}',
      });

      final res = await searchTool.execute({'query': 'Tau Agent'});
      expect(
        res.content,
        contains('search_sample.dart:2: print("Tau Agent");'),
      );
    });

    test('BashTool runs command and captures output', () async {
      final bashTool = BashTool(workingDirectory: tempDir.path);

      final res = await bashTool.execute({'command': 'echo "Hello from Bash"'});
      expect(res.content, contains('Hello from Bash'));
    });

    test('ReadFileTool reads image files as multimodal ToolResult', () async {
      final readTool = ReadFileTool(workingDirectory: tempDir.path);

      final testImage = img.Image(width: 2, height: 2);
      final pngBytes = img.encodePng(testImage);

      final imgFile = File('${tempDir.path}/test_image.png');
      await imgFile.writeAsBytes(pngBytes);

      final res = await readTool.execute({'path': 'test_image.png'});
      expect(res.content, contains('Read image "test_image.png"'));
      expect(res.images, isNotNull);
      expect(res.images!.length, equals(1));
      expect(res.images!.first.mimeType, equals('image/png'));
      expect(res.images!.first.width, equals(2));
      expect(res.images!.first.height, equals(2));
    });

    test('Tools reject path traversal outside workspace directory', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final readTool = ReadFileTool(workingDirectory: tempDir.path);
      final editTool = EditFileTool(workingDirectory: tempDir.path);
      final listTool = ListDirTool(workingDirectory: tempDir.path);
      final searchTool = SearchFilesTool(workingDirectory: tempDir.path);

      expect(
        (await writeTool.execute({
          'path': '../evil.txt',
          'content': 'bad',
        })).content,
        contains('outside workspace'),
      );
      expect(
        (await readTool.execute({'path': '../evil.txt'})).content,
        contains('outside workspace'),
      );
      expect(
        (await editTool.execute({
          'path': '../evil.txt',
          'target_content': 'a',
          'replacement_content': 'b',
        })).content,
        contains('outside workspace'),
      );
      expect(
        (await listTool.execute({'path': '..'})).content,
        contains('outside workspace'),
      );
      expect(
        (await searchTool.execute({'path': '..', 'query': 'secret'})).content,
        contains('outside workspace'),
      );
    });
  });
}
