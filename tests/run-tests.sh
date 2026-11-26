#!/usr/bin/env bash
# Tests for setup.sh. Every case runs the real script against a throwaway sandbox
# (CODE_USER_DIR / HOME_DIR / NO_PATH), so real config is never touched.
#
#   bash tests/run-tests.sh
#
# If no working python3 is on PATH (e.g. Git Bash on Windows), a temporary python3 shim
# backed by `uv run --no-project python` is used.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
PASSES=0
FAILURES=0

# ---- python3 shim --------------------------------------------------------------
SHIM_DIR=""
if ! python3 -c 'import sys' >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    SHIM_DIR="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexec uv run --no-project --quiet python "$@"\n' > "$SHIM_DIR/python3"
    chmod +x "$SHIM_DIR/python3"
    export PATH="$SHIM_DIR:$PATH"
    echo "(using python3 shim via uv)"
  else
    echo "No python3 and no uv: cannot run setup.sh tests." >&2
    exit 2
  fi
fi

# ---- helpers -------------------------------------------------------------------
new_sandbox() {   # sets SB, SB_CODE, SB_HOME
  SB="$(mktemp -d "${TMPDIR:-/tmp}/hs-test-XXXXXX")"
  SB_CODE="$SB/Code/User"
  SB_HOME="$SB/home"
  # VS Code counts as installed when its User dir exists (macOS often has no `code` on PATH)
  mkdir -p "$SB_HOME" "$SB_CODE"
}

remove_sandbox() {
  # Remove symlinks on their own first; rm -rf never follows them, but be explicit.
  find "$SB" -type l -exec rm -f {} + 2>/dev/null || true
  rm -rf "$SB"
}

run_setup() {     # sets RC, OUT
  OUT="$(CODE_USER_DIR="$SB_CODE" HOME_DIR="$SB_HOME" NO_PATH=1 bash "$SETUP" 2>&1)"
  RC=$?
}

# run_setup with PATH changed: run_setup_path <dir-to-prepend or ""> <hide-code: 0/1>
run_setup_path() {
  local p="" d IFS=:
  for d in $PATH; do
    if [ "$2" = 1 ] && { [ -x "$d/code" ] || [ -f "$d/code.cmd" ]; }; then continue; fi
    p="${p:+$p:}$d"
  done
  [ -n "$1" ] && p="$1:$p"
  OUT="$(PATH="$p" CODE_USER_DIR="$SB_CODE" HOME_DIR="$SB_HOME" NO_PATH=1 bash "$SETUP" 2>&1)"
  RC=$?
}

check() {         # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASSES=$((PASSES + 1)); else FAILURES=$((FAILURES + 1)); echo "    FAIL: $desc"; fi
}

test_case() {     # test_case <name> <function>
  echo "- $1"
  new_sandbox
  "$2"
  remove_sandbox
}

# ---- guard: snapshot real config ------------------------------------------------
real_state() {
  local f
  for f in "$HOME/Library/Application Support/Code/User/settings.json" \
           "$HOME/Library/Application Support/Code/User/tasks.json" \
           "$HOME/.config/Code/User/settings.json" \
           "$HOME/.config/Code/User/tasks.json" \
           "${APPDATA:-/nonexistent}/Code/User/settings.json" \
           "${APPDATA:-/nonexistent}/Code/User/tasks.json"; do
    if [ -e "$f" ]; then echo "$f $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"; else echo "$f absent"; fi
  done
}
REAL_BEFORE="$(real_state)"

# Can this shell make real symlinks? (Git Bash on Windows silently copies instead.)
SYMLINKS=0
PROBE="$(mktemp -d)"; mkdir "$PROBE/t"
if ln -s "$PROBE/t" "$PROBE/l" 2>/dev/null && [ -L "$PROBE/l" ]; then SYMLINKS=1; fi
rm -rf "$PROBE"
[ "$SYMLINKS" = 1 ] || echo "(no symlink support here: link checks skipped; setup.sh skips the link step on Windows)"

