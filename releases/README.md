# Releases

The notes in this directory describe approved Golden releases. GitHub Releases holds the versioned script and a matching SHA-256 file. Older assets stay available; a new release does not overwrite them.

After a development build is approved, set the version and channel in `wireguard-vpn.sh`, update README, changelog and release notes, then create or change `.github/release-request.json` on `main` (start from `.github/release-request.example.json`). The release workflow checks the version and Bash syntax, creates the tag and publishes the script with its checksum. Verify the assets before aligning `develop` with the published `main` tree.
