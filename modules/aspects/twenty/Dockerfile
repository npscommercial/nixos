# Images for Twenty and its own database and queue. Dependabot keeps the tags
# and digests current; twenty.nix reads these FROM lines by stage name.
# Upgrade Twenty one minor version at a time: each release migrates from the
# one before it.
FROM docker.io/twentycrm/twenty:v1.10.2@sha256:db31b5b2651b8756473490fe34d824f1a48cc266a97db1f57bdecee5b6ea8e51 AS twenty
FROM docker.io/library/postgres:16.15@sha256:f9a7b9ebf6f56201f949db745e47bc423c0f0f8294bafe991cc10bf74b029657 AS db
FROM docker.io/library/redis:8.2.3@sha256:0908d9af26bf9b985e984a40a5eb82eed229b07a3317eee6843832c3cc3a9619 AS redis