# ---- cases -----------------------------------------------------------------------
case_smoke() {
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  [ "$RC" -eq 0 ] || echo "$OUT" | sed 's/^/      /'
  check "settings.json created in sandbox" [ -f "$SB_CODE/settings.json" ]
  check "tasks.json created in sandbox" [ -f "$SB_CODE/tasks.json" ]
  [ "$SYMLINKS" = 1 ] && check ".d2/themes resolves to repo d2/" [ -f "$SB_HOME/.d2/themes/theme.d2" ]
  check "d2t installed and executable" [ -x "$SB_HOME/.d2/bin/d2t" ]
  check "PATH step reported as skipped" grep -q "NO_PATH" <<<"$OUT"
}

FIXTURES="$REPO_ROOT/tests/fixtures"
copy_fixture() { mkdir -p "$SB_CODE"; cp "$FIXTURES/$1" "$SB_CODE/$2"; }
backups() { ls "$SB_CODE" | grep -c '\.bak-' || true; }
# json_true <file> <python expression over `d`> : succeeds if the expression is truthy
json_true() {
  python3 - "$1" "$2" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if eval(sys.argv[2], {"d": d}) else 1)
EOF
}
file_hash() { cksum < "$1"; }
# Path as the (possibly native Windows) python sees it; identity on macOS.
native() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

case_jsonc() {
  copy_fixture settings-jsonc.json settings.json
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  [ "$RC" -eq 0 ] || echo "$OUT" | sed 's/^/      /'
  local s="$SB_CODE/settings.json"
  check "editor.fontSize kept" json_true "$s" 'd["editor.fontSize"] == 14'
  check 'search.exclude "dist/*.map" kept' json_true "$s" 'd["search.exclude"] == {"dist/*.map": True}'
  check "files.exclude globs kept" json_true "$s" 'd["files.exclude"] == {"**/.git": True, "out/**": True}'
  check '"see // docs" string intact' json_true "$s" 'd["my.note"] == "see // docs"'
  check "URL with /* intact" json_true "$s" 'd["my.url"] == "https://example.com/a/*b"'
  check "escaped quotes and backslash intact" json_true "$s" "d['my.quote'] == 'it\\'s \"quoted\" \\\\ back'"
  check "one-element array kept" json_true "$s" 'd["my.single"] == ["only"]'
  check "empty array and object kept" json_true "$s" 'd["my.empty"] == [] and d["my.emptyObj"] == {}'
  check "nested null kept" json_true "$s" 'd["my.nested"] == {"a": [1, 2, {"b": None}]}'
  check "unrelated Marp theme kept first" json_true "$s" 'd["markdown.marp.themes"][0] == "C:/other/custom.css"'
  check "stale phd.css path replaced" json_true "$s" 'not any("/old/place/" in t for t in d["markdown.marp.themes"])'
  check "4 themes total: custom + phd + work + classic" json_true "$s" 'len(d["markdown.marp.themes"]) == 4'
  check "retired dtp/splice entries removed" json_true "$s" 'not any(t.endswith(("dtp.css", "splice.css")) for t in d["markdown.marp.themes"])'
  check "exactly one backup of settings.json" [ "$(backups)" -eq 1 ]
}

case_broken() {
  copy_fixture settings-broken.json settings.json
  local p="$SB_CODE/settings.json" before
  before="$(file_hash "$p")"
  run_setup
  check "non-zero exit code" [ "$RC" -ne 0 ]
  check "settings.json byte-identical" [ "$(file_hash "$p")" == "$before" ]
  # (path form differs under Git Bash + Windows python, so match the file name)
  check "error names the file" grep -qE "Could not parse .*settings\.json" <<<"$OUT"
  check "no backup written" [ "$(backups)" -eq 0 ]
  check "other steps still ran (tasks.json created)" [ -f "$SB_CODE/tasks.json" ]
}

