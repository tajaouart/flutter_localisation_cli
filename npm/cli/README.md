# @flutterlocalisation/cli

The `fl` command and the `fl_mcp` MCP server of [FlutterLocalisation](https://flutterlocalisation.com),
for Flutter, iOS and Angular apps, as native binaries. No Dart needed.

```bash
npm install --save-dev @flutterlocalisation/cli
npx fl init        # API key, project, folders
npx fl pull        # translated files into the repo
```

In an Angular app, `ng add @flutterlocalisation/angular` installs this package and sets up
`@angular/localize` for you.

MCP clients (Claude, GitHub Copilot) start the server with:

```json
{ "command": "npx", "args": ["-y", "--package", "@flutterlocalisation/cli", "fl_mcp"], "env": { "FL_API_TOKEN": "flk_live_..." } }
```

npm installs the one binary package that matches the machine
(`@flutterlocalisation/cli-darwin-arm64`, `-darwin-x64`, `-linux-x64`, `-linux-arm64`,
`-win32-x64`). The same commands come with Dart: `dart pub global activate flutter_localisation_cli`.
Full documentation: https://pub.dev/packages/flutter_localisation_cli
