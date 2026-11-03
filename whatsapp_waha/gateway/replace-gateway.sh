#!/usr/bin/env bash
# Replaces the netagent-gateway container with a new image, copying every
# setting from the running container. The old container is only stopped and
# renamed, never deleted, and is restored automatically if anything fails
# after the first change, including Ctrl+C or a dropped SSH session.
#
#   bash replace-gateway.sh /root/netagent-gateway-expiry-scheduler.tar
set -euo pipefail

TAR="${1:?usage: replace-gateway.sh <image.tar>}"
NAME=netagent-gateway
NEW_IMAGE=netagent-gateway:expiry-scheduler
STAMP=$(date +%Y%m%d-%H%M%S)
OLD_NAME="${NAME}-old-${STAMP}"
WORK=$(mktemp -d /root/gateway-deploy-XXXXXX)
chmod 700 "$WORK"

# PHASE says how far the swap got, so the exit handler knows what to undo.
#   checks  nothing has been changed yet
#   swap    the old container may have been changed; roll back on any exit
#   done    the new container passed every check; keep it
PHASE=checks
OLD_ID=""
RESTART_SPEC=no
PORT=3001

# Health probe: node inside the container, then busybox wget inside the
# container, then curl from the host to the container's IP.
probe() {
  local target=$1 url="http://127.0.0.1:${PORT}/healthz" ip
  docker exec "$target" node -e "fetch('$url').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" >/dev/null 2>&1 && return 0
  docker exec "$target" wget -qO- "$url" >/dev/null 2>&1 && return 0
  if command -v curl >/dev/null 2>&1; then
    for ip in $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$target" 2>/dev/null); do
      curl -fsS -m 3 "http://${ip}:${PORT}/healthz" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

rollback() {
  set +e
  echo
  echo "Restoring the old container ($OLD_ID)."
  local failed=0 current
  # Remove only a container that is not the old one.
  current=$(docker ps -aq --no-trunc --filter "name=^/${NAME}\$")
  if [ -n "$current" ] && [ "$current" != "$OLD_ID" ]; then
    echo "Last log lines of the new container:"
    docker logs "$current" 2>&1 | tail -n 20
    docker rm -f "$current" >/dev/null || failed=1
  fi
  if [ "$(docker inspect -f '{{.Name}}' "$OLD_ID")" != "/$NAME" ]; then
    docker rename "$OLD_ID" "$NAME" || failed=1
  fi
  docker update --restart="$RESTART_SPEC" "$OLD_ID" >/dev/null || failed=1
  if [ "$(docker inspect -f '{{.State.Running}}' "$OLD_ID")" != "true" ]; then
    docker start "$OLD_ID" >/dev/null || failed=1
  fi
  local healthy=no
  for _ in $(seq 1 15); do
    sleep 2
    if probe "$OLD_ID"; then healthy=yes; break; fi
  done
  if [ "$failed" = 0 ] && [ "$healthy" = yes ]; then
    echo "Old container restored, running and healthy as $NAME."
  else
    echo "ROLLBACK INCOMPLETE. Run these by hand:"
    echo "  docker rm -f \$(docker ps -aq --filter name=^/${NAME}\$ | grep -v ${OLD_ID:0:12})"
    echo "  docker rename $OLD_ID $NAME"
    echo "  docker update --restart=$RESTART_SPEC $NAME"
    echo "  docker start $NAME"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  # The rollback itself must not be interrupted.
  trap '' INT TERM HUP
  if [ "$PHASE" = swap ]; then
    rollback
    status=1
  elif [ "$PHASE" = checks ] && [ "$status" != 0 ]; then
    echo "Stopped during checks; nothing was changed."
  fi
  rm -rf "$WORK"
  exit "$status"
}
# Armed before anything is changed. set -e failures, explicit exits, Ctrl+C,
# kill and SSH hangup all pass through finish.
trap finish EXIT
trap 'exit 130' INT TERM HUP

inspect() { docker inspect -f "$1" "$OLD_ID"; }

# ---------- 1. Checks. Nothing is changed in this step. ----------
OLD_ID=$(docker inspect -f '{{.Id}}' "$NAME")
[ "$(inspect '{{.State.Running}}')" = "true" ] || { echo "$NAME is not running."; exit 1; }
OLD_IMAGE=$(inspect '{{.Config.Image}}')
echo "Current container: ${OLD_ID:0:12}, image: $OLD_IMAGE"

# Stop if the container uses a setting this script does not copy.
UNSUPPORTED=""
[ "$(inspect '{{json .Config.Entrypoint}}')" = "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$OLD_IMAGE")" ] || UNSUPPORTED+=" entrypoint"
[ "$(inspect '{{json .Config.Cmd}}')" = "$(docker image inspect -f '{{json .Config.Cmd}}' "$OLD_IMAGE")" ] || UNSUPPORTED+=" command"
[ "$(inspect '{{len .HostConfig.Devices}}')" = "0" ] || UNSUPPORTED+=" devices"
[ "$(inspect '{{len .HostConfig.Links}}')" = "0" ] || UNSUPPORTED+=" links"
[ -z "$(inspect '{{.HostConfig.PidMode}}{{.HostConfig.UTSMode}}')" ] || UNSUPPORTED+=" pid/uts-mode"
[ -z "$(inspect '{{range .NetworkSettings.Networks}}{{if .IPAMConfig}}{{.IPAMConfig.IPv4Address}}{{end}}{{end}}')" ] || UNSUPPORTED+=" static-ip"
[ -z "$(inspect '{{if .Config.Healthcheck}}yes{{end}}')" ] || UNSUPPORTED+=" healthcheck"
case "$(inspect '{{.HostConfig.NetworkMode}}')" in
  host|none|container:*) UNSUPPORTED+=" network-mode" ;;