case_tasks() {
  copy_fixture tasks-jsonc.json tasks.json
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  local t="$SB_CODE/tasks.json"
  check "user tasks first, in order" json_true "$t" '[x["label"] for x in d["tasks"]][:2] == ["my build", "my test"]'
  check "one-element arrays in user task kept" json_true "$t" 'd["tasks"][0]["args"] == ["all"] and d["tasks"][0]["problemMatcher"] == ["$gcc"]'
  check "exactly three house-style tasks (no duplicates)" json_true "$t" 'sum(x["label"].startswith("house-style:") for x in d["tasks"]) == 3'
}

case_idempotent() {
  copy_fixture settings-jsonc.json settings.json
  copy_fixture tasks-jsonc.json tasks.json
  run_setup
  check "first run exit 0" [ "$RC" -eq 0 ]
  local m1 m2 b
  m1="$(mtime "$SB_CODE/settings.json") $(mtime "$SB_CODE/tasks.json") $(mtime "$SB_CODE/snippets/d2.json") $(mtime "$SB_HOME/.d2/bin/d2t")"
  b="$(backups)"
  sleep 1.1
  run_setup
  check "second run exit 0" [ "$RC" -eq 0 ]
  m2="$(mtime "$SB_CODE/settings.json") $(mtime "$SB_CODE/tasks.json") $(mtime "$SB_CODE/snippets/d2.json") $(mtime "$SB_HOME/.d2/bin/d2t")"
  check "no file rewritten on second run" [ "$m1" == "$m2" ]
  check "no new backups on second run" [ "$(backups)" -eq "$b" ]
  check "second run reports up to date" grep -q "already up to date" <<<"$OUT"
  check "no temp files left behind" [ "$(ls "$SB_CODE" | grep -c '\.tmp-' || true)" -eq 0 ]
}

case_settings_keys() {
  mkdir -p "$SB_CODE"
  printf '{ "a": 1, "d2.layout": "tala", "z": 2 }' > "$SB_CODE/settings.json"
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  local s="$SB_CODE/settings.json"
  check "D2.previewLayout = tala" json_true "$s" 'd.get("D2.previewLayout") == "tala"'
  check "d2.layout removed" json_true "$s" '"d2.layout" not in d'
  check "markdown.marp.enableHtml = true" json_true "$s" 'd["markdown.marp.enableHtml"] is True'
}

# Marp for VS Code only loads https URLs or workspace paths: themes come from the GitHub remote.
themes_are() {   # themes_are <base>: settings.json lists <base>/{phd,work,classic}.css
  json_true "$SB_CODE/settings.json" "d['markdown.marp.themes'] == ['$1/' + x + '.css' for x in ('phd', 'work', 'classic')]"
}
setup_with_remote() {   # setup_with_remote <remote> [THEME_BASE_URL]; sets RC, OUT
  OUT="$(GIT_REMOTE_URL="$1" THEME_BASE_URL="${2:-}" CODE_USER_DIR="$SB_CODE" HOME_DIR="$SB_HOME" NO_PATH=1 bash "$SETUP" 2>&1)"
  RC=$?
}
case_marp_themes() {
  local raw="https://raw.githubusercontent.com/someone/house-style/main/themes"
  setup_with_remote https://github.com/someone/house-style.git
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  check "https remote -> raw URLs" themes_are "$raw"
  setup_with_remote git@github.com:someone/house-style.git
  check "ssh remote -> raw URLs" themes_are "$raw"
  setup_with_remote https://github.com/someone/house-style
  check "remote without .git -> raw URLs" themes_are "$raw"
  setup_with_remote https://github.com/someone/house-style.git https://example.test/t/
  check "THEME_BASE_URL wins, trailing / trimmed" themes_are "https://example.test/t"
  setup_with_remote https://gitlab.example/x/y.git
  check "non-GitHub remote still exits 0" [ "$RC" -eq 0 ]
  check "non-GitHub remote falls back to local paths" themes_are "$(native "$REPO_ROOT")/themes"
  check "non-GitHub remote warns about live preview" grep -q '\[!\].*preview' <<<"$OUT"
}

