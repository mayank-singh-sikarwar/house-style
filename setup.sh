#!/usr/bin/env bash
# =============================================================================
# setup.sh - One-step setup for house-style themes on macOS / Linux.
# Configures VS Code User Settings, D2 Tala/Arial tooling, and global export tasks.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "===================================================="
echo "  house-style - Personal Theme & Engine Setup (POSIX)"
echo "===================================================="
echo "Repo location: $REPO_ROOT"
echo ""

# Test overrides (redirect every write into a sandbox):
#   CODE_USER_DIR=<dir>  VS Code User dir      HOME_DIR=<dir>  home for ~/.d2      NO_PATH=1  skip PATH advice
HOME_DIR="${HOME_DIR:-$HOME}"
NO_PATH="${NO_PATH:-}"

# Determine OS and VS Code User Settings Directory
if [[ -n "${CODE_USER_DIR:-}" ]]; then
    :
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CODE_USER_DIR="$HOME/Library/Application Support/Code/User"
else
    CODE_USER_DIR="$HOME/.config/Code/User"
fi

EXIT_CODE=0
D2_USER_DIR="$HOME_DIR/.d2"
D2_THEMES_LINK="$D2_USER_DIR/themes"
D2_BIN_DIR="$D2_USER_DIR/bin"

# Marp for VS Code only loads themes from https URLs or from paths inside the open workspace;
# an absolute local path is silently dropped. So register the GitHub raw URLs of this repo.
#   THEME_BASE_URL=<url>  folder holding phd.css / work.css (default: from the GitHub remote)
#   GIT_REMOTE_URL=<url>  tests only: stands in for `git remote get-url origin`
THEME_BASE="${THEME_BASE_URL:-}"
THEME_BASE="${THEME_BASE%/}"
if [[ -z "$THEME_BASE" ]]; then
    REMOTE="${GIT_REMOTE_URL:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)}"
    if [[ "$REMOTE" =~ github\.com[:/]([^/]+)/([^/]+)/?$ ]]; then
        GH_OWNER="${BASH_REMATCH[1]}"; GH_REPO="${BASH_REMATCH[2]%.git}"
        THEME_BASE="https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/main/themes"
    else
        THEME_BASE="$REPO_ROOT/themes"
        echo "[!] No GitHub remote found: Marp live preview will not show the house themes (PDF export still will)."
        echo "    Re-run with THEME_BASE_URL=https://<host>/<path-to>/themes"
    fi
fi
export CODE_USER_DIR REPO_ROOT D2_BIN_DIR HOME_DIR THEME_BASE

# -----------------------------------------------------------------------------
# 0. Is VS Code installed? (spec section 6) A User dir from an earlier launch, or `code` on PATH.
#    If not: skip every editor step and never create Code/User.
# -----------------------------------------------------------------------------
VSCODE_PRESENT=0
if [[ -d "$CODE_USER_DIR" ]] || command -v code >/dev/null 2>&1; then VSCODE_PRESENT=1; fi
if [[ "$VSCODE_PRESENT" != 1 ]]; then
    echo "[!] VS Code not found (no $CODE_USER_DIR and no 'code' on PATH)."
    echo "    Skipping VS Code settings, tasks and snippets; re-run setup after installing VS Code."
    echo "[i] D2 import line for this machine:"
    echo "    ...@\"$HOME_DIR/.d2/themes/theme\""
fi

# -----------------------------------------------------------------------------
# 1. VS Code User Settings, Tasks & D2 snippets (safe JSONC merge, spec section 5.1)
#    String-aware parse, abort a file on parse failure, no-op when unchanged,
#    timestamped backup before write, atomic replace.
# -----------------------------------------------------------------------------
if [[ "$VSCODE_PRESENT" == 1 ]] && ! python3 - <<'EOF'
import copy, json, os, shutil, sys, tempfile, time

code_dir = os.environ["CODE_USER_DIR"]
repo_root = os.environ["REPO_ROOT"]


