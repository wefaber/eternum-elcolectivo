#!/usr/bin/env bash
# Blue/green deploy for the El Colectivo static site (repo wefaber/eternum-elcolectivo).
#
#   deploy/colectivo-static.sh <sha>          publish ./dist (the caller already ran bun run build)
#   deploy/colectivo-static.sh --rollback     flip nginx back to the previous slot, no rebuild
#   deploy/colectivo-static.sh --status       print the live slot and its revision
#
# Blue/green for a static site is two docroots plus one nginx snippet that points at one of them:
#
#   /home/hermes/colectivo-static/{blue,green}/dist     the two slots
#   /etc/nginx/snippets/colectivo-static-active.conf    `set $colectivo_static_root ...` (the live slot)
#
# The idle slot is overwritten and checked locally; only then the snippet moves. If the hostname does
# not end up serving the new entry asset, the snippet moves back on its own. The live slot is never
# touched while it is serving, so --rollback is a flip and not a rebuild.
#
# This script owns colectivo.eternum.lat and nothing else. Taking that apex over from
# wefaber/colectivo-site is a one-time migration (deploy/README.md): the vhost for the apex must
# include OUR snippet, not their colectivo-active.conf. The preflight checks exactly that, so a
# half-done takeover fails as "vhost still serves colectivo-site" instead of as a health check that
# gets a 200 from the wrong project — which is how the old /var/www deploy rolled back forever.
set -euo pipefail

SITE=colectivo-static
BASE="${COLECTIVO_STATIC_BASE:-/home/hermes/colectivo-static}"
STATE="${COLECTIVO_STATIC_STATE:-/home/hermes/deploy/state/$SITE}"
SNIPPET="${COLECTIVO_STATIC_SNIPPET:-/etc/nginx/snippets/$SITE-active.conf}"
DOMAIN="${COLECTIVO_STATIC_DOMAIN:-colectivo.eternum.lat}"
VHOST="${COLECTIVO_STATIC_VHOST:-/etc/nginx/sites-enabled/$DOMAIN}"
# Snippet de wefaber/colectivo-site. Si el vhost del apex lo incluye, el dominio todavia es suyo.
FOREIGN_SNIPPET=colectivo-active.conf
ORIGIN_IP="${COLECTIVO_STATIC_ORIGIN_IP:-167.114.2.210}"
DRY_RUN="${DRY_RUN:-0}"
TRIES="${TRIES:-15}"

NGINX=/usr/sbin/nginx
SYSTEMCTL=/usr/bin/systemctl
SLOTS=(blue green)