case_tasks_contents() {
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  local t="$SB_CODE/tasks.json"
  local d2='[x for x in d["tasks"] if x["label"] == "house-style: Export D2 to SVG (Tala + Arial)"]'
  local mp='[x for x in d["tasks"] if x["label"] == "house-style: Export Marp Deck to PDF"]'
  check "both house-style tasks present with spec labels" json_true "$t" "len($d2) == 1 and len($mp) == 1"
  check "D2 task command is absolute d2t" json_true "$t" "$d2[0]['command'] == '$(native "$SB_HOME")/.d2/bin/d2t'"
  check "marp-cli pinned to 4.5.1" json_true "$t" "'@marp-team/marp-cli@4.5.1' in $mp[0]['args']"
  check "--theme-set points at repo themes" json_true "$t" \
    "(lambda a: a[a.index('--theme-set') + 1] == '$(native "$REPO_ROOT")/themes')($mp[0]['args'])"
  check "pdf flags kept" json_true "$t" "'--pdf' in $mp[0]['args'] and '--allow-local-files' in $mp[0]['args']"
  # Live preview: d2t --watch on the open file (Tala via d2t's default), as a background task
  local pv='[x for x in d["tasks"] if x["label"] == "house-style: Preview D2 (live, Tala + Arial)"]'
  check "preview task present" json_true "$t" "len($pv) == 1"
  check "preview task uses the same absolute d2t" json_true "$t" "$pv[0]['command'] == $d2[0]['command']"
  check "preview args" json_true "$t" "$pv[0]['args'] == ['--watch', '\${file}', '\${fileDirname}/\${fileBasenameNoExtension}.svg']"
  check "preview is a background task" json_true "$t" "$pv[0]['isBackground'] is True"
  check "preview matcher fits d2 watch output" json_true "$t" "(lambda m, re=__import__('re'): bool(re.search(m['background']['beginsPattern'], 'info: compiling a.d2...')) and bool(re.search(m['background']['beginsPattern'], 'info: detected change in a.d2: recompiling...')) and bool(re.search(m['background']['endsPattern'], 'success: successfully compiled a.d2 to a.svg in 5ms')) and bool(re.search(m['background']['endsPattern'], 'err: failed to compile a.d2: /x/a.d2:1:1: boom')) and re.search(m['pattern']['regexp'], 'err: failed to compile a.d2: /x/a.d2:3:7: boom').group(m['pattern']['file'], m['pattern']['line'], m['pattern']['message']) == ('/x/a.d2', '3', 'boom'))($pv[0]['problemMatcher'])"
}

# ---- d2t.sh wrapper ----------------------------------------------------------------
# A stub `d2` first on PATH records the arguments the wrapper passes.
d2t_args() {      # d2t_args [ENV=val ...] -- <args...>  -> prints what d2 received
  local stub="$SB/stub" envs=()
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\n' "$stub" > "$stub/d2"
  chmod +x "$stub/d2"
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u D2_LAYOUT ${envs[@]+"${envs[@]}"} PATH="$stub:$PATH" bash "$REPO_ROOT/d2/d2t.sh" "$@" >/dev/null 2>&1
  tr -d '\r' < "$stub/args"
}

case_d2t_layout() {
  local a
  a="$(d2t_args -- in.d2 out.svg)"
  check "default adds --layout tala" grep -qx -- "tala" <<<"$a"
  a="$(d2t_args -- --layout elk in.d2 out.svg)"
  check "--layout elk is respected (no tala)" bash -c '! grep -qx tala <<<"$1"' _ "$a"
  a="$(d2t_args -- --layout=elk in.d2 out.svg)"
  check "--layout=elk is respected (no tala)" bash -c '! grep -qx tala <<<"$1"' _ "$a"
  a="$(d2t_args -- -l elk in.d2 out.svg)"
  check "-l elk is respected (no tala)" bash -c '! grep -qx tala <<<"$1"' _ "$a"
  a="$(d2t_args D2_LAYOUT=elk -- in.d2 out.svg)"
  check "D2_LAYOUT=elk is respected (no --layout added)" bash -c '! grep -qx -- --layout <<<"$1"' _ "$a"
  a="$(d2t_args -- in.d2 out.svg)"
  check "user args passed through last" [ "$(tail -n 2 <<<"$a" | tr '\n' ' ')" == "in.d2 out.svg " ]
}

