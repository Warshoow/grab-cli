#!/usr/bin/env bash
# Regression checks for grab, against throwaway local repos. Run: ./test.sh
set -uo pipefail

GRAB="$(cd "$(dirname "$0")" && pwd)/grab"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch main
git config --global protocol.file.allow always

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
g() { bash "$GRAB" "$@" </dev/null >/dev/null 2>&1; }

# Tools repo: main has foo, foo-bar, hooked; dev changes foo
git init -q "$T/src"
(
    cd "$T/src"
    for t in foo foo-bar hooked; do mkdir "$t"; echo "# $t tool" > "$t/README.md"; done
    echo 'touch "$GRAB_PROJECT_DIR/hook-ran"' > hooked/post-grab.sh
    git add -A && git commit -qm init
    git checkout -qb dev && echo DEV > foo/README.md && git commit -qam dev && git checkout -q main
)
git clone -q --bare "$T/src" "$T/tools.git"
REPO="file://$T/tools.git"

mkdir "$T/p" && cd "$T/p"
g init "$REPO"

g add foo-bar --no-hook
g add foo --no-hook
check "add foo after foo-bar" 'grep -qx foo .grabfile'

rm -rf .grab/tools
g install --no-hook; rc=$?
check "install copies every tool" '[[ $rc == 0 && -d .grab/tools/foo && -d .grab/tools/foo-bar ]]'

check "status exits 0" 'g status'

out=$(bash "$GRAB" list --remote 2>&1)
check "list --remote shows tools not installed" 'grep -q hooked <<< "$out"'

g remove foo
check "remove foo keeps foo-bar" 'grep -qx foo-bar .grabfile && ! grep -qx foo .grabfile'

echo "branch=main" >> .grabfile
check "branch= line is not a tool" 'g install --no-hook'

g add foo @dev --no-hook
g update
check "update keeps pinned ref" 'grep -q DEV .grab/tools/foo/README.md'

g add hooked; rc=$?
check "hook without terminal does not fail" '[[ $rc == 0 && -d .grab/tools/hooked && ! -e hook-ran ]]'

out=$(bash "$GRAB" add nope --no-hook 2>&1)
check "unknown tool gives clear message" 'grep -q "not found in repo" <<< "$out"'

mkdir -p "$T/p2/newtool" && cd "$T/p2" && echo x > newtool/a
g init "$REPO"
echo "branch=dev" >> .grabfile
g publish newtool -m pub
check "publish follows .grabfile branch" 'git -C "$T/tools.git" ls-tree --name-only dev | grep -qx newtool && ! git -C "$T/tools.git" ls-tree --name-only main | grep -qx newtool'

echo
[[ $fails == 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
