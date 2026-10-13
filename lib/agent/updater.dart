import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool isUpdateAvailable;
  final String? releaseUrl;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.isUpdateAvailable,
    this.releaseUrl,
  });
}

/// Manages version checks and standalone binary updates.
class NibUpdater {
  static const currentVersion = '0.2.5';
  static const repo = 'nicklisac/nib';

  /// Non-blocking check with 12-hour local caching to ensure zero latency at launch.
  static Future<UpdateInfo?> checkForUpdateCached({bool force = false}) async {
    try {
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isEmpty) return null;

      final cacheDir = Directory(p.join(home, '.nib'));
      final cacheFile = File(p.join(cacheDir.path, 'update_check.json'));

      if (!force && await cacheFile.exists()) {
        try {
          final content = await cacheFile.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          final checkedAt = DateTime.tryParse(
            data['checked_at'] as String? ?? '',
          );
          if (checkedAt != null &&
              DateTime.now().difference(checkedAt).inHours < 12) {
            final latest = data['latest_version'] as String? ?? '';
            if (latest.isNotEmpty) {
              return UpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latest,
                isUpdateAvailable: _isNewer(currentVersion, latest),
                releaseUrl: data['release_url'] as String?,
              );
            }
          }
        } catch (_) {}
      }

      // Query GitHub API
      final url = Uri.parse(
        'https://api.github.com/repos/$repo/releases/latest',
      );
      final headers = _githubHeaders();
      final res = await http
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 3));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final rawTag = data['tag_name'] as String? ?? '';
        final latest = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
        final htmlUrl = data['html_url'] as String?;

        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        await cacheFile.writeAsString(
          jsonEncode({
            'checked_at': DateTime.now().toIso8601String(),
            'latest_version': latest,
            'release_url': htmlUrl,
          }),
        );

        return UpdateInfo(
          currentVersion: currentVersion,
          latestVersion: latest,
          isUpdateAvailable: _isNewer(currentVersion, latest),
          releaseUrl: htmlUrl,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Performs in-place binary update by downloading the release asset for the current OS/architecture.
  static Future<void> performSelfUpdate({
    void Function(String message)? onProgress,
  }) async {
    final target = _detectPlatformArch();
    if (target == null) {
      throw UnsupportedError('Unsupported operating system or architecture.');
    }

    onProgress?.call('Checking for latest release from GitHub...');
    final url = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
    final res = await http
        .get(url, headers: _githubHeaders())
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw StateError('Failed to fetch release info (HTTP ${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final rawTag = data['tag_name'] as String? ?? '';
    final latest = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
    final tag = rawTag.isNotEmpty ? rawTag : 'v$latest';

    if (!_isNewer(currentVersion, latest)) {
      onProgress?.call('Nib is already up to date (v$currentVersion).');
      return;
    }

    final archiveExt = Platform.isWindows ? 'zip' : 'tar.gz';
    final archiveName = 'nib-$tag-$target.$archiveExt';
    final downloadUrl =
        'https://github.com/$repo/releases/download/$tag/$archiveName';

    onProgress?.call('Downloading $archiveName...');
    final downloadRes = await http
        .get(Uri.parse(downloadUrl))
        .timeout(const Duration(seconds: 60));

    if (downloadRes.statusCode != 200) {
      throw StateError('Download failed (HTTP ${downloadRes.statusCode})');
    }

    final tempDir = await Directory.systemTemp.createTemp('nib_update_');
    try {
      final archiveFile = File(p.join(tempDir.path, archiveName));
      await archiveFile.writeAsBytes(downloadRes.bodyBytes);

      onProgress?.call('Extracting binary...');
      if (Platform.isWindows) {
        final pr = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'Expand-Archive -Path "${archiveFile.path}" -DestinationPath "${tempDir.path}" -Force',
        ]);
        if (pr.exitCode != 0) {
          throw StateError('Extraction failed: ${pr.stderr}');
        }
      } else {
        final pr = await Process.run('tar', [
          '-xzf',
          archiveFile.path,
          '-C',
          tempDir.path,
        ]);
        if (pr.exitCode != 0) {
          throw StateError('Extraction failed: ${pr.stderr}');
        }
      }

      final binaryName = Platform.isWindows ? 'nib.exe' : 'nib';
      final newBinary = File(p.join(tempDir.path, binaryName));
      if (!await newBinary.exists()) {
        throw StateError('Extracted archive did not contain "$binaryName"');
      }

      onProgress?.call('Replacing executable in-place...');
      final currentExe = File(Platform.resolvedExecutable);

      // On Unix, rename over active executable replaces inode cleanly.
      if (Platform.isWindows) {
        final backupExe = File('${currentExe.path}.old');
        if (await backupExe.exists()) {
          try {
            await backupExe.delete();
          } catch (_) {}
        }
        await currentExe.rename(backupExe.path);
        await newBinary.copy(currentExe.path);
      } else {
        await Process.run('chmod', ['+x', newBinary.path]);
        await newBinary.rename(currentExe.path);
        await Process.run('chmod', ['+x', currentExe.path]);
      }

      onProgress?.call(
        '✔ Successfully upgraded Nib from v$currentVersion to v$latest!',
      );
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Uninstalls Nib by deleting the executable and optionally purging ~/.nib
  static Future<bool> performUninstall({
    bool purgeData = false,
    bool force = false,
    void Function(String message)? onProgress,
  }) async {
    final exe = File(Platform.resolvedExecutable);

    if (!force) {
      stdout.write(
        'Are you sure you want to uninstall Nib (${exe.path})? [y/N]: ',
      );
      final confirm = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (confirm != 'y' && confirm != 'yes') {
        onProgress?.call('Uninstall cancelled.');
        return false;
      }
    }

    // Optional data purge
    var shouldPurge = purgeData;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final dotNib = home.isNotEmpty ? Directory(p.join(home, '.nib')) : null;

    if (!force && !purgeData && dotNib != null && dotNib.existsSync()) {
      stdout.write(
        'Do you also want to remove ~/.nib configuration and sessions? [y/N]: ',
      );
      final purgeConfirm = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (purgeConfirm == 'y' || purgeConfirm == 'yes') {
        shouldPurge = true;
      }
    }

    if (shouldPurge && dotNib != null && dotNib.existsSync()) {
      try {
        dotNib.deleteSync(recursive: true);
        onProgress?.call('✔ Removed ~/.nib directory.');
      } catch (e) {
        onProgress?.call('Warning: Could not remove ~/.nib: $e');
      }
    }

    try {
      if (exe.existsSync()) {
        exe.deleteSync();
        onProgress?.call('✔ Removed binary at ${exe.path}.');
      }
    } catch (e) {
      throw StateError('Could not delete executable at ${exe.path}: $e');
    }

    onProgress?.call('✔ Nib has been uninstalled.');
    return true;
  }

  static String? _detectPlatformArch() {
    String os;
    if (Platform.isLinux) {
      os = 'linux';
    } else if (Platform.isMacOS) {
      os = 'macos';
    } else if (Platform.isWindows) {
      os = 'windows';
    } else {
      return null;
    }

    String arch;
    if (Platform.isMacOS) {
      arch = 'arm64';
    } else {
      final pVer = Platform.version.toLowerCase();
      if (pVer.contains('arm64') || pVer.contains('aarch64')) {
        arch = 'arm64';
      } else {
        arch = 'x64';
      }
    }

    return '$os-$arch';
  }

  static bool _isNewer(String current, String latest) {
    final curParts = _parseSemver(current);
    final latParts = _parseSemver(latest);
    for (var i = 0; i < 3; i++) {
      if (latParts[i] > curParts[i]) return true;
      if (latParts[i] < curParts[i]) return false;
    }
    return false;
  }

  static List<int> _parseSemver(String v) {
    final clean = v.trim().replaceFirst(RegExp(r'^v'), '');
    final parts = clean.split('.');
    return [
      parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
    ];
  }

  static Map<String, String> _githubHeaders() {
    final headers = {
      'Accept': 'application/vnd.github.v3+json',
      'User-Agent': 'nib-updater/v$currentVersion',
    };

    final token =
        Platform.environment['GITHUB_TOKEN'] ??
        Platform.environment['GH_TOKEN'] ??
        _getGhCliToken();

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    return headers;
  }

  static String? _getGhCliToken() {
    try {
      final res = Process.runSync('gh', ['auth', 'token']);
      if (res.exitCode == 0 && res.stdout is String) {
        final tok = (res.stdout as String).trim();
        if (tok.isNotEmpty) return tok;
      }
    } catch (_) {}
    return null;
  }
}