case_d2t_render() {
  command -v d2 >/dev/null 2>&1 || { echo "    (skipped: d2 not installed)"; return; }
  printf 'a -> b\n' > "$SB/x.d2"
  bash "$REPO_ROOT/d2/d2t.sh" --layout elk "$SB/x.d2" "$SB/wrapped.svg" >/dev/null 2>&1
  d2 --layout elk "$SB/x.d2" "$SB/plain.svg" >/dev/null 2>&1
  check "wrapper renders an SVG" [ -s "$SB/wrapped.svg" ]
  check "wrapper embeds a different (Arial) font than plain d2" bash -c '! cmp -s "$1" "$2"' _ "$SB/wrapped.svg" "$SB/plain.svg"
}

case_themes() {
  command -v d2 >/dev/null 2>&1 || { echo "    (skipped: d2 not installed)"; return; }
  local themes v
  themes="$(native "$REPO_ROOT")/d2"
  for v in theme theme-dark theme-terminal theme-terminal-dark theme-colour theme-colour-dark theme-colour-terminal theme-colour-terminal-dark; do
    printf '...@"%s/%s"\na: Slide {class: store}\nb: Model {class: primary-solid}\na -> b\ng: Group {c: Card; d: Db {shape: cylinder}; p: Doc {shape: page}}\n' "$themes" "$v" > "$SB/$v.d2"
    d2 "$SB/$v.d2" "$SB/$v.svg" >/dev/null 2>&1
    check "$v compiles from an absolute import" [ -s "$SB/$v.svg" ]
  done
  check "terminal variants use a monospace font" bash -c 'grep -qi mono "$1" && grep -qi mono "$2"' _ "$SB/theme-terminal.svg" "$SB/theme-terminal-dark.svg"
  check "base theme does not" bash -c '! grep -qi mono "$1"' _ "$SB/theme.svg"
  # Colour variants tint an unclassed container (B4 -> primary-soft) and stroke lines in primary; base stays grey
  for v in theme-colour theme-colour-terminal; do
    check "$v tints default containers and lines" bash -c 'grep -q "#E7EEF4" "$1" && grep -q "#3B6EA5" "$1"' _ "$SB/$v.svg"
    # shapes nested in a container use AA5 / AB5 (top-level ones use AA4 / AB4)
    check "$v tints nested cylinders (AA5 -> ok-soft)" grep -qE 'fill="#E8F3ED" class="[^"]*fill-AA5' "$SB/$v.svg"
    check "$v tints nested pages (AB5 -> warn-soft)" grep -qE 'fill="#FDF5E8" class="[^"]*fill-AB5' "$SB/$v.svg"
  done
  check "colour-terminal variants use a monospace font" bash -c 'grep -qi mono "$1" && grep -qi mono "$2"' _ "$SB/theme-colour-terminal.svg" "$SB/theme-colour-terminal-dark.svg"
  check "colour variant keeps Arial-style (no monospace)" bash -c '! grep -qi mono "$1"' _ "$SB/theme-colour.svg"
  check "base theme leaves default containers untinted" bash -c '! grep -q "#E7EEF4" "$1"' _ "$SB/theme.svg"
  check "dark colour variant differs from dark base" bash -c '! cmp -s "$1" "$2"' _ "$SB/theme-colour-dark.svg" "$SB/theme-dark.svg"
  env -u D2_LAYOUT d2 "$SB/theme.d2" "$SB/bare.svg" >/dev/null 2>&1
  d2 --layout tala "$SB/theme.d2" "$SB/tala.svg" >/dev/null 2>&1
  d2 --layout elk "$SB/theme.d2" "$SB/elk.svg" >/dev/null 2>&1
  check "bare d2 render == --layout tala render" cmp -s "$SB/bare.svg" "$SB/tala.svg"
  check "--layout elk still overrides the theme default" bash -c '! cmp -s "$1" "$2"' _ "$SB/bare.svg" "$SB/elk.svg"
}

