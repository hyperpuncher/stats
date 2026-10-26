#!/usr/bin/env bash
#
# gen.sh - render a GitHub stats card as SVG.
#
# one GraphQL call. requirements: bash, gh, jq (all three ship on github runners).
# usage: ./gen.sh [username] [output.svg]
#
# writes an SVG that themes itself via prefers-color-scheme.
set -euo pipefail

# ------------------------------------------------------------------ config
USER_NAME="${1:-$(gh api user --jq .login)}"
OUT_FILE="${2:-profile/card.svg}"

# only owned, non-fork repos are counted, so the star total and the language
# total are governed by the same repo set.
# override from the environment or your workflow:
#   LANGS_COUNT=12 EXCLUDE_REPOS="repo-a repo-b" ./gen.sh
LANGS_COUNT="${LANGS_COUNT:-16}"
EXCLUDE_REPOS="${EXCLUDE_REPOS:-}"

# palette catalog: name:bg:title:text:icon. values are github-stats-extended's
# (MIT), so the names mean the same thing they do elsewhere. add your own line
# and select it with THEME=yourname.
CATALOG=(
	"aura:15141b:a277ff:61ffca:ffca85"
	"catppuccin_latte:eff1f5:137980:4c4f69:8839ef"
	"catppuccin_mocha:1e1e2e:94e2d5:cdd6f4:cba6f7"
	"tokyonight:1a1b27:70a5fd:38bdae:bf91f3"
	"dracula:282a36:ff6e96:f8f8f2:79dafa"
	"radical:141321:fe428e:a9fef7:f8d847"
	"gruvbox:282828:fabd2f:8ec07c:fe8019"
	"onedark:282c34:e4bf7a:df6d74:8eb573"
	"github_dark:0d1117:58a6ff:c3d1d9:1f6feb"
	"nord:2e3440:81a1c1:d8dee9:88c0d0"
	"synthwave:2b213a:e2e9ec:e5289e:ef8539"
	"cobalt:193549:e683d9:75eeb2:0480ef"
	"monokai:272822:eb1f6a:f1f1eb:e28905"
	"ocean_dark:151a28:8957b2:92d534:ffffff"
	"rose_pine:191724:9ccfd8:e0def4:ebbcba"
)
THEME_NAMES=""
for entry in "${CATALOG[@]}"; do THEME_NAMES+="${entry%%:*} "; done

# the palette pair, light first then dark. the card themes itself with an
# internal prefers-color-scheme query, so this is the only colour decision.
# a single name uses that palette in both schemes:
#   THEME=aura ./gen.sh
THEME="${THEME:-catppuccin_latte aura}"

# ------------------------------------------------------------------ layout
PAD=25
COLUMN_GAP=35 # between the stat column and the language grid
STAT_X=25
STAT_LABEL_X=25 # local to STAT_X; the 16px icon occupies 0..16
STAT_VALUE_GAP=12
STAT_Y=82
STAT_ROW=38
MAX_VALUE_W=52 # worst case value at 14px, roughly "1234.6k"
LANG_Y=112
LANG_COL=180   # column pitch; raise it for more air between name and %
LANG_GUTTER=20 # space between a percentage and the next column's dot
LANG_ROW=29
BAR_Y=86
BAR_RADIUS=4

# label advance widths at 14px/600 in system-ui, in tenths of a pixel so they
# compare as integers. measured in DejaVu, which is wider than SF Pro or Segoe
# UI, so other platforms get slack rather than a collision. index-aligned with
# $labels; re-measure if a label is added or renamed.
LABEL_W=(1225 965 629 809 799 1238 780)

# static geometry, derived from the tokens and the width table above
max_label_w=$(printf '%s\n' "${LABEL_W[@]}" | sort -n | tail -1)
STAT_VALUE_X=$((STAT_LABEL_X + (max_label_w + 9) / 10 + STAT_VALUE_GAP + MAX_VALUE_W))
LANG_X=$((STAT_X + STAT_VALUE_X + COLUMN_GAP))
BAR_X=$LANG_X
BAR_W=$((LANG_COL * 2 - LANG_GUTTER))
CARD_W=$((LANG_X + BAR_W + PAD))

