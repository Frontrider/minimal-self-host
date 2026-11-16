#!/usr/bin/env python3
import base64
import binascii
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ldap3 import BASE, NONE, Connection, Server
from ldap3.core.exceptions import LDAPBindError, LDAPException, LDAPInvalidCredentialsResult
from ldap3.utils.dn import escape_rdn, parse_dn

logging.basicConfig(level=logging.INFO)
LDAP_HOST = os.environ.get("LDAP_HOST") or os.environ["CORE_INTERNAL_IP"]
LDAP_BASE = "ou=people,dc=example,dc=com"
LDAP_GROUP_BASE = "ou=groups,dc=example,dc=com"
LDAP_ADMIN_GROUP = "lldap_admin"
FORWARD_AUTH_PATH = "/auth/api/authz/forward-auth"
# This variant returns the same identity headers, but only for LLDAP admins.
FORWARD_AUTH_ADMIN_PATHS = (
    "/auth/api/authz/forward-auth-admin",
    "/auth/api/authz/forward-auth/admin",
)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path != FORWARD_AUTH_PATH and path not in FORWARD_AUTH_ADMIN_PATHS:
            self.send_error(404)
            return
        admin_only = path != FORWARD_AUTH_PATH

        try:
            scheme, encoded = self.headers.get("Authorization", "").split(" ", 1)
            if scheme.lower() != "basic":
                raise ValueError("not Basic authentication")
            credentials = base64.b64decode(encoded, validate=True).decode("utf-8")
            username, password = credentials.split(":", 1)
            if not username or not password or any(c in username for c in "\r\n\x00"):
                raise ValueError("empty or invalid credentials")
        except (ValueError, UnicodeError, binascii.Error):
            self.unauthorized()
            return

        dn = f"uid={escape_rdn(username)},{LDAP_BASE}"
        try:
            server = Server(LDAP_HOST, port=3890,
                            connect_timeout=5, get_info=NONE)
            with Connection(server, user=dn, password=password, auto_bind=True, receive_timeout=5,
                            raise_exceptions=True, check_names=False) as connection:
                connection.search(dn, "(objectClass=*)", search_scope=BASE,
                                  attributes=["uid", "displayName", "mail", "memberOf"])
                if len(connection.entries) != 1:
                    raise LDAPException("User entry not found")
                entry = connection.entries[0]
                user = str(entry.uid.value or username)
                name = str(entry.displayName.value or user)
                email = str(entry.mail.value or "")
                groups = []
                for group_dn in entry.memberOf.values:
                    if not group_dn:
                        continue
                    parsed = parse_dn(group_dn)
                    if (len(parsed) >= 2 and parsed[0][0].lower() == "cn"
                            and group_dn.lower().endswith("," + LDAP_GROUP_BASE)):
                        group = parsed[0][1]
                        if "," in group or "\\" in group:
                            raise LDAPException("LDAP group name cannot be represented safely")
                        groups.append(group)
                if admin_only and LDAP_ADMIN_GROUP not in groups:
                    self.forbidden()
                    return
                values = {
                    "Remote-User": user,
                    "Remote-Groups": ",".join(groups),
                    "Remote-Name": name,
                    "Remote-Email": email,
                }
                if any(any(ord(c) < 32 or ord(c) == 127 for c in value) for value in values.values()):
                    raise LDAPException("Invalid LDAP attribute")
                for value in values.values():
                    value.encode("latin-1")
        except (LDAPBindError, LDAPInvalidCredentialsResult):
            self.unauthorized()
            return
        except (LDAPException, OSError, ValueError):
            logging.exception("LDAP authentication service failed")
            self.send_error(503)
            return

        self.send_response(200)
        for header, value in values.items():
            self.send_header(header, value)
        self.end_headers()

    def unauthorized(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Minimal Self Host", charset="UTF-8"')
        self.end_headers()

    def forbidden(self):
        self.send_response(403)
        self.end_headers()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 9091), Handler).serve_forever()
