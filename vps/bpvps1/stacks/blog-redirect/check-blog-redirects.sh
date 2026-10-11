#!/usr/bin/env bash
# Check every rule in blog-redirects.conf against the live blog.kaiteki.my.
#
#   vps/bpvps1/stacks/blog-redirect/check-blog-redirects.sh [base-url]
#
# base-url defaults to https://blog.kaiteki.my. Point it at a local container
# (http://localhost:18080) to test the config before a deploy. Exit 0 when every
# rule answers as written, 1 otherwise. Prints each mismatch.
set -euo pipefail

BASE="${1:-https://blog.kaiteki.my}"
CONF="$(dirname "$0")/blog-redirects.conf"

fail=0
total=0

# Percent-encode non-ASCII bytes the way a browser would (a few image names hold
# a "×"); nginx decodes $uri before the map lookup either way.
urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9/._~:@!\$\&\'\(\)\*+,\;=%-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

check() { # check <path> <want>
  local got
  got=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE$(urlencode "$1")")
  total=$((total + 1))
  if [ "${got% }" != "$2" ]; then
    echo "MISMATCH $1: got [$got] want [$2]"
    fail=1
  fi
}

# "from" "to"; lines inside the map blocks.
while read -r from to; do
  check "$from" "301 $to"
done < <(sed -n '/^map \$uri \$blog_target/,/^}/p' "$CONF" | grep '^    "' | sed -E 's/^ +"([^"]*)" "([^"]*)";$/\1 \2/')

while read -r from; do
  check "$from" "410"
done < <(sed -n '/^map \$uri \$blog_gone/,/^}/p' "$CONF" | grep '^    "' | sed -E 's/^ +"([^"]*)" 1;$/\1/')

check "/" "301 https://kaiteki.my/blog"

echo "$total checked, $([ $fail = 0 ] && echo 'all match' || echo 'MISMATCHES above')"
exit $fail
