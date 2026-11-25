# Images for Twenty and its own database and queue. Dependabot keeps the tags
# and digests current; twenty.nix reads these FROM lines by stage name.
# Upgrade Twenty one minor version at a time: each release migrates from the
# one before it.
FROM docker.io/twentycrm/twenty:v1.10.2@sha256:db31b5b2651b8756473490fe34d824f1a48cc266a97db1f57bdecee5b6ea8e51 AS twenty
FROM docker.io/library/postgres:16.16@sha256:07abc3f43c9395b0bdbbab36bc25ddb0e8d83cd4fcafb5fb7d6abe14ff156dd8 AS db
FROM docker.io/library/redis:8.10.3@sha256:1f88291b4c57bdf249f02eb085a8669889b2d2954e91d4de5118a5da6b78dd53 AS redis
