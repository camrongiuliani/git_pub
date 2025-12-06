import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart'; // For robust version sorting
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

// --- CONFIGURATION ---

/// Name of the JSON configuration file expected in the current working directory.
const String _configFileName = '.pub-git-proxy.json';

/// Holds the package configurations loaded from the JSON file.
///
/// The key is the package name, and the value is a record containing the Git URL.
/// Example: { "my_package": (gitUrl: "https://github.com/user/repo.git") }
late final Map<String, ({String gitUrl})> _packageConfig;

/// Directory path for caching cloned Git repositories.
///
/// Using a temporary directory ensures that the cache is cleaned up on system restart.
final String _gitCacheDir =
    p.join(Directory.systemTemp.path, 'pub_git_proxy_cache');

/// File path for storing the server's process ID (PID) to manage its lifecycle.
final String _pidFilePath = p.join(Directory.systemTemp.path, 'savpub.pid');

/// The hostname the server will listen on. '0.0.0.0' makes it accessible from any network interface.
const String _hostname = '0.0.0.0';

/// The port the server will listen on. Can be overridden with the --port CLI flag.
int _port = 8080;

/// In-memory cache for storing Git tags (versions) for each package.
///
/// This avoids costly `git ls-remote` calls for every version request.
/// The key is the package name, and the value is a list of version strings.
final Map<String, List<String>> _tagsCache = {};

// --- UTILITIES ---

