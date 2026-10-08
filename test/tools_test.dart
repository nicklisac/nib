import 'dart:io';
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
        expect(writeRes, contains('Successfully wrote 3 lines'));

        final readRes = await readTool.execute({
          'path': 'hello.txt',
          'start_line': 1,
          'end_line': 2,
        });
        expect(readRes, contains('1 | Line 1'));
        expect(readRes, contains('2 | Line 2'));
        expect(readRes, isNot(contains('Line 3')));
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
      expect(editRes, contains('Successfully updated'));

      final readRes = await readTool.execute({'path': 'code.txt'});
      expect(readRes, contains('qux baz'));
      expect(readRes, isNot(contains('foo bar')));
    });

    test('ListDirTool lists directory contents', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final listTool = ListDirTool(workingDirectory: tempDir.path);

      await writeTool.execute({'path': 'a.txt', 'content': 'sample'});
      await writeTool.execute({'path': 'b.txt', 'content': 'sample 2'});

      final listRes = await listTool.execute({'path': '.'});
      expect(listRes, contains('a.txt'));
      expect(listRes, contains('b.txt'));
    });

    test('SearchFilesTool locates matching lines', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final searchTool = SearchFilesTool(workingDirectory: tempDir.path);

      await writeTool.execute({
        'path': 'search_sample.dart',
        'content': 'void main() {\n  print("Tau Agent");\n}',
      });

      final res = await searchTool.execute({'query': 'Tau Agent'});
      expect(res, contains('search_sample.dart:2: print("Tau Agent");'));
    });

    test('BashTool runs command and captures output', () async {
      final bashTool = BashTool(workingDirectory: tempDir.path);

      final res = await bashTool.execute({'command': 'echo "Hello from Bash"'});
      expect(res, contains('Hello from Bash'));
    });

    test('Tools reject path traversal outside workspace directory', () async {
      final writeTool = WriteFileTool(workingDirectory: tempDir.path);
      final readTool = ReadFileTool(workingDirectory: tempDir.path);
      final editTool = EditFileTool(workingDirectory: tempDir.path);
      final listTool = ListDirTool(workingDirectory: tempDir.path);
      final searchTool = SearchFilesTool(workingDirectory: tempDir.path);

      expect(
        await writeTool.execute({'path': '../evil.txt', 'content': 'bad'}),
        contains('outside workspace'),
      );
      expect(
        await readTool.execute({'path': '../evil.txt'}),
        contains('outside workspace'),
      );
      expect(
        await editTool.execute({
          'path': '../evil.txt',
          'target_content': 'a',
          'replacement_content': 'b',
        }),
        contains('outside workspace'),
      );
      expect(
        await listTool.execute({'path': '..'}),
        contains('outside workspace'),
      );
      expect(
        await searchTool.execute({'path': '..', 'query': 'secret'}),
        contains('outside workspace'),
      );
    });
  });
}
