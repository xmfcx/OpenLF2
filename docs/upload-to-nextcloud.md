# Upload a build to Nextcloud

This document tells you how to upload a portable build to the Nextcloud instance at `cloud.evim.dev`. It also tells you how to make a public download link for that build.

The commands use WebDAV (an HTTP protocol for remote files) for the upload. They use the Nextcloud OCS Share API for the link.

## Credentials

The credentials are in `~/.env/cloud-evim-dev/mfcirit@gmail.com.env`.

- The file name without `.env` is the Nextcloud username (`mfcirit@gmail.com`).
- The first line of the file is the app password. The line has no `NAME=` prefix.

Do not `source` or `export` this file. The file is not in shell format.

Do not print the file to the terminal. The file holds only the password, so a filter that hides `NAME=value` pairs shows the password in full.

The commands that follow give the credentials to `curl` on standard input with `-K -`. This keeps the password out of the process list and the shell history.

## Upload the zip

1. Set the variables:

   ```bash
   F="$HOME/.env/cloud-evim-dev/mfcirit@gmail.com.env"
   U="$(basename "$F" .env)"
   P="$(head -n1 "$F" | tr -d '\r\n')"
   Z=/home/mfc/Downloads/OpenLF2-v1.1.1-windows/OpenLF2-Windows-x64-portable.zip
   D="Games/LF2/OpenLF2"
   ```

2. Make sure that the target folder exists. The server must return `HTTP 207`:

   ```bash
   printf 'user = "%s:%s"\n' "$U" "$P" | curl -s -K - -X PROPFIND -H "Depth: 1" \
     "https://cloud.evim.dev/remote.php/dav/files/$U/$D/" -w '\nHTTP %{http_code}\n' \
     | grep -oE '<d:href>[^<]*</d:href>|HTTP [0-9]+'
   ```

3. Upload the zip. The server must return `HTTP 201` for a new file or `HTTP 204` for a replaced file:

   ```bash
   printf 'user = "%s:%s"\n' "$U" "$P" | curl -s -K - -T "$Z" \
     "https://cloud.evim.dev/remote.php/dav/files/$U/$D/$(basename "$Z")" -w 'HTTP %{http_code}\n'
   ```

4. Make sure that the remote size is the same as the local size:

   ```bash
   printf 'user = "%s:%s"\n' "$U" "$P" | curl -s -K - -X PROPFIND -H "Depth: 1" \
     "https://cloud.evim.dev/remote.php/dav/files/$U/$D/" | grep -oE '<d:getcontentlength>[0-9]+'
   stat -c %s "$Z"
   ```

## Make a public download link

1. Make a read-only public link (`shareType=3`, `permissions=1`):

   ```bash
   printf 'user = "%s:%s"\n' "$U" "$P" | curl -s -K - -X POST \
     -H "OCS-APIRequest: true" -H "Accept: application/json" \
     "https://cloud.evim.dev/ocs/v2.php/apps/files_sharing/api/v1/shares" \
     --data-urlencode "path=/$D/$(basename "$Z")" -d shareType=3 -d permissions=1 \
     | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["ocs"]; print(d["meta"]["statuscode"], d["data"].get("url"))'
   ```

   The command prints `200` and the link, for example `https://cloud.evim.dev/s/<token>`.

2. Make sure that the link works without a login. The server must return `HTTP 206`:

   ```bash
   curl -sL -o /dev/null -r 0-1023 -w 'HTTP %{http_code}\n' "https://cloud.evim.dev/s/<token>/download"
   ```

The link has no password and no expiration date. To add them, edit the share in the Nextcloud web interface.

## Upload of v1.1.1

On 2026-10-24, we uploaded `OpenLF2-Windows-x64-portable.zip` (37291045 bytes) to `/Games/LF2/OpenLF2`. The public link is https://cloud.evim.dev/s/BgjSDPXKHa26d8i.

## Upload of v1.1.1 with the speed menu

On 2026-10-24, we uploaded `OpenLF2-Windows-x64-portable-mfd.zip` (37313363 bytes) to `/Games/LF2/OpenLF2`. This zip is the v1.1.1 portable build with the game speed menu and script sharing scripts. Its launcher keeps the settings in `%APPDATA%\OpenLF2`. The public link is https://cloud.evim.dev/s/jxWdsWzeeTggYck. The scripts in this zip have LF line endings, so they match a Linux build for network play.

On 2026-10-25, we created the public read-only link of the versions folder `/Games/LF2/OpenLF2/versions`: https://cloud.evim.dev/s/trAWB2wyHyWewWb. Its token is in `~/programs/openlf2-windows/versions-share-token`, and `publish-version.sh` uploads each game version there. The first version is `2026.10.25-30` (c1d1b40).

On 2026-10-25, `publish-version.sh` published `2026.10.25-37` (29fdd48), the latest version. Its `versions.json` lists `2026.10.25-37` and `2026.10.25-30`. Each version has two packages in the folder: `openlf2-ID-linux-x64.tar.gz` and `openlf2-ID-windows-x64.tar.gz`. The download address of a package is `https://cloud.evim.dev/s/trAWB2wyHyWewWb/download?path=/&files=NAME`. The local copies are in `~/programs/openlf2-windows/out`.
