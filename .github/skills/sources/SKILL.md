---
description: 'Describe what this skill does.'
---

If an application needs an icon, use these as a source.
- https://github.com/homarr-labs/dashboard-icons

If none was found, use the official logo of the application, or an image from their gallery.
NEVER generate any images.

If a docker image is needed, prefer the official image from dockerhub, or the one from the official repository of the application.

if it does not exist, use one of these sources:
https://hub.docker.com/r/linuxserver/

NEVER write any application descriptions.

Don't use web applications that can't be shared under a subpath (with a reverse proxy).
STOP processing if this is the case, this type of application will not work, there is no point in wasting time to hack around it before it gets deleted.
Subdomains are never an option.

When configuring ldap, the lldap_admin group should be used to determine if a user needs admin permissions or not.
If lldap can't be configured for the app, use the already available forward auth proxy with:
```yaml
      caddy.7_handle.0_forward_auth: '127.0.0.1:9091'
      caddy.7_handle.0_forward_auth.uri: '/auth/api/authz/forward-auth'
      caddy.7_handle.0_forward_auth.copy_headers: 'Remote-User Remote-Groups Remote-Name Remote-Email'
```
use `/auth/api/authz/forward-auth-admin` as the path if only admins should be able to access the page.
Always publish every port that the application needs with caddy. 

There is an entire caddy reverse proxy in the stack, avoid using anything else if possible.


Every container reading the data volume from /data must use 1000:1000 as its uid/guid pair.

