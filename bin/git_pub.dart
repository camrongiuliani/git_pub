import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart'; // Dependency required for version sorting

// --- CONFIGURATION ---

// File name for the configuration JSON file to be read from PWD
const String _configFileName = '.pub-git-proxy.json';

// IMPORTANT: This map will now be loaded from the JSON file at runtime.
// The structure of the JSON file must match:
// { "my_private_package": { "gitUrl": "https://..." }, ... }
late final Map<String, ({String gitUrl})> _packageConfig;

// Local directory to clone and cache the Git repositories.
final String _gitCacheDir =
    p.join(Directory.systemTemp.path, 'pub_git_proxy_cache');
// File path to store the server's Process ID (PID)
final String _pidFilePath = p.join(Directory.systemTemp.path, 'savpub.pid');
final String _hostname = '0.0.0.0';
final int _port = 8080;

// In-memory cache for Git tags to prevent repeated remote calls
final Map<String, List<String>> _tagsCache = {};

// --- UTILITIES ---

/// Executes a git command and handles potential errors.
Future<String> _runGit(List<String> args, {String? workingDirectory}) async {
  final result =
      await Process.run('git', args, workingDirectory: workingDirectory);

  if (result.exitCode != 0) {
    print('Git Error (Exit Code ${result.exitCode}): ${args.join(' ')}');
    print('Stdout: ${result.stdout}');
    print('Stderr: ${result.stderr}');
    throw Exception('Git command failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

/// Loads the package configuration from the .pub-git-proxy.json file.
Future<Map<String, ({String gitUrl})>> _loadPackageConfig() async {
  final configFile = File(_configFileName);

  if (!configFile.existsSync()) {
    throw FileSystemException(
      'Configuration file not found',
      configFile.path,
      OSError(
        'Please create a "$_configFileName" file in the current directory with your package mappings.',
      ),
    );
  }

  print('Loading package configuration from ${configFile.path}...');

  try {
    final content = await configFile.readAsString();
    final Map<String, dynamic> jsonMap = json.decode(content);

    final Map<String, ({String gitUrl})> config = {};

    jsonMap.forEach((key, value) {
      if (value is Map<String, dynamic> &&
          value.containsKey('gitUrl') &&
          value['gitUrl'] is String) {
        config[key] = (gitUrl: value['gitUrl'] as String);
      } else {
        throw FormatException(
            'Invalid configuration for package "$key". Expected {"gitUrl": "..."}.');
      }
    });

    if (config.isEmpty) {
      throw Exception(
          'Configuration file is empty or contains no valid packages.');
    }

    print('Successfully loaded ${config.length} package configuration(s).');
    return config;
  } on FileSystemException catch (e) {
    throw Exception('Error reading configuration file: ${e.message}');
  } on FormatException catch (e) {
    throw Exception(
        'Configuration file is not valid JSON or has an invalid structure: $e');
  } catch (e) {
    rethrow;
  }
}

/// Dynamically fetches all available semantic version tags from a Git repository.
Future<List<String>> _getAvailableTags(
    String packageName, String gitUrl) async {
  // Check cache first
  if (_tagsCache.containsKey(packageName)) {
    return _tagsCache[packageName]!;
  }

  print('Fetching tags for $packageName from $gitUrl...');

  try {
    // Use `git ls-remote` for fast tag retrieval without needing a full clone
    final result = await _runGit(['ls-remote', '--tags', gitUrl]);

    // Parse the output (e.g., "SHA\trefs/tags/v1.2.3")
    final tags = result
        .split('\n')
        .map((line) {
          if (line.isEmpty) return null;
          final parts = line.split('\t');
          // Extract the tag name, which is the last part after the last slash
          return parts.last.split('/').last;
        })
        .where((tag) => tag != null && tag!.isNotEmpty)
        .map((tag) {
          // Remove leading 'v' if present (e.g., v1.0.0 -> 1.0.0)
          if (tag!.startsWith('v') &&
              tag.length > 1 &&
              RegExp(r'\d').hasMatch(tag[1])) {
            return tag.substring(1);
          }
          return tag;
        })
        // Simple filter to try and keep only valid SemVer tags (e.g., 1.2.3)
        .where((tag) => RegExp(r'^\d+\.\d+\.\d+').hasMatch(tag!))
        .toList()
        .cast<String>();

    // Update cache and return
    _tagsCache[packageName] = tags;
    print('Found ${tags.length} versions for $packageName.');
    return tags;
  } catch (e) {
    print('Failed to fetch tags for $packageName: $e');
    return []; // Return empty list on failure
  }
}

// --- HANDLERS ---

/// Handles the GET /api/packages/<package> request (to list versions)
/// Pub expects a JSON response with the package name and a list of available versions.
Future<Response> _handlePackageRequest(
    Request request, String packageName) async {
  final config = _packageConfig[packageName];

  if (config == null) {
    return Response.notFound(
        'Package "$packageName" not found in proxy configuration.');
  }

  // Dynamically fetch all available versions (tags)
  final availableVersions = await _getAvailableTags(packageName, config.gitUrl);

  if (availableVersions.isEmpty) {
    return Response.internalServerError(
        body: 'Could not retrieve any versions from Git repository.');
  }

  // 1. Convert string versions to Version objects for proper semantic sorting
  final versionObjects = availableVersions
      .map((v) {
        try {
          return Version.parse(v);
        } catch (e) {
          return null;
        }
      })
      .where((v) => v != null)
      .toList()
    ..sort(); // Sorts ascending based on semantic versioning rules

  // 2. Map all version objects into the complex format Pub expects
  final List<Map<String, dynamic>> versions = versionObjects.map((vObject) {
    final v = vObject.toString();
    final archiveUrl =
        'http://${request.requestedUri.host}:${request.requestedUri.port}/api/packages/$packageName/versions/$v.tar.gz';

    // Note: This uses a static/minimal pubspec structure.
    return {
      'version': v,
      'retracted': false,
      'pubspec': {
        'name': packageName,
        'version': v,
        'environment': {'sdk': '>=3.0.0 <4.0.0'}, // Standard environment
      },
      'archive_url': archiveUrl,
    };
  }).toList();

  // 3. Identify the latest version (the last one after sorting)
  final latestVersion = versionObjects.last.toString();

  // 4. Find the 'latest' object from the list generated above
  final latestVersionObject =
      versions.firstWhere((v) => v['version'] == latestVersion);

  // 5. Construct the final compliant pub API response
  final jsonResponse = {
    'name': packageName,
    'isDiscontinued': false, // Not discontinued
    'latest': latestVersionObject,
    'versions': versions,
  };

  return Response.ok(
    json.encode(jsonResponse),
    headers: {'content-type': 'application/json'},
  );
}

/// Handles the GET /api/packages/<package>/versions/<version>.tar.gz request (to serve the archive)
Future<Response> _handleArchiveRequest(
    Request request, String packageName, String version) async {
  final config = _packageConfig[packageName];

  if (config == null) {
    return Response.notFound(
        'Package "$packageName" not found in proxy configuration.');
  }

  // The Pub client has already determined the exact version (tag) it needs based on the range.
  final packageDir = p.join(_gitCacheDir, packageName);
  final archivePath = p.join(_gitCacheDir, '$packageName-$version.tar.gz');

  try {
    // 1. Ensure the package directory exists (Clone if necessary)
    final dir = Directory(packageDir);
    if (!dir.existsSync()) {
      print('Cloning $packageName from ${config.gitUrl}...');
      await _runGit(
        ['clone', config.gitUrl, packageName],
        workingDirectory: _gitCacheDir,
      );
    } else {
      // Ensure local repo is up to date with tags
      print('Fetching latest tags for $packageName...');
      await _runGit(['fetch', '--tags'], workingDirectory: packageDir);
    }

    // 2. Checkout the specific tag/version requested by the Pub client
    print('Checking out version $version...');
    // We try 'tags/v$version' and 'tags/$version' as tags can sometimes have a 'v' prefix
    try {
      await _runGit(['checkout', 'tags/v$version', '-f'],
          workingDirectory: packageDir);
    } catch (_) {
      await _runGit(['checkout', 'tags/$version', '-f'],
          workingDirectory: packageDir);
    }

    // 3. Create the compressed archive (tar -czf)
    print('Creating archive at $archivePath...');

    // We use a temporary directory for archiving to ensure we only compress the package content
    final tempArchiveDir = Directory(
        p.join(Directory.systemTemp.path, 'pub_archive_temp', packageName));
    if (tempArchiveDir.existsSync()) {
      await tempArchiveDir.delete(recursive: true);
    }
    await tempArchiveDir.create(recursive: true);

    // Copy package contents (excluding the .git folder)
    await for (final entity in dir.list(recursive: false)) {
      final baseName = p.basename(entity.path);
      if (baseName != '.git') {
        final targetPath = p.join(tempArchiveDir.path, baseName);
        if (entity is Directory) {
          await Process.run('cp', ['-r', entity.path, targetPath]);
        } else if (entity is File) {
          await entity.copy(targetPath);
        }
      }
    }

    // Create tar.gz archive
    // Change directory to the parent of the package to archive the folder itself
    final archiveResult = await Process.run(
        'tar',
        [
          '-czf',
          archivePath,
          packageName // Archive the package folder name itself
        ],
        workingDirectory: tempArchiveDir.parent.path);

    if (archiveResult.exitCode != 0) {
      throw Exception('Tar command failed: ${archiveResult.stderr}');
    }

    // 4. Serve the archive file
    print('Serving archive $archivePath...');
    final file = File(archivePath);
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': 'application/x-tar',
        'content-disposition':
            'attachment; filename="$packageName-$version.tar.gz"',
        'content-length': file.lengthSync().toString(),
      },
    );
  } catch (e) {
    print('Archive generation error: $e');
    return Response.internalServerError(
        body: 'Failed to generate package archive: $e');
  }
}

// --- SERVER LOGIC ---

/// Runs the Shelf server and writes the PID to a file.
Future<void> _runServer() async {
  // 1. Load configuration first
  try {
    _packageConfig = await _loadPackageConfig();
  } catch (e) {
    print('FATAL ERROR during configuration loading: $e');
    exit(1);
  }

  // 2. Ensure the cache directory exists
  final cacheDir = Directory(_gitCacheDir);
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
    print('Created Git cache directory: $_gitCacheDir');
  } else {
    print('Using existing Git cache directory: $_gitCacheDir');
  }

  // Define the router
  final router = Router()
    ..get('/api/packages/<packageName>', _handlePackageRequest)
    ..get('/api/packages/<packageName>/versions/<version>.tar.gz',
        (Request request, String packageName, String version) {
      final cleanVersion = version.endsWith('.tar.gz')
          ? version.substring(0, version.length - 7)
          : version;
      return _handleArchiveRequest(request, packageName, cleanVersion);
    })
    ..get(
        '/',
        (_) =>
            Response.ok('SavPub Git Proxy is running on $_hostname:$_port.'));

  // Middleware to log requests
  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(router);

  try {
    final server = await io.serve(handler, _hostname, _port);

    // Write the PID to the file *after* successful startup
    await File(_pidFilePath).writeAsString(pid.toString());

    print('SavPub started successfully!');
    print('Server PID: $pid');
    print(
        'Serving Dart Pub Git Proxy at http://${server.address.host}:${server.port}');
    print(
        'Press Ctrl-C to stop (or use "savpub stop" if run as a background service).');
  } on SocketException catch (e) {
    if (e.message.contains('Address already in use')) {
      print(
          'Error: Port $_port is already in use. Please stop the running process or choose a different port.');
    } else {
      rethrow;
    }
  }
}

