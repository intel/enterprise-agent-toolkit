#!/bin/sh
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# The console's sign-in client, run with kcadm inside the Keycloak pod. Idempotent.
# Arguments: realm admin-user client origin audience; the admin password on stdin.
set -eu
REALM=$1 ADMIN=$2 CLIENT=$3 ORIGIN=$4 AUD=$5
IFS= read -r KC_CLI_PASSWORD || :; export KC_CLI_PASSWORD
KC=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm-agent-console.config
trap 'rm -f "$CFG"' EXIT
k() { sub=$1; shift; "$KC" "$sub" --config "$CFG" -r "$REALM" "$@"; }
"$KC" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN" >/dev/null

# Authorization code with PKCE only; callbacks for the console and each agent dashboard.
cid=$(k get clients -q "clientId=$CLIENT" --fields id --format csv --noquotes)
if [ -z "$cid" ]; then
  cid=$(k create clients -i -s "clientId=$CLIENT" -s enabled=true -s publicClient=false)
  echo "CREATED client $CLIENT"
fi
k update "clients/$cid" -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s implicitFlowEnabled=false \
  -s serviceAccountsEnabled=false -s "redirectUris=[\"$ORIGIN/oauth2/callback\",\"$ORIGIN/gw/*\"]" -s "webOrigins=[\"$ORIGIN\"]" \
  -s 'attributes."pkce.code.challenge.method"=S256' -s "attributes.\"post.logout.redirect.uris\"=$ORIGIN/*"
mappers=$(k get "clients/$cid/protocol-mappers/models" --fields name --format csv --noquotes)
case "
$mappers
" in *"
audience
"*) ;; *) k create "clients/$cid/protocol-mappers/models" -s name=audience -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper -s "config.\"included.custom.audience\"=$AUD" \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null && echo "CREATED mapper audience" ;;
esac
# A browser session cannot ask for scopes per call, so the console's tokens carry all of them.
k get client-scopes --fields id,name --format csv --noquotes | while IFS=, read -r id name; do
  case "$name" in agent:read|agent:write|agent:converse|agent:grant) k update "clients/$cid/default-client-scopes/$id" ;; esac
done
echo "CLIENT_SECRET=$(k get "clients/$cid/client-secret" --fields value --format csv --noquotes)"
