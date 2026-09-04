#!/usr/bin/env bash
# Overleaf requires Mongo to run as a (single-node) replica set. The official
# toolkit's `bin/up` does this automatically on every `docker compose up`;
# since we're running plain Podman + Quadlet with no such wrapper, this
# script reproduces that one step by hand. It's idempotent (safe to re-run)
# and only actually needs to be run once, right after the first
# `systemctl start mongo.service`.
set -euo pipefail

# This is a rootful deployment (containers created by root's systemd via
# Quadlet), so a plain user-level `podman exec` can't see the `mongo`
# container at all -- rootful and rootless Podman use separate container
# stores. `sudo` here talks to the same rootful Podman that owns it.
echo "Waiting for Mongo to accept connections..."
until sudo podman exec mongo mongosh --quiet --eval "db.version()" >/dev/null 2>&1; do
  sleep 1
done

sudo podman exec mongo mongosh --quiet --eval '
  db.isMaster().primary || rs.initiate({ _id: "overleaf", members: [ { _id: 0, host: "mongo:27017" } ] })
'

echo "Mongo replica set 'overleaf' is ready."