# ------------------------------------------------------------------ fetch
# all-time commits come from summing GitHub's own contribution years, so the
# whole card fits in one call. search/commits would need a second request and
# reports a different total (10667 vs 10799 for hyperpuncher).
# each year alias also yields the repos contributed to that year, so the
# all-time distinct repo count costs no extra request. 100 is GitHub's ceiling,
# not ours: maxRepositories above 100 is an ARGUMENT_LIMIT error, and the
# repositoryContributions connection rejects first above 100 outright while
# refusing to run without a bound. counting more in one year would mean
# paginating with cursors.
MAX_CONTRIB_REPOS=100
year_blocks=""
for y in $(seq 2008 "$(date -u +%Y)"); do
	year_blocks+="  y$y: contributionsCollection(from: \"$y-01-01T00:00:00Z\", to: \"$y-12-31T23:59:59Z\") {
    totalCommitContributions restrictedContributionsCount
    commitContributionsByRepository(maxRepositories: $MAX_CONTRIB_REPOS) { repository { nameWithOwner } }
    issueContributionsByRepository(maxRepositories: $MAX_CONTRIB_REPOS) { repository { nameWithOwner } }
    pullRequestContributionsByRepository(maxRepositories: $MAX_CONTRIB_REPOS) { repository { nameWithOwner } }
    repositoryContributions(first: $MAX_CONTRIB_REPOS) { nodes { repository { nameWithOwner } } }
  }
"
done

Q_HEAD=$(
	cat <<'EOF'
query($login: String!) {
  user(login: $login) {
    login
    name
    createdAt
    prs: pullRequests(first: 1) { totalCount }
    merged: pullRequests(states: MERGED) { totalCount }
    openIssues: issues(states: OPEN) { totalCount }
    closedIssues: issues(states: CLOSED) { totalCount }
EOF
)
Q_TAIL=$(
	cat <<'EOF'
    calendar: contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } }
    repos: repositories(first: 100, ownerAffiliations: OWNER, isFork: false) {
      totalCount
      pageInfo { hasNextPage }
      nodes {
        name
        isPrivate
        stargazerCount
        languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
          edges { size node { name color } }
        }
      }
    }
  }
}
EOF
)

# github's edge sometimes answers with a 502 html page, which is neither a
# valid response nor an auth failure, so retry a few times before giving up.
tries=0
until data=$(gh api graphql -f query="$Q_HEAD$year_blocks$Q_TAIL" -F login="$USER_NAME" 2>&1) &&
	[[ $data == '{'* ]]; do
	tries=$((tries + 1))
	if [ "$tries" -ge 3 ]; then
		echo "github returned no usable json after $tries tries: ${data:0:300}" >&2
		exit 1
	fi
	sleep 5
done

# a token that cannot read private repos still renders, but the language mix
# quietly drops to public-only, which looks like a healthy card.
private=$(jq '[.data.user.repos.nodes[] | select(.isPrivate)] | length' <<<"$data")
[ "$private" -gt 0 ] ||
	echo "::warning::no private repos visible. either you have none, or the token cannot read them, and then the language mix is public-only"
