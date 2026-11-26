# house-style — slide and diagram themes for every repo

House themes for Marp slides and D2 diagrams, plus a one-step setup that makes them available in every
VS Code workspace, with no files added to your experiment repos.

```
house-style/
├── setup.ps1                   One-step setup for Windows (PowerShell)
├── setup.sh                    One-step setup for macOS (bash)
├── themes/                     Marp slide themes
│   ├── phd.css                 slate/blue palette, for PhD and academic decks
│   ├── work.css                purple-led palette, for work decks
│   └── classic.css             simple academic look: Century Gothic + Calibri, logos on the title slide
├── d2/                         D2 diagram themes and the d2t wrapper (see d2/README.md)
│   ├── theme.d2 / theme-dark.d2                    Arial look, light / dark
│   ├── theme-terminal.d2 / theme-terminal-dark.d2  Terminal look (monospace, UPPERCASE)
│   ├── theme-colour*.d2        colour by default (light, dark, + Terminal)
│   ├── core.d2                 shared classes and geometry
│   ├── d2t.ps1 · d2t.cmd · d2t.sh   render with Arial embedded + Tala layout
│   └── examples/  previews/
├── examples/                   starter decks
│   ├── phd_starter_deck.md
│   ├── work_starter_deck.md
│   └── classic_starter_deck.md
├── tests/                      setup tests (run in a throwaway sandbox)
└── icons-placeholder.png       stand-in image used by the starter decks
```

Logos, gear marks and the Feather icon set are embedded in the CSS, so a theme file is self-contained.

## 1. Set up once per machine

Requirements: VS Code with the **Marp** (`marp-team.marp-vscode`) and **D2** (`terrastruct.d2`) extensions,
**D2 ≥ 0.9.0** (it bundles the Tala layout engine), and Node.js for PDF export. On macOS, `setup.sh` also needs
a working Python 3: it uses the first that runs of `python3`, `/usr/bin/python3` (Command Line Tools) and `uv`,
so an asdf or pyenv shim with no version set is skipped.

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1     # Windows
```

```bash
chmod +x ./setup.sh && ./setup.sh                        # macOS
```

What it does (safe to re-run; a second run changes nothing):

1. **VS Code User Settings:** registers `phd`, `work` and `classic` in `markdown.marp.themes`, enables Marp
   HTML, and sets the D2 preview layout (`D2.previewLayout`) to `tala`. The themes are registered as
   `raw.githubusercontent.com` URLs built from this repo's GitHub remote, because Marp for VS Code ignores
   local paths outside the open workspace. So the repo must be public, and the preview needs a network
   connection. Use `-ThemeBaseUrl <url>` (`THEME_BASE_URL=<url>` on macOS) to point elsewhere.
2. **VS Code User Tasks:** adds **house-style: Export Marp Deck to PDF**,
   **house-style: Export D2 to SVG (Tala + Arial)** and **house-style: Preview D2 (live, Tala + Arial)**.
3. **VS Code snippets:** typing `d2theme` in a `.d2` file offers eight imports for this machine: `d2theme`,
   `-dark`, `-terminal`, `-terminal-dark`, and the same four for `d2theme-colour`.
4. **`~/.d2/themes`:** a junction (Windows) or symlink (macOS) to this repo's `d2/` folder.
5. **`d2t`:** installed to `~/.d2/bin`. On Windows that folder is also added to your User PATH (restart
   VS Code and terminals afterwards); on macOS setup prints the line to add to your shell profile.

Your existing settings are never thrown away. Setup reads VS Code's JSON-with-comments correctly, writes a
timestamped `*.bak-*` copy before changing a file, and stops without touching a file it cannot parse.
Comments in a file that *is* rewritten are not kept; they remain in the backup.

## 2. Slides

In any repo, start a deck with front matter:

```markdown
---
marp: true
theme: phd        # or: work, classic
paginate: true
footer: "Lab / Project"
---
```

Live preview works straight away; it loads the theme from GitHub, so theme edits appear in the preview
once pushed (allow a few minutes for GitHub's cache). PDF export uses your local copy. To export: `Ctrl+Shift+P` (`Cmd+Shift+P`) → **Tasks: Run Task** →
**house-style: Export Marp Deck to PDF**. The task passes `--theme-set` to Marp CLI. Without it, Marp CLI
ignores VS Code's theme list and silently exports in its default theme.

Starting a new deck:

1. Copy `examples/phd_starter_deck.md` (or the `work` / `classic` one) into the repo.
2. Edit the front matter: `theme`, `footer`.
3. Replace the slide content; keep one layout per slide: `<!-- _class: tint cards -->`.
4. Figures: use paths relative to the deck, e.g. `![](../figures/fig2.png)`.

Theme names must stay unique (`phd`, `work`, `classic`), because Marp registers them by the `@theme` line.

## 3. Diagrams

In a `.d2` file, type `d2theme` and pick the snippet. It inserts the import for this machine, e.g.:

```d2
...@"C:/Users/<you>/.d2/themes/theme"     # macOS: ...@"/Users/<you>/.d2/themes/theme"

data: Raw data {class: store}
feat: Features {class: primary}
model: Small model {class: primary-solid}
data -> feat -> model
```

The path is absolute and quoted because D2 does not expand `~` in imports. A diagram moved to another
machine needs its import line re-inserted (type `d2theme` again).

Render to SVG with Arial embedded and the Tala layout: **Tasks: Run Task** →
**house-style: Export D2 to SVG (Tala + Arial)**, or from a terminal:

```bash
d2t figure.d2 figure.svg
d2t --watch figure.d2 figure.svg     # live reload
d2t --layout elk figure.d2 figure.svg   # any d2 flag works; --layout / D2_LAYOUT override Tala
```

Live preview with the export look: **Tasks: Run Task** → **house-style: Preview D2 (live, Tala + Arial)**. It
opens a browser page that reloads on every save and writes the same `.svg`; stop it with **Tasks: Terminate
Task**. D2 errors appear in the Problems panel.

Then put it on a slide: `![](figures/figure.svg)`. Palette, classes and the Terminal variants are described
in [d2/README.md](d2/README.md).

## 4. Moving the repo, and other machines

Setup resolves its own location, so after moving or renaming this folder just re-run it: the
`~/.d2/themes` link and the PDF task's `--theme-set` path are updated (the preview's theme URLs follow the
GitHub remote, not the folder). On another machine: clone, then
run setup there.

| Need | Do this |
|---|---|
| Command line / CI | `npx @marp-team/marp-cli@4.5.1 deck.md --theme-set <path>/themes --pdf --allow-local-files` |
| A repo must build without this machine | Add this repo as a git submodule and point the repo's own `.vscode/settings.json` at it: `"markdown.marp.themes": ["./slides/themes/themes/phd.css"]` |

## 5. Keeping the themes in step

`phd.css` and `work.css` share one structure; only the tokens block (palette, fonts, title size, logos)
differs. When you change a layout in one, make the same change in the other. `classic.css` has its own,
simpler structure and layouts (`section`, `picture`, `blank`); it is kept as it is.

## 6. Tests

The setup scripts are tested against a throwaway sandbox; your real VS Code config and PATH are never
touched (each run checks this).

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1   # Windows PowerShell 5.1
```

```bash
bash tests/run-tests.sh   # macOS; on Windows Git Bash it uses `uv` for python3 and skips symlink checks
```
