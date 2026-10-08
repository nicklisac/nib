import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:nib/agent/approval_manager.dart';
import 'package:test/test.dart';

void main() {
  group('ApprovalManager Test Suite', () {
    late ApprovalManager manager;

    setUp(() {
      manager = ApprovalManager.instance;
      manager.requireConfirmation = true;
      manager.confirmAllCommands = false;
      manager.keyReader = null;
    });

    tearDown(() {
      manager.requireConfirmation = false;
      manager.confirmAllCommands = false;
      manager.keyReader = null;
    });

    group('isDestructiveBashCommand regex policy', () {
      test('identifies destructive system commands', () {
        expect(
          ApprovalManager.isDestructiveBashCommand('rm -rf /tmp/test'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand(
            'mv important.txt backup.txt',
          ),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand(
            'dd if=/dev/zero of=/dev/sda',
          ),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('mkfs.ext4 /dev/sdb1'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('truncate -s 0 log.txt'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('chmod 777 /var/www'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand(
            'chown root:root secret.key',
          ),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('kill -9 12345'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('pkill -f dart'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('sudo apt remove curl'),
          isTrue,
        );
        expect(ApprovalManager.isDestructiveBashCommand('su -'), isTrue);
      });

      test('identifies destructive git commands', () {
        expect(
          ApprovalManager.isDestructiveBashCommand('git reset --hard HEAD~1'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('git clean -fd'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('git checkout .'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('git restore .'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('git branch -D old-branch'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand(
            'git push origin main --force',
          ),
          isTrue,
        );
        expect(ApprovalManager.isDestructiveBashCommand('git push -f'), isTrue);
      });

      test('identifies destructive package publishing', () {
        expect(ApprovalManager.isDestructiveBashCommand('npm publish'), isTrue);
        expect(
          ApprovalManager.isDestructiveBashCommand('yarn publish'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('cargo publish'),
          isTrue,
        );
      });

      test('identifies redirection to sensitive system paths', () {
        expect(
          ApprovalManager.isDestructiveBashCommand('echo bad > /etc/passwd'),
          isTrue,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('cat data > /dev/sda'),
          isTrue,
        );
      });

      test('allows safe read-only or build commands', () {
        expect(ApprovalManager.isDestructiveBashCommand('git status'), isFalse);
        expect(
          ApprovalManager.isDestructiveBashCommand('git log -n 5'),
          isFalse,
        );
        expect(ApprovalManager.isDestructiveBashCommand('git diff'), isFalse);
        expect(ApprovalManager.isDestructiveBashCommand('ls -la'), isFalse);
        expect(
          ApprovalManager.isDestructiveBashCommand('cat README.md'),
          isFalse,
        );
        expect(ApprovalManager.isDestructiveBashCommand('dart test'), isFalse);
        expect(
          ApprovalManager.isDestructiveBashCommand('npm run build'),
          isFalse,
        );
        expect(
          ApprovalManager.isDestructiveBashCommand('grep -rn "TODO" .'),
          isFalse,
        );
      });
    });

    group('confirmBashCommand interaction', () {
      test('bypasses confirmation when requireConfirmation is false', () async {
        manager.requireConfirmation = false;
        final result = await manager.confirmBashCommand('rm -rf /');
        expect(result, isTrue);
      });

      test(
        'bypasses confirmation for non-destructive command when confirmAllCommands is false',
        () async {
          manager.requireConfirmation = true;
          manager.confirmAllCommands = false;
          final result = await manager.confirmBashCommand('ls -la');
          expect(result, isTrue);
        },
      );

      test('approves destructive command on explicit "y"', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.printable('y');

        final result = await manager.confirmBashCommand('rm temp.txt');
        expect(result, isTrue);
      });

      test('rejects destructive command on Escape key', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.control(ControlCharacter.escape);

        final result = await manager.confirmBashCommand('rm temp.txt');
        expect(result, isFalse);
      });

      test('rejects destructive command on "n"', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.printable('n');

        final result = await manager.confirmBashCommand('rm temp.txt');
        expect(result, isFalse);
      });

      test(
        'rejects destructive command on arbitrary unknown key or blank/tab/arrow',
        () async {
          manager.requireConfirmation = true;
          manager.keyReader = () async =>
              Key.control(ControlCharacter.arrowDown);

          final result = await manager.confirmBashCommand('rm temp.txt');
          expect(result, isFalse);
        },
      );

      test('fails closed in headless environment without keyReader', () async {
        manager.requireConfirmation = true;
        manager.keyReader = null;

        // In headless runner, stdout.hasTerminal is false, so it must fail closed
        if (!stdout.hasTerminal) {
          final result = await manager.confirmBashCommand('rm temp.txt');
          expect(result, isFalse);
        }
      });
    });

    group('confirmFileEdit interaction', () {
      test(
        'bypasses file edit confirmation when requireConfirmation is false',
        () async {
          manager.requireConfirmation = false;
          final result = await manager.confirmFileEdit(
            path: 'foo.dart',
            oldContent: 'old',
            newContent: 'new',
          );
          expect(result, isTrue);
        },
      );

      test('approves file edit on "y"', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.printable('y');

        final result = await manager.confirmFileEdit(
          path: 'foo.dart',
          oldContent: 'old',
          newContent: 'new',
        );
        expect(result, isTrue);
      });

      test('rejects file edit on Escape', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.control(ControlCharacter.escape);

        final result = await manager.confirmFileEdit(
          path: 'foo.dart',
          oldContent: 'old',
          newContent: 'new',
        );
        expect(result, isFalse);
      });

      test('rejects file edit on "n"', () async {
        manager.requireConfirmation = true;
        manager.keyReader = () async => Key.printable('n');

        final result = await manager.confirmFileEdit(
          path: 'foo.dart',
          oldContent: 'old',
          newContent: 'new',
        );
        expect(result, isFalse);
      });

      test('loops on "d" (diff) and then approves on "y"', () async {
        manager.requireConfirmation = true;
        var callCount = 0;
        manager.keyReader = () async {
          callCount++;
          if (callCount == 1) {
            return Key.printable('d');
          }
          return Key.printable('y');
        };

        final result = await manager.confirmFileEdit(
          path: 'foo.dart',
          oldContent: 'hello',
          newContent: 'hello world',
        );
        expect(result, isTrue);
        expect(callCount, equals(2));
      });
    });
  });
}
