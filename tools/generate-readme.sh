#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
#  generate-readme.sh
#  Scans the repo, introspects module directories, and rebuilds
#  the auto-generated sections of README.md between markers.
#
#  A "module" = any top-level directory that isn't hidden or tools/.
#  Descriptions are pulled from the first content line of the
#  first .md file found in each module. Zero config files needed.
#
#  Usage: bash tools/generate-readme.sh
# ────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# ── Replace content between <!-- AUTO:$1:START --> and :END -->
#    with contents of temp file $2
inject() {
    local section=$1 payload=$2
    awk -v s="<!-- AUTO:${section}:START -->" \
        -v e="<!-- AUTO:${section}:END -->" \
        -v p="$payload" \
    'index($0,s) { print; while((getline l < p)>0) print l; close(p); x=1; next }
     index($0,e) { x=0 }
     !x' README.md > README.md.tmp && mv README.md.tmp README.md
}

# ── Discover modules ─────────────────────────────────────────────

modules=()
for d in */; do
    [[ "$d" == .* || "$d" == tools/ ]] && continue
    modules+=("${d%/}")
done

(( ${#modules[@]} )) || { echo "No modules found." >&2; exit 0; }
printf ':: found %d module(s): %s\n' "${#modules[@]}" "${modules[*]}" >&2

# ── Module table ─────────────────────────────────────────────────

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

total_f=0 total_l=0
{
    echo '<table>'
    echo '  <tr><th>Module</th><th>Description</th><th></th></tr>'
    for dir in "${modules[@]}"; do
        desc="—"
        md=$(find "$dir" -maxdepth 1 -name '*.md' | head -1)
        if [[ -n "$md" ]]; then
            desc=$(awk '!/^(#|---|[[:space:]]*$)/ && NF { print; exit }' "$md")
            : "${desc:=—}"
        fi

        link="${md:-$dir/}"

        n_files=$(find "$dir" -type f | wc -l | tr -d '[:space:]')
        n_lines=$(find "$dir" -type f -exec cat {} + 2>/dev/null | wc -l | tr -d '[:space:]')
        (( total_f += n_files )) || true
        (( total_l += n_lines )) || true

        echo "  <tr>"
        echo "    <td><b><a href=\"${link}\">${dir}</a></b></td>"
        echo "    <td>${desc}</td>"
        echo "    <td><sub>${n_files} files · ${n_lines} lines</sub></td>"
        echo "  </tr>"
    done
    echo '</table>'
} > "$tmp"
inject MODULES "$tmp"

# ── Tree ─────────────────────────────────────────────────────────

{
    echo '```'
    if command -v tree &>/dev/null && tree --version &>/dev/null; then
        tree --dirsfirst --charset utf-8 -I '.git|.github' -a . \
            | sed '1s|.*|repo/|'
    else
        echo "repo/"
        find . -not -path './.git/*' -not -path './.git' \
               -not -path './.github/*' -not -path './.github' \
               -not -name '.' -print \
            | sed 's|^\./||' | sort | awk '
        { lines[NR] = $0; depth[NR] = split($0, _, "/") - 1 }
        END {
            for (i = 1; i <= NR; i++) {
                last = 1
                for (j = i + 1; j <= NR; j++) {
                    if (depth[j] <= depth[i]) {
                        if (depth[j] == depth[i]) last = 0
                        break
                    }
                }
                is_last[i] = last
            }
            for (i = 1; i <= NR; i++) {
                d = depth[i]
                split(lines[i], p, "/")
                prefix = ""
                for (k = 0; k < d; k++) {
                    if (cont[k]) prefix = prefix "│   "
                    else         prefix = prefix "    "
                }
                if (is_last[i]) prefix = prefix "└── "
                else            prefix = prefix "├── "
                cont[d] = !is_last[i]
                print prefix p[d + 1]
            }
        }'
    fi
    echo '```'
} > "$tmp"
inject TREE "$tmp"

# ── Stats ────────────────────────────────────────────────────────

printf '**%d module(s)** · **%s files** · **%s lines**\n' \
    "${#modules[@]}" "$total_f" "$total_l" > "$tmp"
inject STATS "$tmp"
echo ":: README.md updated." >&2