// --- COMMAND LOGIC ---

void _printUsage() {
  print('Usage: dart run pub_git_proxy.dart <command>');
  print('');
  print('Commands:');
  print('  start    Start the SavPub server (runs in foreground).');
  print('  stop     Stop the running SavPub server using its PID.');
  print('  restart  Stop and then start the SavPub server.');
}

/// CLI command to start the server.
Future<void> _startCommand() async {
  final pidFile = File(_pidFilePath);
  if (pidFile.existsSync()) {
    try {
      final pid = int.parse(await pidFile.readAsString());
      // Note: In a real-world CLI, you'd check if the PID is actually running.
      // For simplicity here, we assume if the file exists, the server is running.
      print(
          'Server appears to be already running with PID $pid. Use "savpub restart" or "savpub stop".');
      return;
    } catch (_) {
      // PID file is corrupt, proceed to start
      await pidFile.delete().catchError((_) {});
    }
  }

  await _runServer();
}

/// CLI command to stop the server.
Future<void> _stopCommand() async {
  final pidFile = File(_pidFilePath);
  if (!pidFile.existsSync()) {
    print('Server is not running (PID file not found at $_pidFilePath).');
    return;
  }

  try {
    final pid = int.parse(await pidFile.readAsString());
    print('Attempting to stop SavPub server with PID $pid...');

    final success = Process.killPid(pid, ProcessSignal.sigterm);

    if (success) {
      print('Successfully sent termination signal to PID $pid.');
      // Wait a moment for the process to exit and clean up
      await Future.delayed(Duration(seconds: 1));
    } else {
      print(
          'Warning: Could not send signal to PID $pid. It might be dead already.');
    }

    // Clean up the PID file
    await pidFile.delete();
    print('SavPub server stopped and PID file cleaned up.');
  } catch (e) {
    print('Error stopping server: $e');
    await pidFile.delete().catchError((_) {}); // Try to clean up corrupted file
  }
}

/// CLI command to restart the server.
Future<void> _restartCommand() async {
  print('Initiating SavPub restart...');
  // Clear the in-memory tag cache on restart
  _tagsCache.clear();
  await _stopCommand();
  // Wait briefly for resources (port) to be freed
  await Future.delayed(Duration(seconds: 1));
  await _startCommand();
}

// --- MAIN CLI DISPATCHER ---

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    _printUsage();
    return;
  }

  final command = arguments.first.toLowerCase();

  switch (command) {
    case 'start':
      await _startCommand();
      break;
    case 'stop':
      await _stopCommand();
      break;
    case 'restart':
      await _restartCommand();
      break;
    default:
      print('Unknown command: "$command"');
      _printUsage();
      break;
  }
}