/// Executes a Git command asynchronously and returns its standard output.
///
/// Throws an exception if the command fails (exits with a non-zero code).
///
/// - [args]: The arguments to pass to the `git` executable.
/// - [workingDirectory]: The directory where the command should be executed.
Future<String> _runGit(List<String> args, {String? workingDirectory}) async {
  final result =
      await Process.run('git', args, workingDirectory: workingDirectory);

  if (result.exitCode != 0) {
    // Log detailed error information for easier debugging.
    print('Git Error (Exit Code ${result.exitCode}): ${args.join(' ')}');
    print('Stdout: ${result.stdout}');
    print('Stderr: ${result.stderr}');
    throw Exception('Git command failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

/// Loads and validates the package configuration from the `.pub-git-proxy.json` file.
///
/// This file must be present in the directory where the script is executed.
Future<Map<String, ({String gitUrl})>> _loadPackageConfig() async {
  final configFile = File(_configFileName);

  if (!configFile.existsSync()) {
    throw FileSystemException(
      'Configuration file not found.',
      configFile.path,
      const OSError(
        'Please create a "$_configFileName" file in the current directory.',
      ),
    );
  }

  print('Loading package configuration from ${configFile.path}...');

  try {
    final content = await configFile.readAsString();
    final Map<String, dynamic> jsonMap = json.decode(content);

    final config = <String, ({String gitUrl})>{};

    // Validate and parse the JSON structure.
    jsonMap.forEach((key, value) {
      if (value is Map<String, dynamic> &&
          value.containsKey('gitUrl') &&
          value['gitUrl'] is String) {
        config[key] = (gitUrl: value['gitUrl'] as String);
      } else {
        throw FormatException(
          'Invalid configuration for package "$key". Expected `{"gitUrl": "..."}`.',
        );
      }
    });

    if (config.isEmpty) {
      throw Exception(
        'Configuration file is empty or contains no valid packages.',
      );
    }

    print('Successfully loaded ${config.length} package configuration(s).');
    return config;
  } on FileSystemException catch (e) {
    throw Exception('Error reading configuration file: ${e.message}');
  } on FormatException catch (e) {
    throw Exception(
      'Configuration file is not valid JSON or has an invalid structure: $e',
    );
  }
}

/// Fetches all semantic version tags from a remote Git repository.
///
/// It uses `git ls-remote` for efficiency, avoiding a full clone.
/// Results are cached in memory to speed up subsequent requests.
///
/// - [packageName]: The name of the package, used for caching.
/// - [gitUrl]: The remote URL of the Git repository.
Future<List<String>> _getAvailableTags(
  String packageName,
  String gitUrl,
) async {
  // Return cached tags if available.
  if (_tagsCache.containsKey(packageName)) {
    return _tagsCache[packageName]!;
  }

  print('Fetching tags for $packageName from $gitUrl...');

  try {
    // `ls-remote` lists references from a remote repository.
    final result = await _runGit(['ls-remote', '--tags', gitUrl]);

    // Parse the output to extract tag names.
    // Example output line: "f1b2c3d... refs/tags/v1.2.3"
    final tags = result
        .split('\n')
        .map((line) {
          if (line.isEmpty) return null;
          final parts = line.split('\t');
          // e.g., "refs/tags/v1.2.3" -> "v1.2.3"
          return parts.last.split('/').last;
        })
        .whereType<String>() // Filter out nulls
        .map((tag) {
          // Normalize tags by removing a leading 'v' (e.g., "v1.0.0" -> "1.0.0").
          if (tag.startsWith('v') &&
              tag.length > 1 &&
              RegExp(r'\d').hasMatch(tag[1])) {
            return tag.substring(1);
          }
          return tag;
        })
        // Ensure tags follow a basic SemVer pattern (e.g., "1.2.3").
        .where((tag) => RegExp(r'^\d+\.\d+\.\d+').hasMatch(tag))
        .toList();

    _tagsCache[packageName] = tags; // Cache the result.
    print('Found ${tags.length} versions for $packageName.');
    return tags;
  } catch (e) {
    print('Failed to fetch tags for $packageName: $e');
    return []; // Return an empty list on failure to prevent server crashes.
  }
}

// --- HTTP HANDLERS ---

/// Responds to `GET /api/packages/<packageName>`.
///
/// This endpoint mimics the official pub server's package metadata API. It returns
/// a JSON object containing a list of all available versions for the package.
Future<Response> _handlePackageRequest(
  Request request,
  String packageName,
) async {
  final config = _packageConfig[packageName];

  if (config == null) {
    return Response.notFound(
      'Package "$packageName" not found in proxy configuration.',
    );
  }

  final availableVersions = await _getAvailableTags(packageName, config.gitUrl);

  if (availableVersions.isEmpty) {
    return Response.internalServerError(
      body: 'Could not retrieve any versions from the Git repository.',
    );
  }

  // 1. Parse strings into `Version` objects for correct semantic version sorting.
  final versionObjects = availableVersions
      .map((v) {
        try {
          return Version.parse(v);
        } catch (_) {
          return null; // Ignore non-parsable versions.
        }
      })
      .whereType<Version>()
      .toList()
    ..sort(); // Sorts according to SemVer rules (e.g., 1.0.10 > 1.0.9).

  // 2. Format the version data into the structure expected by the pub client.
  final versions = versionObjects.map((vObject) {
    final v = vObject.toString();
    // The URL where the pub client can download the tarball for this version.
    final archiveUrl =
        'http://${request.requestedUri.host}:${request.requestedUri.port}/api/packages/$packageName/versions/$v.tar.gz';

    return {
      'version': v,
      'retracted': false,
      'pubspec': {
        'name': packageName,
        'version': v,
        'environment': {'sdk': '>=3.0.0 <4.0.0'}, // Generic SDK constraint.
      },
      'archive_url': archiveUrl,
    };
  }).toList();

  // 3. The latest version is the last one in the sorted list.
  final latestVersion = versionObjects.last.toString();
  final latestVersionObject =
      versions.firstWhere((v) => v['version'] == latestVersion);

  // 4. Construct the final JSON response body.
  final jsonResponse = {
    'name': packageName,
    'isDiscontinued': false,
    'latest': latestVersionObject,
    'versions': versions,
  };

  return Response.ok(
    json.encode(jsonResponse),
    headers: {'content-type': 'application/json'},
  );
}

/// Responds to `GET /api/packages/<package>/versions/<version>.tar.gz`.
///
/// This endpoint serves a gzipped tarball of the package's source code for a specific version.
Future<Response> _handleArchiveRequest(
  Request request,
  String packageName,
  String version,
) async {
  final config = _packageConfig[packageName];

  if (config == null) {
    return Response.notFound(
      'Package "$packageName" not found in proxy configuration.',
    );
  }

  final packageDir = p.join(_gitCacheDir, packageName);
  final archivePath = p.join(_gitCacheDir, '$packageName-$version.tar.gz');

  try {
    // 1. Clone the repository if not already cached, or fetch latest tags if it is.
    final dir = Directory(packageDir);
    if (!dir.existsSync()) {
      print('Cloning $packageName from ${config.gitUrl}...');
      await _runGit(
        ['clone', config.gitUrl, packageName],
        workingDirectory: _gitCacheDir,
      );
    } else {
      print('Fetching latest tags for $packageName...');
      await _runGit(['fetch', '--tags'], workingDirectory: packageDir);
    }

    // 2. Check out the specific git tag corresponding to the requested version.
    print('Checking out version $version...');
    try {
      // Try with a 'v' prefix first, as it's a common convention.
      await _runGit(
        ['checkout', 'tags/v$version', '-f'],
        workingDirectory: packageDir,
      );
    } catch (_) {
      // Fallback to checking out the tag without the 'v' prefix.
      await _runGit(
        ['checkout', 'tags/$version', '-f'],
        workingDirectory: packageDir,
      );
    }

    // 3. Create a compressed tarball (.tar.gz) of the checked-out code.
    print('Creating archive at $archivePath...');

    // Use a temporary directory to stage files for archiving, excluding the .git folder.
    final tempArchiveDir = Directory(
      p.join(Directory.systemTemp.path, 'pub_archive_temp', packageName),
    );
    if (tempArchiveDir.existsSync()) {
      await tempArchiveDir.delete(recursive: true);
    }
    await tempArchiveDir.create(recursive: true);

    // Copy repository contents to the staging area.
    await for (final entity in dir.list(followLinks: false)) {
      if (p.basename(entity.path) != '.git') {
        final targetPath = p.join(tempArchiveDir.path, p.basename(entity.path));
        // Use system 'cp' for simplicity in copying directories.
        await Process.run('cp', ['-r', entity.path, targetPath]);
      }
    }

    // Create the tarball from the staging directory.
    final archiveResult = await Process.run(
      'tar',
      ['-czf', archivePath, packageName],
      workingDirectory: tempArchiveDir.parent.path,
    );

    if (archiveResult.exitCode != 0) {
      throw Exception('Tar command failed: ${archiveResult.stderr}');
    }

    // 4. Stream the created tarball back to the client.
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
      body: 'Failed to generate package archive: $e',
    );
  }
}

// --- SERVER LIFECYCLE ---

/// Initializes and runs the Shelf HTTP server.
Future<void> _runServer() async {
  // 1. Load configuration on startup.
  try {
    _packageConfig = await _loadPackageConfig();
  } catch (e) {
    print('FATAL ERROR during configuration loading: $e');
    exit(1);
  }

  // 2. Ensure the Git cache directory exists.
  final cacheDir = Directory(_gitCacheDir);
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
    print('Created Git cache directory: $_gitCacheDir');
  } else {
    print('Using existing Git cache directory: $_gitCacheDir');
  }

  // 3. Define the server's routing rules.
  final router = Router()
    ..get('/api/packages/<packageName>', _handlePackageRequest)
    ..get('/api/packages/<packageName>/versions/<version>.tar.gz',
        (Request request, String packageName, String version) {
      // The pub client might request '1.0.0.tar.gz', so we clean it up.
      final cleanVersion = version.endsWith('.tar.gz')
          ? version.substring(0, version.length - 7)
          : version;
      return _handleArchiveRequest(request, packageName, cleanVersion);
    })
    ..get(
      '/',
      (_) => Response.ok('SavPub Git Proxy is running on $_hostname:$_port.'),
    );

  // 4. Set up the request handler pipeline with logging.
  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(router.call);

  // 5. Start the server and handle potential port conflicts.
  try {
    final server = await io.serve(handler, _hostname, _port);
    await File(_pidFilePath).writeAsString(pid.toString());

    print('SavPub started successfully!');
    print('Server PID: $pid');
    print(
      'Serving Dart Pub Git Proxy at http://${server.address.host}:$_port',
    );
    print('Press Ctrl-C to stop (or use "git_pub stop").');
  } on SocketException catch (e) {
    if (e.message.contains('Address already in use')) {
      print(
        'Error: Port $_port is already in use. Please stop the running process or choose a different port.',
      );
      // Clean up the PID file if the server fails to start
      final pidFile = File(_pidFilePath);
      if (pidFile.existsSync()) {
        pidFile.deleteSync();
      }
      exit(1);
    } else {
      rethrow;
    }
  }
}

// --- COMMAND-LINE INTERFACE ---

/// Prints the CLI usage instructions.
void _printUsage() {
  print('Usage: dart run git_pub.dart [options] <command>');
  print('');
  print('A local pub server proxy for private Git repositories.');
  print('');
  print('Options:');
  print('  --port <number>    Sets the server port (default: 8080).');
  print('');
  print('Commands:');
  print(
    '  start    Start the server. If it is already running, it will be stopped first.',
  );
  print('  stop     Stop the running server.');
  print('  restart  Restart the server and clear the in-memory tag cache.');
}

/// Handles the `start` command. If the server is already running, it will be
/// automatically stopped before starting a new instance.
Future<void> _startCommand() async {
  final pidFile = File(_pidFilePath);
  if (pidFile.existsSync()) {
    print(
      'Server appears to be already running. Automatically stopping it first...',
    );
    await _stopCommand();
    // Wait a moment for the port to be released.
    await Future.delayed(const Duration(seconds: 1));
  }

  await _runServer();
}

/// Handles the `stop` command.
Future<void> _stopCommand() async {
  final pidFile = File(_pidFilePath);
  if (!pidFile.existsSync()) {
    print('Server is not running (PID file not found).');
    return;
  }

  try {
    final pidValue = int.parse(await pidFile.readAsString());
    print('Stopping server with PID $pidValue...');

    // Send a termination signal to the process.
    if (Process.killPid(pidValue)) {
      print('Successfully sent termination signal to PID $pidValue.');
      // Give it a moment to shut down gracefully.
      await Future.delayed(const Duration(seconds: 1));
    } else {
      print(
        'Warning: Could not signal PID $pidValue. It may have already exited.',
      );
    }
  } catch (e) {
    print(
      'Error stopping server: $e. The process may need to be stopped manually.',
    );
  } finally {
    // Always attempt to clean up the PID file.
    if (pidFile.existsSync()) {
      await pidFile.delete();
      print('PID file cleaned up.');
    }
  }
}

/// Handles the `restart` command.
Future<void> _restartCommand() async {
  print('Restarting server...');
  _tagsCache.clear(); // Clear in-memory cache on restart.
  await _stopCommand();
  await Future.delayed(const Duration(seconds: 1)); // Wait for port to free up.
  await _startCommand();
}

/// Main entry point for the command-line application.
void main(List<String> arguments) async {
  final args = List<String>.from(arguments);

  // Find and extract the --port argument.
  final portIndex = args.indexOf('--port');
  if (portIndex != -1) {
    if (portIndex + 1 >= args.length) {
      print('Error: Missing value for --port argument.');
      _printUsage();
      exit(1);
    }
    try {
      _port = int.parse(args[portIndex + 1]);
      // Remove the flag and its value to not interfere with command parsing.
      args.removeRange(portIndex, portIndex + 2);
    } catch (e) {
      print(
        'Error: Invalid port number "${args[portIndex + 1]}". Must be an integer.',
      );
      exit(1);
    }
  }

  if (args.isEmpty) {
    print('Error: A command (start, stop, restart) is required.');
    _printUsage();
    return;
  }

  final command = args.first.toLowerCase();

  switch (command) {
    case 'start':
      await _startCommand();
    case 'stop':
      await _stopCommand();
    case 'restart':
      await _restartCommand();
    default:
      print('Unknown command: "$command"');
      _printUsage();
  }
}
