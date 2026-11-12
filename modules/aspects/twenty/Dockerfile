# Images for Twenty and its own database and queue. Dependabot keeps the tags
# and digests current; twenty.nix reads these FROM lines by stage name.
# Upgrade Twenty one minor version at a time: each release migrates from the
# one before it.
FROM docker.io/twentycrm/twenty:v1.10.2@sha256:db31b5b2651b8756473490fe34d824f1a48cc266a97db1f57bdecee5b6ea8e51 AS twenty
FROM docker.io/library/postgres:16.10@sha256:21f6013073bc6b92830a2129570e2f5ec42a6c734b5a985a41e83aa58f54c3c1 AS db
FROM docker.io/library/redis:8.2.3@sha256:0908d9af26bf9b985e984a40a5eb82eed229b07a3317eee6843832c3cc3a9619 AS redis