case_snippets() {
  mkdir -p "$SB_CODE/snippets"
  printf '{ // mine\n  "my box": { "prefix": "box", "body": ["x: {shape: rectangle}"] },\n}\n' > "$SB_CODE/snippets/d2.json"
  run_setup
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  local sn="$SB_CODE/snippets/d2.json" home v body
  home="$(native "$SB_HOME")"
  check "existing user snippet kept" json_true "$sn" '"my box" in d'
  for v in theme theme-dark theme-terminal theme-terminal-dark theme-colour theme-colour-dark theme-colour-terminal theme-colour-terminal-dark; do
    check "d2$v body is the quoted absolute import" json_true "$sn" \
      "[s['body'] for s in d.values() if s.get('prefix') == 'd2$v'] == [['...@\"$home/.d2/themes/$v\"']]"
    if [ "$SYMLINKS" = 1 ] && command -v d2 >/dev/null 2>&1; then
      body="$(python3 -c "import json,sys; print([s['body'][0] for s in json.load(open(sys.argv[1])).values() if s.get('prefix')=='d2$v'][0])" "$sn" 2>/dev/null | tr -d '\r')"
      printf '%s\na -> b\n' "$body" > "$SB/$v.d2"
      d2 "$SB/$v.d2" "$SB/$v.svg" >/dev/null 2>&1
      check "d2$v snippet body compiles via the sandbox .d2/themes link" bash -c '[ -n "$1" ] && [ -s "$2" ]' _ "$body" "$SB/$v.svg"
    fi
  done
  check "setup prints the exact import line" grep -qF "...@\"$home/.d2/themes/theme\"" <<<"$OUT"
  check "setup no longer advertises the broken ~ import" bash -c '! grep -qF "@~/" <<<"$1"' _ "$OUT"
}

case_vscode_missing() {
  rmdir "$SB_CODE" "$SB/Code"
  run_setup_path "" 1
  check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
  [ "$RC" -eq 0 ] || echo "$OUT" | sed 's/^/      /'
  check "Code/User dir not created" [ ! -e "$SB_CODE" ]
  check "warning printed" grep -q "VS Code not found" <<<"$OUT"
  check "wrapper still installed" [ -x "$SB_HOME/.d2/bin/d2t" ]
  check "import line still printed" grep -qF '.d2/themes/theme"' <<<"$OUT"
}

# A version-manager shim (asdf/pyenv) can sit first on PATH and fail when no version is set:
# "No version is set for command python3", exit 126. setup.sh must fall back to a working Python.
case_broken_python() {
  local stub="$SB/stub" s="$SB_CODE/settings.json"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash
echo "No version is set for command python3" >&2
exit 126
' > "$stub/python3"
  chmod +x "$stub/python3"
  run_setup_path "$stub" 0
  check "exit code 0 with a broken python3 first on PATH (got $RC)" [ "$RC" -eq 0 ]
  check "settings.json still written via the fallback Python" [ -s "$s" ]
  check "says which Python it fell back to" grep -q "Python:" <<<"$OUT"
  # No working Python at all (only testable where /usr/bin/python3 is absent or broken, e.g. Git Bash)
  if ! /usr/bin/python3 -c 'import sys' >/dev/null 2>&1; then
    rm -rf "$SB_CODE"; mkdir -p "$SB_CODE"
    printf '#!/usr/bin/env bash
exit 1
' > "$stub/uv"; chmod +x "$stub/uv"
    run_setup_path "$stub" 0
    check "no working Python: exit non-zero (got $RC)" [ "$RC" -ne 0 ]
    check "no working Python: clear message with the fixes" bash -c 'grep -q "No working Python 3" <<<"$1" && grep -q "asdf" <<<"$1" && grep -q "xcode-select --install" <<<"$1"' _ "$OUT"
    check "no working Python: settings.json not created" [ ! -e "$s" ]
    check "no working Python: d2t wrapper still installed" [ -f "$SB_HOME/.d2/bin/d2t" ]
  fi
}

