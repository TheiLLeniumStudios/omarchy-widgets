# omarchy widgets — TheiLLeniumStudios

A widget store for [Omalauncher](https://github.com/TheiLLeniumStudios/omalauncher): home-screen
widgets written in OWL. On every push to `main`, CI builds `index.json` and publishes the store to
GitHub Pages at <https://theilleniumstudios.github.io/omarchy-widgets/>, where the launcher's
**widget store** reads it (add it there as `TheiLLeniumStudios/omarchy-widgets`).

Before installing, the app shows every command a widget runs and every package it installs, and it
checks the download against the catalog's SHA-256. Unlike the
[reviewed store](https://github.com/SimonSchubert/omarchy-widgets) this is built from, widgets here
are published by pushing to `main`, without review.

## Adding a widget

From the phone: long-press the widget, tap **publish** and pick this store; your coding agent commits
it here and pushes. That needs a GitHub login in the phone's Linux; use a fine-grained token limited
to this repo with *Contents: read and write* (`gh auth login --with-token`, then `gh auth setup-git`).

By hand:

1. Add it at `widgets/<your GitHub username, lowercase>/<name>/widget.owl` (lowercase letters,
   digits and dashes), with `meta { description: "..."; version: "1.0"; license: "MIT" }` and its
   packages in `requires { pacman: [...] }`.
2. Optionally add `preview.png` (under 300 KB) and `previews/<theme>.webp` (under 100 KB each).
3. Check it: `java -jar tools/owl.jar review . widgets/<you>/<name>/widget.owl`
4. Push to `main`. Bump `version` in `meta` for updates: the app offers an update when it goes up.

`order.txt` sets the store's order. The language is documented in [docs/LANGUAGE.md](docs/LANGUAGE.md).
`tools/`, `docs/`, `w/` and the workflows come from SimonSchubert/omarchy-widgets (MIT, see LICENSE).
