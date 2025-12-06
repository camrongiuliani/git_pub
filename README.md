# Git Pub Proxy

A lightweight, local Dart pub server that acts as a proxy for private Git repositories. 

This tool allows you to treat Git repositories as if they were conventional pub packages, enabling version constraints and simplifying dependency management in your Dart and Flutter projects.

## Features

- **Dynamic Version Discovery**: Automatically fetches and lists versions based on Git tags.
- **Semantic Versioning**: Correctly parses and sorts Git tags to serve the latest compatible version.
- **Local Caching**: Clones Git repositories into a local cache to speed up subsequent fetches.
- **On-Demand Archiving**: Creates and serves `.tar.gz` archives of your package source code on the fly.
- **Simple CLI**: Provides `start`, `stop`, and `restart` commands to manage the server's lifecycle.
- **Configurable Port**: Allows specifying a custom port for the server.

## Prerequisites

- **Dart SDK**: The script is written in Dart and requires the Dart SDK to run.
- **Git**: The server relies on the `git` command-line tool being available in the system's PATH.

## Configuration

1.  Create a JSON configuration file named `.pub-git-proxy.json` in the same directory where you will run the script.

2.  Add your private packages to this file, mapping the package name to its Git URL. The key is the package name you use in `pubspec.yaml`, and the value is the HTTPS or SSH URL for the Git repository.

    **Example `.pub-git-proxy.json`:**
    ```json
    {
      "my_private_package": {
        "gitUrl": "https://github.com/my-org/my_private_package.git"
      },
      "another_package": {
        "gitUrl": "git@github.com:my-org/another_package.git"
      }
    }
    ```

## How to Use

Navigate to the directory containing the `git_pub.dart` script and your `.pub-git-proxy.json` configuration file.

**Start the Server:**

This command starts the server in the foreground. If a server is already running, it will be stopped first. By default, the server runs on port 8080.

```bash
dart run git_pub.dart start
```

To specify a different port, use the `--port` option:

```bash
dart run git_pub.dart start --port 8081
```

**Stop the Server:**

This command finds the server's process ID (PID) from a temporary file and terminates it.

```bash
dart run git_pub.dart stop
```

**Restart the Server:**

This is a convenient shortcut for stopping and then starting the server. It also clears the in-memory tag cache.

```bash
dart run git_pub.dart restart
```

## Using the Proxy in a Flutter/Dart Project

To make your project use the local Git Pub Proxy, you need to override the package's location in your `pubspec.yaml` file. Use the `hosted` dependency type, specifying the proxy's URL (including the custom port if you set one).

**Example `pubspec.yaml`:**

```yaml
dependencies:
  flutter:
    sdk: flutter

  # This package will be fetched from your local Git Pub Proxy on port 8081
  my_private_package:
    hosted:
      name: my_private_package
      url: http://localhost:8081 # URL of the running proxy
    version: ^1.2.0

  # other_package will be fetched from pub.dev as usual
  other_package:
    version: ^2.5.0
```

Now, when you run `flutter pub get` or `dart pub get`, the Dart build tools will contact your local proxy for `my_private_package`, which will then fetch the correct version from your Git repository.

## How It Works

- **Package Metadata (`/api/packages/<packageName>`):**
  - When `pub get` runs, it first asks the proxy for a list of available versions for a given package.
  - The proxy runs `git ls-remote --tags` on the configured Git URL to get all tags.
  - It filters for tags that look like semantic versions (e.g., `1.0.0`, `v2.1.3`).
  - These versions are sorted and returned to the client in the JSON format expected by the pub tool.

- **Package Archive (`/api/packages/<packageName>/versions/<version>.tar.gz`):**
  - Once the pub client determines which version to use, it requests the corresponding `.tar.gz` archive.
  - The proxy server:
    1.  Clones the repository into a temporary cache directory (if not already cached).
    2.  Fetches the latest tags to ensure it's up-to-date.
    3.  Checks out the specific Git tag requested.
    4.  Creates a `.tar.gz` archive of the repository's contents (excluding the `.git` directory).
    5.  Streams the generated archive back to the client.