def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas, only outside string literals."""
    out, i, n, in_str = [], 0, len(text), False

    def skip_ws_comments(j):
        while j < n:
            if text[j].isspace():
                j += 1
            elif text.startswith("//", j):
                while j < n and text[j] != "\n":
                    j += 1
            elif text.startswith("/*", j):
                e = text.find("*/", j + 2)
                if e < 0:
                    return n
                j = e + 2
            else:
                break
        return j

    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            e = text.find("*/", i + 2)
            if e < 0:
                raise ValueError("unterminated /* comment")
            i = e + 2; continue
        if c == ",":
            j = skip_ws_comments(i + 1)
            if j < n and text[j] in "}]":
                i += 1; continue
        out.append(c); i += 1
    if in_str:
        raise ValueError("unterminated string")
    return "".join(out)


def parse_jsonc(text):
    clean = strip_jsonc(text)
    if not clean.strip():
        return {}
    data = json.loads(clean)
    if not isinstance(data, dict):
        raise ValueError("top-level value is not a JSON object")
    return data


def update_json_file(path, mutate):
    """Read -> mutate -> write only if changed. Returns created|updated|unchanged|failed."""
    exists = os.path.exists(path)
    data = {}
    if exists:
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                data = parse_jsonc(f.read())
        except Exception as e:
            print(f"[x] Could not parse {path}")
            print(f"    {e}")
            print("    File left untouched. Fix it (or move it aside) and re-run setup.")
            return "failed"
    before = json.dumps(data)
    data = mutate(copy.deepcopy(data))
    if exists and json.dumps(data) == before:
        return "unchanged"
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    if exists:
        shutil.copy2(path, path + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=os.path.basename(path) + ".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    return "updated" if exists else "created"


def report(what, path, result):
    if result == "unchanged":
        print(f"[=] {what} already up to date -> {path}")
    elif result != "failed":
        print(f"[+] {what} {result} -> {path}")


# ---- settings.json ----
house_themes = [os.environ["THEME_BASE"] + "/" + x for x in ("phd.css", "work.css")]


def mutate_settings(s):
    existing = s.get("markdown.marp.themes") or []
    kept = [t for t in existing
            if not any(str(t).replace("\\", "/").lower().endswith("/" + x) for x in ("dtp.css", "phd.css", "splice.css", "work.css"))]
    s["markdown.marp.themes"] = kept + house_themes
    s["markdown.marp.enableHtml"] = True
    # D2 extension (terrastruct.d2) preview layout; 'd2.layout' was a rev-1 key no extension reads
    s["D2.previewLayout"] = "tala"
    s.pop("d2.layout", None)
    return s


# ---- tasks.json ----
MARP_CLI_VERSION = "4.5.1"
LEGACY = ("house-style:", "D2: Export SVG", "Marp: Export")
d2_task = {
    "label": "house-style: Export D2 to SVG (Tala + Arial)",
    "type": "shell",
    # Absolute path: VS Code tasks must not depend on ~/.d2/bin being on PATH
    "command": os.environ["D2_BIN_DIR"] + "/d2t",
    "args": ["${file}", "${fileDirname}/${fileBasenameNoExtension}.svg"],
    "group": "build",
    "presentation": {"reveal": "silent", "panel": "shared"},
    "problemMatcher": [],
}
marp_task = {
    "label": "house-style: Export Marp Deck to PDF",
    "type": "shell",
    "command": "npx",
    # --theme-set: Marp CLI does not read VS Code's markdown.marp.themes
    "args": ["--yes", "@marp-team/marp-cli@" + MARP_CLI_VERSION, "${file}",
             "--theme-set", repo_root + "/themes", "--pdf", "--allow-local-files",
             "-o", "${fileDirname}/${fileBasenameNoExtension}.pdf"],
    "group": "build",
    "presentation": {"reveal": "silent", "panel": "shared"},
    "problemMatcher": [],
}


def mutate_tasks(t):
    existing = [x for x in (t.get("tasks") or []) if not str(x.get("label", "")).startswith(LEGACY)]
    t.setdefault("version", "2.0.0")
    t["tasks"] = existing + [d2_task, marp_task]
    return t


# ---- snippets/d2.json (spec section 5.3) ----
# D2 does not expand ~ in imports, so the snippets insert a quoted absolute path for this machine.
home_fwd = os.environ["HOME_DIR"].replace("\\", "/")
VARIANTS = ("theme", "theme-dark", "theme-terminal", "theme-terminal-dark")


def mutate_snippets(sn):
    sn = {k: v for k, v in sn.items() if not k.startswith("house-style:")}
    for v in VARIANTS:
        sn["house-style: import " + v] = {
            "prefix": "d2" + v,
            "body": [f'...@"{home_fwd}/.d2/themes/{v}"'],
            "description": f"Import the house D2 theme '{v}' (absolute path for this machine)",
        }
    return sn


failed = False
for what, name, fn in (("VS Code User Settings", "settings.json", mutate_settings),
                       ("VS Code User Tasks", "tasks.json", mutate_tasks),
                       ("VS Code D2 snippets", os.path.join("snippets", "d2.json"), mutate_snippets)):
    p = os.path.join(code_dir, name)
    r = update_json_file(p, fn)
    report(what, p, r)
    failed = failed or r == "failed"
print("[i] D2 import line for this machine (or type 'd2theme' in a .d2 file):")
print(f'    ...@"{home_fwd}/.d2/themes/theme"')
sys.exit(1 if failed else 0)
EOF
then
    EXIT_CODE=1
fi

# -----------------------------------------------------------------------------
# 2. Global D2 Themes Symlink
# -----------------------------------------------------------------------------
mkdir -p "$D2_USER_DIR"

if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    # Git Bash / Cygwin: `ln -s` silently copies the folder instead of linking it.
    echo "[!] Windows shell detected: skipping the themes link (ln -s would copy d2/). On Windows, use setup.ps1."
elif [[ -L "$D2_THEMES_LINK" ]]; then
    # A symlink (possibly dangling): replace the link itself; -n stops ln following it into the old target.
    CURRENT="$(readlink "$D2_THEMES_LINK")"
    if [[ "$CURRENT" == "$REPO_ROOT/d2" ]]; then
        echo "[=] Global D2 themes link already configured: $D2_THEMES_LINK -> $REPO_ROOT/d2"
    else
        ln -sfn "$REPO_ROOT/d2" "$D2_THEMES_LINK"
        echo "[+] Re-pointed global D2 themes link -> $REPO_ROOT/d2 (was $CURRENT)"
    fi
elif [[ -e "$D2_THEMES_LINK" ]]; then
    echo "[x] $D2_THEMES_LINK exists and is not a link (a real folder or file). Leaving it untouched."
    echo "    Move it aside and re-run setup to link it to $REPO_ROOT/d2."
    EXIT_CODE=1
else
    ln -s "$REPO_ROOT/d2" "$D2_THEMES_LINK"
    echo "[+] Linked global D2 themes directory: $D2_THEMES_LINK -> $REPO_ROOT/d2"
fi

# -----------------------------------------------------------------------------
# 3. Global d2t Wrapper & PATH Setup
# -----------------------------------------------------------------------------
mkdir -p "$D2_BIN_DIR"

# Copy only when missing or different, so a re-run makes no writes.
if [[ -f "$D2_BIN_DIR/d2t" ]] && cmp -s "$REPO_ROOT/d2/d2t.sh" "$D2_BIN_DIR/d2t"; then
    echo "[=] d2t wrapper already up to date -> $D2_BIN_DIR/d2t"
else
    cp "$REPO_ROOT/d2/d2t.sh" "$D2_BIN_DIR/d2t"
    chmod +x "$D2_BIN_DIR/d2t"
    echo "[+] Installed d2t wrapper to $D2_BIN_DIR/d2t"
fi

# Advise on PATH if needed
if [[ -n "$NO_PATH" ]]; then
    echo "[i] NO_PATH set: skipping PATH advice"
elif [[ ":$PATH:" != *":$D2_BIN_DIR:"* ]]; then
    echo "[i] To run 'd2t' directly from any terminal, add ~/.d2/bin to your PATH:"
    echo "    echo 'export PATH=\"\$HOME/.d2/bin:\$PATH\"' >> ~/.zshrc (or ~/.bashrc)"
fi

# -----------------------------------------------------------------------------
# 5. Sanity Check
# -----------------------------------------------------------------------------
echo ""
echo "Toolchain Check:"
# D2 >= 0.9.0 bundles Tala (spec section 5.4). Hints only; never fails setup.
MIN_D2="0.9.0"
ver_ge() {   # ver_ge A B -> true if A >= B (numeric x.y.z; works on macOS bash 3.2)
    local IFS=. i a b
    read -r -a a <<<"$1"; read -r -a b <<<"$2"
    for i in 0 1 2; do
        if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
        if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
    done
    return 0
}
if command -v d2 >/dev/null 2>&1; then
    D2_VER_TEXT="$(d2 --version 2>&1 | tr -d '\r' | head -n 1)"
    D2_VER="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$D2_VER_TEXT" | head -n 1 || true)"
    HAS_TALA=0
    if d2 layout 2>&1 | grep -qw tala; then HAS_TALA=1; fi
    if [[ -n "$D2_VER" ]] && ver_ge "$D2_VER" "$MIN_D2" && [[ "$HAS_TALA" == 1 ]]; then
        echo "  [OK] D2 v$D2_VER with Tala"
    else
        if [[ -z "$D2_VER" ]] || ! ver_ge "$D2_VER" "$MIN_D2"; then
            echo "  [!] D2 $D2_VER_TEXT is older than $MIN_D2 (Tala is bundled from $MIN_D2). Upgrade: curl -fsSL https://d2lang.com/install.sh | sh -s --"
        fi
        if [[ "$HAS_TALA" != 1 ]]; then
            echo "  [!] Tala layout engine not available; d2t still works with D2_LAYOUT=elk."
        fi
    fi
else
    echo "  [!] D2 CLI not found. Install via: curl -fsSL https://d2lang.com/install.sh | sh -s --"
fi

if command -v npx >/dev/null 2>&1; then
    echo "  [OK] npx (Node.js) is available for Marp PDF exports."
else
    echo "  [!] Node.js/npx not found. Install via brew or official package."
fi

echo ""
echo "===================================================="
echo "  Setup Complete!                                   "
echo "===================================================="
echo "Use in any workspace without per-repo configuration:"
echo "1. Marp Slides: add 'theme: phd' or 'theme: work' to frontmatter."
echo "2. D2 Diagrams: in a .d2 file type 'd2theme' (or d2theme-dark / d2theme-terminal / d2theme-terminal-dark);"
echo "   the import line for this machine is printed above."
echo "3. Export: run 'Ctrl+Shift+P' (Cmd+Shift+P) -> 'Tasks: Run Task' -> export."
echo ""
if [[ "$EXIT_CODE" -ne 0 ]]; then echo "[x] Setup finished with errors (see [x] lines above)."; fi
exit "$EXIT_CODE"
