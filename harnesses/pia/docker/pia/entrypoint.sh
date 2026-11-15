#!/bin/sh
# Keep-alive entrypoint for the pia agent container.
#
# The container itself only idles. The interactive pi session is started by
# the pia CLI via 'docker exec -it <name> pi [pi-args]' — for both 'pia run'
# (fresh session) and 'pia rs' (continue the last session). This is what lets
# 'docker start' revive a stopped container without a TTY and without losing
# its filesystem/session state, then attach pi with arguments afterwards
# ('docker start' cannot pass arguments to an entrypoint).
#
# Note: a TTY check cannot be used here — containers created with '-it' keep
# a TTY on their streams even when later started detached.
#
# Direct docker users can still start pi immediately, e.g.:
#   docker run -it pia pi --continue

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# Destination logger backing 'pia urls': appends every request destination
# (TLS SNI hostnames, cleartext HTTP URLs) to a log inside the container for
# its whole life. Started here — not by the pia CLI — so every container start
# revives it, including 'docker start' and 'pia rs'. Best effort and silent:
# an image without the helper or tshark simply logs nothing. Containers that
# run a command instead of idling (the 'exec "$@"' path above) get no logger.
if command -v pia-monitor > /dev/null 2>&1; then
    pia-monitor log > /dev/null 2>&1 &
fi

exec sleep infinity