# $days flattens the calendar so the busiest day only walks it once.
IFS=$'\t' read -r name since stars prs merged issues busiest busiest_date commits nextpage < <(jq -r '
  (.data.user.calendar.contributionCalendar.weeks | map(.contributionDays) | add) as $days
  | [ (.data.user.name // .data.user.login),
      (.data.user.createdAt | split("-")[0]),
      ([.data.user.repos.nodes[].stargazerCount] | add // 0),
      .data.user.prs.totalCount,
      .data.user.merged.totalCount,
      (.data.user.openIssues.totalCount + .data.user.closedIssues.totalCount),
      ($days | max_by(.contributionCount) | .contributionCount),
      ($days | max_by(.contributionCount) | .date),
      ([.data.user | to_entries[] | select(.key | test("^y[0-9]+$"))
        | (.value.totalCommitContributions + .value.restrictedContributionsCount)] | add // 0),
      .data.user.repos.pageInfo.hasNextPage
    ] | @tsv' <<<"$data")

[ "$nextpage" = "true" ] && echo "warning: more than 100 owned repos, only the first 100 are counted" >&2

# all-time distinct repos contributed to, excluding the user's own repos, so
# this stays a reach metric rather than counting every personal project.
contribs=$(jq -r --arg me "$USER_NAME/" '
  [ .data.user | to_entries[] | select(.key | test("^y[0-9]+$"))
    | (.value.commitContributionsByRepository[]?.repository.nameWithOwner,
       .value.issueContributionsByRepository[]?.repository.nameWithOwner,
       .value.pullRequestContributionsByRepository[]?.repository.nameWithOwner,
       (.value.repositoryContributions.nodes[]?.repository.nameWithOwner)) ]
  | map(select(. != null and (startswith($me) | not))) | unique | length
' <<<"$data")

# the display name is the only user-controlled string that reaches the SVG,
# and it can contain & or <, which would produce invalid XML.
name_svg=$(printf '%s' "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

# under 1000 plain, otherwise one decimal and a k, rounded.
kfmt() {
	local n=$1
	if [ "$n" -lt 1000 ]; then
		printf '%s' "$n"
		return
	fi
	local tenths=$(((n + 50) / 100))
	printf '%s.%sk' $((tenths / 10)) $((tenths % 10))
}

values=("$(kfmt "$stars")" "$(kfmt "$commits")" "$(kfmt "$prs")" "$(kfmt "$merged")"
"$(kfmt "$issues")" "$(kfmt "$contribs")" "$(kfmt "$busiest")")
labels=("Total Stars Earned" "Total Commits" "Total PRs" "Merged PRs"
	"Total Issues" "Repos contributed" "Busiest day")
icons=("star" "commits" "prs" "prs_merged" "issues" "contribs" "flame")

# the API hands back colors already prefixed, so strip it: the templates add #.
# percentages are normalised over the displayed set, which is why they sum to
# 100 and why they match the card this replaces.
langs=$(jq -r --arg skip "$EXCLUDE_REPOS" --argjson n "$LANGS_COUNT" --argjson barw "$BAR_W" '
  ($skip | split(" ") | map(select(length > 0))) as $skip
  | [ .data.user.repos.nodes[]
      | . as $r
      | select(($skip | index($r.name)) == null)
      | .languages.edges[] ]
  | group_by(.node.name)
  | map({name: .[0].node.name, color: (.[0].node.color // "8b949e" | ltrimstr("#")), size: (map(.size) | add)})
  | sort_by(-.size)
  | .[0:$n]
  | (map(.size) | add) as $total
  | reduce .[] as $l ({x: 0, rows: []};
      ($l.size * 100 / $total) as $p
      | {x: (.x + $p * $barw / 100),
         rows: (.rows + [{name: $l.name, color: $l.color, pct: $p,
                          x: .x, w: ($p * $barw / 100 + 0.6)}])})
  | .rows[]
  | "\(.x)\t\(.w)\t\(.pct)\t\(.color)\t\(.name)"
' <<<"$data")

# ------------------------------------------------------------------ geometry
# the parts that need the data: the grid rows follow the actual language count
# (a user with five languages gets two columns, not one) and the card is sized
# by the taller of the two columns.
n_langs=$(awk 'END { print NR }' <<<"$langs")
if [ "$n_langs" -eq 0 ]; then
	echo "no languages found for $USER_NAME" >&2
	exit 1
fi
ROWS_PER_COL=$(((n_langs + 1) / 2))

STAT_BOTTOM=$((STAT_Y + (${#labels[@]} - 1) * STAT_ROW + 16))
LANG_BOTTOM=$((LANG_Y + (ROWS_PER_COL - 1) * LANG_ROW + 12))
CARD_H=$(((STAT_BOTTOM > LANG_BOTTOM ? STAT_BOTTOM : LANG_BOTTOM) + PAD))

# ------------------------------------------------------------------ render
mkdir -p "$(dirname "$OUT_FILE")"

# palette-dependent CSS. emitted twice when a dark palette is set:
# once as the base, once inside the media query.
theme_css() { # bg title text icon
	cat <<EOF
    .bg { fill: #$1; stroke: #$2; stroke-opacity: 0.3; }
    .header { font-size: 18px; font-weight: 600; fill: #$2; }
    .sub { font-size: 12px; fill: #$3; opacity: 0.55; }
    .stat { font-size: 14px; font-weight: 600; fill: #$3; }
    .lang { font-size: 13px; fill: #$3; }
    .icon { fill: #$4; }
EOF
}

# sets P_BG P_TITLE P_TEXT P_ICON from a catalog name, or returns 1
palette_of() {
	local entry
	for entry in "${CATALOG[@]}"; do
		case "$entry" in
		"$1:"*)
			IFS=: read -r _ P_BG P_TITLE P_TEXT P_ICON <<<"$entry"
			return 0
			;;
		esac
	done
	return 1
}

# the base palette is the light one; the second name goes inside a
# prefers-color-scheme query, which outranks the base rules.
read -r light dark <<<"$THEME"
[ -n "$light" ] || {
	echo "THEME must name a palette" >&2
	exit 1
}
[ -n "$dark" ] || dark=$light

palette_of "$light" || {
	echo "unknown theme '$light'. available: $THEME_NAMES" >&2
	exit 1
}
css=$(theme_css "$P_BG" "$P_TITLE" "$P_TEXT" "$P_ICON")

if [ "$dark" != "$light" ]; then
	palette_of "$dark" || {
		echo "unknown theme '$dark'. available: $THEME_NAMES" >&2
		exit 1
	}
	css+="
    @media (prefers-color-scheme: dark) {
$(theme_css "$P_BG" "$P_TITLE" "$P_TEXT" "$P_ICON")
    }"
fi

out="$OUT_FILE"
bar_rects=""
lang_rows=""
desc_langs=""
i=0
while IFS=$'\t' read -r x w pct color lname; do
	[ -n "${lname:-}" ] || continue

	# segments overlap by a fraction of a pixel so sub 1px languages do not
	# antialias into dark hairlines; the rounded clip owns the outer corners.
	bar_rects+=$(printf '<rect x="%.2f" y="0" width="%.2f" height="8" fill="#%s"/>' \
		"$x" "$w" "$color")

	col=$((i / ROWS_PER_COL))
	row=$((i % ROWS_PER_COL))
	lx=$((LANG_X + col * LANG_COL))
	ly=$((LANG_Y + row * LANG_ROW))
	lang_rows+=$(printf '<g transform="translate(%d, %d)"><circle cx="5" cy="6" r="5" fill="#%s"/><text class="lang" x="15" y="10">%s</text><text class="lang num" x="%d" y="10" text-anchor="end">%.1f%%</text></g>' \
		"$lx" "$ly" "$color" "$lname" "$((LANG_COL - LANG_GUTTER))" "$pct")

	desc_langs+=$(printf '%s %.1f%%, ' "$lname" "$pct")
	i=$((i + 1))
done <<<"$langs"

stat_rows=""
desc_stats=""
for idx in "${!labels[@]}"; do
	y=$((STAT_Y + idx * STAT_ROW))
	stat_rows+=$(printf '<g transform="translate(%d, %d)"><use href="#i-%s" class="icon" width="16" height="16"/><text class="stat" x="%d" y="12.5">%s</text><text class="stat num" x="%d" y="12.5" text-anchor="end">%s</text></g>' \
		"$STAT_X" "$y" "${icons[idx]}" "$STAT_LABEL_X" "${labels[idx]}" "$STAT_VALUE_X" "${values[idx]}")
	desc_stats+=$(printf '%s %s, ' "${labels[idx]}" "${values[idx]}")
done

cat >"$out" <<EOF
<svg width="$CARD_W" height="$CARD_H" viewBox="0 0 $CARD_W $CARD_H" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="titleId descId">
  <title id="titleId">$name_svg's GitHub Stats</title>
  <desc id="descId">$desc_stats on $busiest_date. Most used languages: $desc_langs</desc>
  <style>
    text { font-family: system-ui, sans-serif; }
    .num { font-variant-numeric: tabular-nums; font-feature-settings: "tnum" 1; }
$css
  </style>
  <defs>
    <clipPath id="bar-clip"><rect x="0" y="0" width="$BAR_W" height="8" rx="$BAR_RADIUS"/></clipPath>
    <symbol id="i-star" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25zm0 2.445L6.615 5.5a.75.75 0 01-.564.41l-3.097.45 2.24 2.184a.75.75 0 01.216.664l-.528 3.084 2.769-1.456a.75.75 0 01.698 0l2.77 1.456-.53-3.084a.75.75 0 01.216-.664l2.24-2.183-3.096-.45a.75.75 0 01-.564-.41L8 2.694v.001z"/></symbol>
    <symbol id="i-commits" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M1.643 3.143L.427 1.927A.25.25 0 000 2.104V5.75c0 .138.112.25.25.25h3.646a.25.25 0 00.177-.427L2.715 4.215a6.5 6.5 0 11-1.18 4.458.75.75 0 10-1.493.154 8.001 8.001 0 101.6-5.684zM7.75 4a.75.75 0 01.75.75v2.992l2.028.812a.75.75 0 01-.557 1.392l-2.5-1A.75.75 0 017 8.25v-3.5A.75.75 0 017.75 4z"/></symbol>
    <symbol id="i-prs" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M7.177 3.073L9.573.677A.25.25 0 0110 .854v4.792a.25.25 0 01-.427.177L7.177 3.427a.25.25 0 010-.354zM3.75 2.5a.75.75 0 100 1.5.75.75 0 000-1.5zm-2.25.75a2.25 2.25 0 113 2.122v5.256a2.251 2.251 0 11-1.5 0V5.372A2.25 2.25 0 011.5 3.25zM11 2.5h-1V4h1a1 1 0 011 1v5.628a2.251 2.251 0 101.5 0V5A2.5 2.5 0 0011 2.5zm1 10.25a.75.75 0 111.5 0 .75.75 0 01-1.5 0zM3.75 12a.75.75 0 100 1.5.75.75 0 000-1.5z"/></symbol>
    <symbol id="i-prs_merged" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z"/></symbol>
    <symbol id="i-issues" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M8 1.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13zM0 8a8 8 0 1116 0A8 8 0 010 8zm9 3a1 1 0 11-2 0 1 1 0 012 0zm-.25-6.25a.75.75 0 00-1.5 0v3.5a.75.75 0 001.5 0v-3.5z"/></symbol>
    <symbol id="i-contribs" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M2 2.5A2.5 2.5 0 014.5 0h8.75a.75.75 0 01.75.75v12.5a.75.75 0 01-.75.75h-2.5a.75.75 0 110-1.5h1.75v-2h-8a1 1 0 00-.714 1.7.75.75 0 01-1.072 1.05A2.495 2.495 0 012 11.5v-9zm10.5-1V9h-8c-.356 0-.694.074-1 .208V2.5a1 1 0 011-1h8zM5 12.25v3.25a.25.25 0 00.4.2l1.45-1.087a.25.25 0 01.3 0L8.6 15.7a.25.25 0 00.4-.2v-3.25a.25.25 0 00-.25-.25h-3.5a.25.25 0 00-.25.25z"/></symbol>
    <symbol id="i-flame" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M9.533.753V.752c.217 2.385 1.463 3.626 2.653 4.81C13.37 6.74 14.498 7.863 14.498 10c0 3.5-3 6-6.5 6S1.5 13.512 1.5 10c0-1.298.536-2.56 1.425-3.286.376-.308.862 0 1.035.454C4.46 8.487 5.581 8.419 6 8c.282-.282.341-.811-.003-1.5C4.34 3.187 7.035.75 8.77.146c.39-.137.726.194.763.607ZM7.998 14.5c2.832 0 5-1.98 5-4.5 0-1.463-.68-2.19-1.879-3.383l-.036-.037c-1.013-1.008-2.3-2.29-2.834-4.434-.322.256-.63.579-.864.953-.432.696-.621 1.58-.046 2.73.473.947.67 2.284-.278 3.232-.61.61-1.545.84-2.403.633a2.79 2.79 0 0 1-1.436-.874A3.198 3.198 0 0 0 3 10c0 2.53 2.164 4.5 4.998 4.5Z"/></symbol>
  </defs>
  <rect class="bg" x="0.5" y="0.5" width="$((CARD_W - 1))" height="$((CARD_H - 1))" rx="8"/>
  <text class="header" x="$PAD" y="45">$name_svg's GitHub Stats</text>
  <text class="sub" x="$((CARD_W - PAD))" y="45" text-anchor="end">since $since</text>
  <g transform="translate($BAR_X, $BAR_Y)"><g clip-path="url(#bar-clip)">$bar_rects</g></g>
  $stat_rows
  $lang_rows
</svg>
EOF

echo "wrote $out"

echo "$name: ${values[*]} | busiest $busiest on $busiest_date" >&2