case_old_d2() {
  local stub="$SB/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo v0.8.0; else echo "dagre elk"; fi\n' > "$stub/d2"
  chmod +x "$stub/d2"
  run_setup_path "$stub" 0
  check "exit code 0 with old D2 (got $RC)" [ "$RC" -eq 0 ]
  check "version hint" grep -q "D2 v0.8.0 is older than 0.9.0" <<<"$OUT"
  check "tala hint" grep -q "Tala layout engine not available" <<<"$OUT"
  if command -v d2 >/dev/null 2>&1; then
    run_setup
    check "real d2 reported OK" grep -qE '\[OK\] D2 v[0-9]+\.[0-9]+\.[0-9]+ with Tala' <<<"$OUT"
  fi
}

case_links() {
  local link="$SB_HOME/.d2/themes"
  if [ "$SYMLINKS" != 1 ]; then
    run_setup
    check "exit code 0 (got $RC)" [ "$RC" -eq 0 ]
    check "link step skipped on Windows shells, pointing to setup.ps1" grep -q "use setup.ps1" <<<"$OUT"
    check "no copy of d2/ left at .d2/themes" [ ! -e "$link" ]
    return
  fi
  # re-point a link to another dir; old target untouched
  mkdir -p "$SB/other" "$SB_HOME/.d2"; echo x > "$SB/other/keep.txt"
  ln -s "$SB/other" "$link"
  run_setup
  check "re-point: exit 0" [ "$RC" -eq 0 ]
  check "re-pointed to repo d2" [ "$(readlink "$link")" == "$REPO_ROOT/d2" ]
  check "old target contents untouched" [ -f "$SB/other/keep.txt" ]
  # dangling link
  rm -f "$link"; ln -s "$SB/gone" "$link"
  run_setup
  check "dangling: re-pointed" [ "$(readlink "$link")" == "$REPO_ROOT/d2" ]
  # real directory
  rm -f "$link"; mkdir -p "$link"; echo x > "$link/mine.d2"
  run_setup
  check "real dir: non-zero exit" [ "$RC" -ne 0 ]
  check "real dir: untouched, no link created inside it" bash -c '[ ! -L "$1" ] && [ -f "$1/mine.d2" ] && [ ! -e "$1/d2" ]' _ "$link"
  check "real dir: warning explains why" grep -q "not a link" <<<"$OUT"
}

echo "setup.sh tests (sandboxed)"
echo ""
test_case "smoke: empty sandbox gets settings, tasks, theme link and wrapper" case_smoke
test_case "jsonc: comments, trailing commas, globs and // in strings all survive" case_jsonc
test_case "jsonc: unparseable settings.json is left byte-identical and setup exits non-zero" case_broken
test_case "tasks: user tasks survive in order; house-style tasks replaced, not duplicated" case_tasks
test_case "idempotent: second run writes nothing and makes no new backups" case_idempotent
test_case "settings: D2.previewLayout set, stray rev-1 d2.layout removed" case_settings_keys
test_case "marp themes: https URLs from the GitHub remote, override, fallback" case_marp_themes
test_case "tasks: absolute wrapper command, themed and pinned Marp export" case_tasks_contents
test_case "d2t.sh: Tala by default; --layout / -l / D2_LAYOUT override it" case_d2t_layout
test_case "d2t.sh: real render embeds Arial" case_d2t_render
test_case "themes: terminal variants compile by absolute import; bare d2 uses Tala" case_themes
test_case "snippets: d2theme* snippets written, user snippets kept, bodies compile" case_snippets
test_case "vscode missing: editor steps skipped, Code/User not created, rest still runs" case_vscode_missing
test_case "toolchain: old D2 without Tala gets an upgrade hint; real D2 reports OK" case_old_d2
test_case "python: broken python3 shim (asdf) falls back; none at all gives a clear error" case_broken_python
test_case "links: re-point links only; never replace a real directory" case_links

# ---- result ------------------------------------------------------------------------
check "real VS Code config untouched by the test run" [ "$(real_state)" == "$REAL_BEFORE" ]
check "repo d2/ intact after sandbox cleanup" [ -f "$REPO_ROOT/d2/theme.d2" ]
[ -n "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"

echo ""
echo "$PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
