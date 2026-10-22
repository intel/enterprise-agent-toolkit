#!/bin/sh
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# Removes what keycloak-realm.sh and keycloak-console.sh created.
# Arguments: realm admin-user admin-password client...
set -eu
REALM=$1 ADMIN=$2 PASS=$3
shift 3
KC=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm-agent-backend.config
trap 'rm -f "$CFG"' EXIT
k() { sub=$1; shift; "$KC" "$sub" --config "$CFG" -r "$REALM" "$@"; }
"$KC" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN" --password "$PASS" >/dev/null
for client in "$@"; do
  cid=$(k get clients -q "clientId=$client" --fields id --format csv --noquotes)
  [ -z "$cid" ] || { k delete "clients/$cid" && echo "DELETED client $client"; }
done
for s in agent:read agent:write agent:converse agent:grant; do
  k get client-scopes --fields id,name --format csv --noquotes | while IFS=, read -r id name; do
    [ "$name" != "$s" ] || { k delete "client-scopes/$id" && echo "DELETED scope $s"; }
  done
done
for role in platform-admin agent-admin agent-editor agent-viewer; do
  ! k get "roles/$role" >/dev/null 2>&1 || { k delete "roles/$role" && echo "DELETED role $role"; }
done
