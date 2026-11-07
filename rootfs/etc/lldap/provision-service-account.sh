#!/bin/sh
# Creates the "service" account in LLDAP, adds it to lldap_admin, and sets its password.
# Uses the initial admin login (LLDAP_LDAP_USER_PASS). The password is kept on the global_env volume.
set -eu

base=http://127.0.0.1:17180
svc_user=service
pass_file=/var/environment/global-env/lldap_service_password

[ -s "$pass_file" ] || openssl rand -hex 24 > "$pass_file"

i=0
until curl -fsS -o /dev/null "$base/"; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "lldap-service-account: LLDAP did not become ready" >&2
    exit 1
  fi
  sleep 1
done

login=$(jq -n --arg u admin --arg p "$LLDAP_LDAP_USER_PASS" '{username: $u, password: $p}')
token=$(curl -fsS -H 'Content-Type: application/json' -d "$login" "$base/auth/simple/login" | jq -r .token)

gql() {
  curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$1" "$base/api/graphql"
}

# Errors here usually mean the user or membership already exists, so they are not fatal.
create=$(jq -n --arg id "$svc_user" '{query: "mutation($u: CreateUserInput!) { createUser(user: $u) { id } }", variables: {u: {id: $id, email: "service@localhost", displayName: "Service account"}}}')
gql "$create" >/dev/null 2>&1 || echo "lldap-service-account: user $svc_user not created (may already exist)" >&2

group_id=$(gql '{"query": "{ groups { id displayName } }"}' | jq -r '.data.groups[] | select(.displayName == "lldap_admin") | .id')
member=$(jq -n --arg u "$svc_user" --argjson g "$group_id" '{query: "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }", variables: {u: $u, g: $g}}')
gql "$member" >/dev/null 2>&1 || echo "lldap-service-account: $svc_user not added to lldap_admin (may already be a member)" >&2

LLDAP_USER_PASSWORD=$(cat "$pass_file") /opt/lldap/lldap_set_password \
  --base-url "$base" --admin-username admin --admin-password "$LLDAP_LDAP_USER_PASS" --username "$svc_user"
echo "lldap-service-account: $svc_user is ready"