esac
if [ -n "$UNSUPPORTED" ]; then
  echo "Container uses settings this script does not copy:$UNSUPPORTED"
  exit 1
fi
if docker inspect "$OLD_NAME" >/dev/null 2>&1; then echo "$OLD_NAME already exists."; exit 1; fi

docker load -i "$TAR"
FILES=$(docker run --rm --entrypoint ls "$NEW_IMAGE" /app)
echo "$FILES" | grep -qx expiry_scheduler.js
echo "$FILES" | grep -qx server.js
echo "Image contains server.js and expiry_scheduler.js"

# ---------- 2. Copy the settings of the current container. ----------
# Env without the variables the image itself defines. Values are never printed.
inspect '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -v -E '^(PATH|NODE_VERSION|YARN_VERSION|NODE_ENV|EXPIRY_SCHEDULER_ENABLED)=' \
  | sed '/^$/d' > "$WORK/env" || true
chmod 600 "$WORK/env"
if grep -q '^PORT=' "$WORK/env"; then PORT=$(grep '^PORT=' "$WORK/env" | tail -n1 | cut -d= -f2-); fi

# Primary network is the one the container was started with; the rest are
# connected afterwards. Each network keeps its own aliases.
SHORT_ID=${OLD_ID:0:12}
NETWORKS=$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | sed '/^$/d')
PRIMARY=$(inspect '{{.HostConfig.NetworkMode}}')
[ "$PRIMARY" = "default" ] && PRIMARY=bridge
echo "$NETWORKS" | grep -qx -- "$PRIMARY" || PRIMARY=$(echo "$NETWORKS" | head -n1)
EXTRA_NETWORKS=$(echo "$NETWORKS" | grep -vx -- "$PRIMARY" || true)

aliases_for() {
  inspect "{{with index .NetworkSettings.Networks \"$1\"}}{{range .Aliases}}{{println .}}{{end}}{{end}}" \
    | sed '/^$/d' | grep -vx -e "$SHORT_ID" -e "$NAME" || true
}

# Read every network's aliases now, while the old container is still running.
declare -A ALIASES
for network in $NETWORKS; do ALIASES[$network]=$(aliases_for "$network" | tr '\n' ' '); done

ARGS=(--name "$NAME" --env-file "$WORK/env" --network "$PRIMARY")
for alias in ${ALIASES[$PRIMARY]}; do ARGS+=(--network-alias "$alias"); done

# Data folders, the Firebase credential, and any named volumes, same paths and modes.
while IFS='|' read -r type source vname destination rw; do
  [ -z "$destination" ] && continue
  if [ "$rw" = "true" ]; then mode=""; else mode=":ro"; fi
  if [ "$type" = "volume" ]; then ARGS+=(-v "${vname}:${destination}${mode}"); else ARGS+=(-v "${source}:${destination}${mode}"); fi
done < <(inspect '{{range .Mounts}}{{printf "%s|%s|%s|%s|%t\n" .Type .Source .Name .Destination .RW}}{{end}}')

while read -r port; do
  if [ -n "$port" ]; then ARGS+=(-p "$port"); fi
done < <(inspect '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}}{{println}}{{end}}{{end}}')

