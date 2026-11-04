#!/bin/sh
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# Realm setup for the agent API, run with kcadm inside the Keycloak pod. Idempotent.
# Arguments: realm admin-user api-client api-owner api-email audience; the admin password on stdin.
set -eu
REALM=$1 ADMIN=$2 CLIENT=$3 OWNER=$4 EMAIL=$5 AUD=$6
IFS= read -r KC_CLI_PASSWORD || :; export KC_CLI_PASSWORD
KC=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm-agent-backend.config
trap 'rm -f "$CFG"' EXIT
k() { sub=$1; shift; "$KC" "$sub" --config "$CFG" -r "$REALM" "$@"; }
"$KC" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN" >/dev/null

# Roles, each a composite of the one below: agent-viewer < agent-editor < agent-admin < platform-admin.
prev=""
for role in agent-viewer agent-editor agent-admin platform-admin; do
  k get "roles/$role" >/dev/null 2>&1 || { k create roles -s "name=$role" >/dev/null && echo "CREATED role $role"; }
  [ -z "$prev" ] || k add-roles --rname "$role" --rolename "$prev"
  prev=$role
done
k add-roles --rname "default-roles-$REALM" --rolename agent-viewer --rolename agent-editor

# Scopes a token may carry; each only names itself in the `scope` claim.
# The Keycloak image has no awk, so lists are read with the shell alone.
scope_id() {
  k get client-scopes --fields id,name --format csv --noquotes | while IFS=, read -r id name; do
    [ "$name" != "$1" ] || echo "$id"
  done
}
has_line() { printf '%s\n' "$1" | while IFS= read -r l; do [ "$l" != "$2" ] || echo y; done; }
for s in agent:read agent:write agent:converse agent:grant; do
  [ -n "$(scope_id "$s")" ] || { k create client-scopes -s "name=$s" -s protocol=openid-connect \
    -s 'attributes."include.in.token.scope"=true' -s 'attributes."display.on.consent.screen"=false' >/dev/null &&
    echo "CREATED scope $s"; }
done

# The API client: client credentials only, its tokens for audience $AUD, scopes requested per call.
cid=$(k get clients -q "clientId=$CLIENT" --fields id --format csv --noquotes)
if [ -z "$cid" ]; then
  cid=$(k create clients -i -s "clientId=$CLIENT" -s enabled=true -s publicClient=false \
    -s serviceAccountsEnabled=true -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
    -s implicitFlowEnabled=false)
  echo "CREATED client $CLIENT"
fi
mappers=$(k get "clients/$cid/protocol-mappers/models" --fields name --format csv --noquotes)
[ -n "$(has_line "$mappers" audience)" ] || k create "clients/$cid/protocol-mappers/models" -s name=audience \
  -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper -s "config.\"included.custom.audience\"=$AUD" \
  -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null
# Service-account usernames carry hyphens, so the owner is named by a claim of its own.
[ -n "$(has_line "$mappers" owner-username)" ] || k create "clients/$cid/protocol-mappers/models" -s name=owner-username \
  -s protocol=openid-connect -s protocolMapper=oidc-hardcoded-claim-mapper -s 'config."claim.name"=owner_username' \
  -s "config.\"claim.value\"=$OWNER" -s 'config."jsonType.label"=String' -s 'config."access.token.claim"=true' \
  -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null
# email_verified as a string: the agent dashboards' gateway policy can match only string claims.
[ -n "$(has_line "$mappers" email-verified-string)" ] || k create "clients/$cid/protocol-mappers/models" \
  -s name=email-verified-string -s protocol=openid-connect -s protocolMapper=oidc-usermodel-property-mapper \
  -s 'config."user.attribute"=emailVerified' -s 'config."claim.name"=email_verified_string' \
  -s 'config."jsonType.label"=String' -s 'config."access.token.claim"=true' \
  -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null
for s in agent:read agent:write agent:converse agent:grant; do
  k update "clients/$cid/optional-client-scopes/$(scope_id "$s")" >/dev/null
done
uid=$(k get users -q "username=service-account-$CLIENT" -q exact=true --fields id --format csv --noquotes)
k update "users/$uid" -s "email=$EMAIL" -s emailVerified=true
k add-roles --uusername "service-account-$CLIENT" --rolename agent-editor
echo "CLIENT_SECRET=$(k get "clients/$cid/client-secret" --fields value --format csv --noquotes)"