log() { printf '[%s %s] %s\n' "$SITE" "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
other() { [[ "$1" == blue ]] && echo green || echo blue; }

active_slot() { cat "$STATE/active" 2>/dev/null || echo ""; }
slot_ready() { [[ -f "$BASE/$1/dist/index.html" ]]; }
slot_entry() { grep -ohE '/assets/index-[A-Za-z0-9_-]+\.js' "$BASE/$1/dist/index.html" 2>/dev/null | head -1; }
slot_revision() { cat "$BASE/$1/REVISION" 2>/dev/null || echo "(none)"; }

write_snippet() { # slot
  printf '# written by deploy/colectivo-static.sh — live slot: %s\nset $colectivo_static_root %s/%s/dist;\n' \
    "$1" "$BASE" "$1"
}

# Read-only check of the one-time VPS setup (deploy/README.md, the numbers match). Lists everything
# that is missing and stops before the idle slot, the snippet or nginx are touched.
preflight() { # slot
  local slot=$1 miss=() cmd

  case "$SNIPPET" in
    */"$SITE-active.conf") ;;
    *) die "COLECTIVO_STATIC_SNIPPET must end in $SITE-active.conf, got: $SNIPPET" ;;
  esac

  [[ -d "$BASE" && -w "$BASE" ]] || miss+=("2. docroot base missing or not writable: $BASE (mkdir -p $BASE)")
  [[ -d "$STATE" && -w "$STATE" ]] || miss+=("2. state dir missing or not writable: $STATE (mkdir -p $STATE)")
  if [[ ! -f "$VHOST" ]]; then
    miss+=("3. no nginx vhost enabled at $VHOST (deploy/nginx/colectivo.conf)")
  elif grep -qs "$FOREIGN_SNIPPET" "$VHOST"; then
    miss+=("3. $VHOST still serves wefaber/colectivo-site (includes $FOREIGN_SNIPPET): install deploy/nginx/colectivo.conf first")
  elif ! grep -qs "$(basename "$SNIPPET")" "$VHOST"; then
    miss+=("3. $VHOST does not include $(basename "$SNIPPET")")
  fi
  [[ -f "$SNIPPET" ]] ||
    miss+=("4. nginx snippet missing: $SNIPPET (initial: $(write_snippet "$slot" | tr '\n' ' '))")
  [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] ||
    miss+=("5. no TLS certificate for $DOMAIN (deploy/README.md step 5)")

  for cmd in "/usr/bin/tee $SNIPPET" "/usr/sbin/nginx -t" "/usr/bin/systemctl reload nginx"; do
    # shellcheck disable=SC2086 # $cmd is a command line, split on purpose
    sudo -n -l $cmd >/dev/null 2>&1 || miss+=("6. sudoers does not allow, passwordless: sudo $cmd")
  done

  ((${#miss[@]} == 0)) && return 0
  log "preflight failed, the VPS setup is incomplete (deploy/README.md):"
  printf '  - %s\n' "${miss[@]}" >&2
  log "nothing was changed"
  return 1
}

# Move nginx to a slot. The previous snippet is kept so a failed `nginx -t` can be undone.
point_nginx_at() { # slot
  local slot=$1 prev
  prev="$(sudo -n cat "$SNIPPET" 2>/dev/null || true)"
  write_snippet "$slot" | sudo -n /usr/bin/tee "$SNIPPET" >/dev/null
  if ! sudo -n "$NGINX" -t 2>/dev/null; then
    log "nginx rejected the snippet pointing at $slot, restoring the previous one" >&2
    if [[ -n "$prev" ]]; then
      printf '%s\n' "$prev" | sudo -n /usr/bin/tee "$SNIPPET" >/dev/null
    fi
    return 1
  fi
  sudo -n "$SYSTEMCTL" reload nginx || return 1
}

# Two checks, in this order, because they fail for different reasons:
#   origin  — nginx is serving the new slot (SNI straight to the VPS IP, no Cloudflare in the way)
#   public  — DNS + Cloudflare + nginx all agree
serves() { # url, entry
  curl -s --max-time 5 "$1" 2>/dev/null | grep -q "$2"
}
wait_for() { # label, url, entry
  local label=$1 url=$2 entry=$3 i
  for ((i = 1; i <= TRIES; i++)); do
    serves "$url" "$entry" && return 0
    sleep 2
  done
  log "$label never served $entry (last try: $url)" >&2
  return 1
}

flip_to() { # slot
  local slot=$1 entry
  entry="$(slot_entry "$slot")"
  [[ -n "$entry" ]] || die "slot $slot has no hashed entry asset"
  point_nginx_at "$slot" || die "nginx did not accept slot $slot"
  echo "$slot" >"$STATE/active"
  if ! wait_for "origin ($DOMAIN @ $ORIGIN_IP)" "--resolve $DOMAIN:443:$ORIGIN_IP https://$DOMAIN/?deploy=$(date -u +%s)" "$entry"; then
    return 1
  fi
  if ! wait_for "public ($DOMAIN)" "https://$DOMAIN/?deploy=$(date -u +%s)" "$entry"; then
    return 1
  fi
  return 0
}

status() {
  local live; live="$(active_slot)"
  log "live slot: ${live:-(unknown)}"
  for s in "${SLOTS[@]}"; do
    log "  $s: rev $(slot_revision "$s")$( [[ $s == "$live" ]] && echo ' <- live')"
  done
}

# --- rollback ---------------------------------------------------------------------------------
if [[ "${1:-}" == --rollback ]]; then
  live="$(active_slot)"
  [[ -n "$live" ]] || die "no live slot recorded in $STATE/active"
  back="$(other "$live")"
  slot_ready "$back" || die "slot $back is empty, nothing to roll back to"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "$back" >"$STATE/active"
    log "dry run: would flip $DOMAIN from $live to $back; state moved to $back"
    status
    exit 0
  fi
  log "rollback: $live -> $back (rev $(slot_revision "$back"))"
  flip_to "$back" || { log "rollback failed, nginx stays on $live" >&2; exit 1; }
  log "rollback ok, $back is live"
  exit 0
fi

if [[ "${1:-}" == --status ]]; then status; exit 0; fi

# --- deploy -----------------------------------------------------------------------------------
SHA="${1:?usage: colectivo-static.sh <sha> | --rollback | --status}"
[[ -f dist/index.html ]] || die "run from the repo root after 'bun run build' (dist/index.html missing)"

ENTRY="$(grep -ohE '/assets/index-[A-Za-z0-9_-]+\.js' dist/index.html | head -1)"
[[ -n "$ENTRY" ]] || die "dist/index.html has no hashed entry asset"
[[ -f "dist$ENTRY" ]] || die "dist/index.html points at $ENTRY, which is not in dist/ (half-finished build)"

LIVE="$(active_slot)"
IDLE="$(other "${LIVE:-green}")"   # first run: pretend green is live so blue goes up first

preflight "$IDLE" || exit 2

log "deploying $SHA into $IDLE (live is ${LIVE:-(none)}, entry $ENTRY)"

# The idle slot is not serving anything, so wiping it is free. The live slot is untouched.
rm -rf "${BASE:?}/$IDLE"
mkdir -p "$BASE/$IDLE"
rsync -a dist/ "$BASE/$IDLE/dist/"
echo "$SHA" >"$BASE/$IDLE/REVISION"

# Catch a broken copy before nginx ever points at it.
if [[ "$(slot_entry "$IDLE")" != "$ENTRY" ]] || [[ ! -f "$BASE/$IDLE/dist$ENTRY" ]]; then
  die "the copy into $IDLE is incomplete, nginx was not touched"
fi

if [[ "$DRY_RUN" == 1 ]]; then
  # Sin nginx, pero el libro de slots es real: dos dry runs seguidos alternan de slot igual que un
  # deploy, y --rollback se puede probar sin tocar el servidor.
  echo "$IDLE" >"$STATE/active"
  log "dry run: nginx snippet that would be written:"
  write_snippet "$IDLE"
  log "dry run: would flip $DOMAIN to $IDLE ($LIVE left untouched); state moved to $IDLE"
  exit 0
fi

flip_to "$IDLE" || {
  if [[ -n "$LIVE" ]] && slot_ready "$LIVE"; then
    log "$DOMAIN did not serve the new build, flipping back to $LIVE" >&2
    point_nginx_at "$LIVE" || true
    echo "$LIVE" >"$STATE/active"
  else
    log "$DOMAIN did not serve the new build and there is no previous slot" >&2
    rm -f "$STATE/active"   # nothing is verified live: don't leave a slot recorded as active
  fi
  exit 1
}

log "ok: $SHA is live on https://$DOMAIN (slot $IDLE, $LIVE kept for --rollback)"
