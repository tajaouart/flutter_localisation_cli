# @flutterlocalisation/angular

Translate an Angular app with [FlutterLocalisation](https://flutterlocalisation.com), the
official Angular way: `@angular/localize`, an `@@id` on every message, `ng extract-i18n`, one
build per locale.

```bash
ng add @flutterlocalisation/angular
```

It sets up what `ng add @angular/localize` does (the polyfill, the types, the dependency),
makes `ng extract-i18n` write ARB to `src/locale`, names your source locale, installs the `fl`
command and adds three scripts:

| script | does |
|---|---|
| `npm run i18n:extract` | `ng extract-i18n`: writes `src/locale/messages.arb` |
| `npm run i18n:push` | extracts, then sends the strings, translated into every language |
| `npm run i18n:pull` | writes `messages.<locale>.arb` and lists each locale in `angular.json` |

Then `ng build --localize` builds every language.

## Writing messages

```html
<h1 i18n="@@home.title">Hello</h1>
<p i18n="@@home.greeting">Hello {{ name }}</p>
<span i18n="@@home.count">{count, plural, =0 {No posts yet} =1 {One post} other {{{count}} posts}}</span>
```

```ts
this.message = $localize`:@@toast.saved:Saved ${count}:count: posts`;
```

Every message needs an `@@id`: without one Angular names it by a hash of its English text, and
the hash changes with every edit. A plural or select is the whole message, with the sentence
inside each case; inside a sentence Angular gives it a hash id of its own. `npx fl doctor`
lists both.

Options: `--locale-dir`, `--source-locale`, `--project`, `--skip-install`.

A project shared with an iOS or Flutter app gives the Angular app only the keys that ship to
Angular, with their Angular text where a key has a shorter one. Set `"platforms": ["angular"]`
in `flutterlocalisation.json` when the repository holds the Angular app only.
