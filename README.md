# Eddyline releases

The install files for [Eddyline](https://eddyline.app), the self-hosted issue tracker for agencies. This repository is served at `https://get.eddyline.app`.

Install on a fresh Ubuntu or Debian server:

```sh
curl -fsSL https://get.eddyline.app/install.sh | sudo sh -s -- --domain tracker.example.com --email you@example.com
```

The guide is at [eddyline.app/docs](https://eddyline.app/docs).

## Files

| File | What it is |
| --- | --- |
| `install.sh` | The installer. Also served at `/`. |
| `cli.sh` | The `eddy` command the installer puts in `/usr/local/bin`. |
| `compose.yml`, `compose.db.yml`, `Caddyfile`, `Caddyfile.http`, `env.template` | The templates the installer downloads. |
| `SHA256SUMS` | Checksums of the files above. The installer verifies every download against it. |
| `releases.json` | Every release, newest first. The app reads it once a day to tell staff when a newer version is out. |

Every file except this README, `_headers` and `_redirects` is written by the release workflow in the product repository when a version is tagged. Do not edit them by hand.

Eddyline is made by [SectorFlow](https://sectorflow.ai).
