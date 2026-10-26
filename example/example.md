# flutter_localisation_cli example

Install the `fl` command:

```bash
dart pub global activate flutter_localisation_cli
```

Store an API token from the FlutterLocalisation dashboard (**API Keys**), then link the app
in the current folder to a project:

```bash
fl login --token flk_live_xxx
cd my_app
fl init
```

Add a key and let the service translate it into every other locale of the project:

```bash
fl add greeting --value "Hello" -t
```

Move a whole existing ARB file in one request instead of one call per key:

```bash
fl import lib/l10n/app_en.arb -t
```

Pull the translated ARB files back and regenerate the Dart code:

```bash
fl pull
flutter gen-l10n
```

Check how complete each locale is:

```bash
fl status
```

The same operations are available to an AI assistant through the MCP server:

```json
{
  "mcpServers": {
    "flutterlocalisation": {
      "command": "/Users/you/.pub-cache/bin/fl_mcp",
      "env": { "FL_API_TOKEN": "flk_live_xxx" }
    }
  }
}
```