RESTART=$(inspect '{{.HostConfig.RestartPolicy.Name}}')
RETRIES=$(inspect '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
if [ -n "$RESTART" ] && [ "$RESTART" != "no" ]; then
  RESTART_SPEC=$RESTART
  if [ "$RESTART" = "on-failure" ] && [ "$RETRIES" != "0" ]; then RESTART_SPEC="on-failure:$RETRIES"; fi
  ARGS+=(--restart "$RESTART_SPEC")
fi
if [ "$(inspect '{{.HostConfig.ReadonlyRootfs}}')" = "true" ]; then ARGS+=(--read-only); fi
if [ "$(inspect '{{if .HostConfig.Init}}{{.HostConfig.Init}}{{end}}')" = "true" ]; then ARGS+=(--init); fi
while read -r t; do if [ -n "$t" ]; then ARGS+=(--tmpfs "$t"); fi; done < <(inspect '{{range $k, $v := .HostConfig.Tmpfs}}{{$k}}{{if $v}}:{{$v}}{{end}}{{println}}{{end}}')
while read -r c; do if [ -n "$c" ]; then ARGS+=(--cap-drop "$c"); fi; done < <(inspect '{{range .HostConfig.CapDrop}}{{println .}}{{end}}')
while read -r c; do if [ -n "$c" ]; then ARGS+=(--cap-add "$c"); fi; done < <(inspect '{{range .HostConfig.CapAdd}}{{println .}}{{end}}')
while read -r o; do if [ -n "$o" ]; then ARGS+=(--security-opt "$o"); fi; done < <(inspect '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}')
while read -r h; do if [ -n "$h" ]; then ARGS+=(--add-host "$h"); fi; done < <(inspect '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}')
while read -r d; do if [ -n "$d" ]; then ARGS+=(--dns "$d"); fi; done < <(inspect '{{range .HostConfig.Dns}}{{println .}}{{end}}')
LOG_DRIVER=$(inspect '{{.HostConfig.LogConfig.Type}}')
if [ -n "$LOG_DRIVER" ]; then ARGS+=(--log-driver "$LOG_DRIVER"); fi
while read -r o; do if [ -n "$o" ]; then ARGS+=(--log-opt "$o"); fi; done < <(inspect '{{range $k, $v := .HostConfig.LogConfig.Config}}{{$k}}={{$v}}{{println}}{{end}}')
USER_SET=$(inspect '{{.Config.User}}')
if [ -n "$USER_SET" ]; then ARGS+=(--user "$USER_SET"); fi
MEMORY=$(inspect '{{.HostConfig.Memory}}')
if [ "$MEMORY" != "0" ]; then ARGS+=(--memory "$MEMORY"); fi
NANO_CPUS=$(inspect '{{.HostConfig.NanoCpus}}')
if [ "$NANO_CPUS" != "0" ]; then ARGS+=(--cpus "$(awk "BEGIN{print $NANO_CPUS/1000000000}")"); fi
STOP_TIMEOUT=$(inspect '{{if .Config.StopTimeout}}{{.Config.StopTimeout}}{{end}}')
if [ -n "$STOP_TIMEOUT" ]; then ARGS+=(--stop-timeout "$STOP_TIMEOUT"); fi

echo "Settings copied (env values not shown):"
printf '  %q\n' "${ARGS[@]}" | grep -v -- "$WORK/env"
echo "  env names: $(cut -d= -f1 "$WORK/env" | tr '\n' ' ')"
for network in $EXTRA_NETWORKS; do
  echo "  extra network: $network, aliases: ${ALIASES[$network]}"
done
echo "  restart policy: $RESTART_SPEC, health port: $PORT"

# ---------- 3. Swap. Every exit from here on restores the old container. ----------
PHASE=swap

docker update --restart=no "$OLD_ID" >/dev/null
docker stop "$OLD_ID" >/dev/null
docker rename "$OLD_ID" "$OLD_NAME"

# Create, connect every network with its aliases, then start, so the app
# never runs with a missing network.
NEW_ID=$(docker create "${ARGS[@]}" "$NEW_IMAGE")
for network in $EXTRA_NETWORKS; do
  CONNECT=(docker network connect)
  for alias in ${ALIASES[$network]}; do CONNECT+=(--alias "$alias"); done
  "${CONNECT[@]}" "$network" "$NEW_ID"
done
docker start "$NEW_ID" >/dev/null

HEALTHY=no
for _ in $(seq 1 15); do
  sleep 2
  [ "$(docker inspect -f '{{.State.Running}}' "$NEW_ID")" = "true" ] || break
  if probe "$NEW_ID"; then HEALTHY=yes; break; fi
done
[ "$HEALTHY" = "yes" ] || { echo "New container did not become healthy."; exit 1; }

# The scheduler's first run is 30 s after start; watch past it for a crash.
echo "Healthy. Watching 45 s for a crash or restart..."
for _ in $(seq 1 9); do
  sleep 5
  [ "$(docker inspect -f '{{.State.Running}}' "$NEW_ID")" = "true" ] || { echo "New container stopped."; exit 1; }
  [ "$(docker inspect -f '{{.RestartCount}}' "$NEW_ID")" = "0" ] || { echo "New container restarted."; exit 1; }
done
probe "$NEW_ID" || { echo "New container stopped answering /healthz."; exit 1; }

PHASE=done

docker logs "$NEW_ID" 2>&1 | tail -n 5
cat <<EOF

New container is running and healthy.
Old container kept stopped as: $OLD_NAME (${OLD_ID:0:12}, image $OLD_IMAGE)
Manual rollback:
  docker stop $NAME && docker rm $NAME
  docker rename $OLD_NAME $NAME
  docker update --restart=$RESTART_SPEC $NAME
  docker start $NAME
EOF
