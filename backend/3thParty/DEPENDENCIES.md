# Vendored dependencies

Third-party Delphi code is **vendored** (copied into the repo) so the backend
builds offline and identically everywhere, for Win32 and the Linux64 daemon,
without a package manager. Folder names carry **no version number**, so an
upgrade never touches the `.dproj` search paths.

Upgrade with the script, never by hand:

```powershell
# from the repo root; shows the release notes and updates the table below
powershell -File tools\update-mars.ps1 -Tag v.2.0.4
```

Then build Win32 and Linux64, run the tests, and commit the upgrade **on its own**
("MARS 2.0.3 -> 2.0.4"), separate from functional changes.

## MARS-Curiosity (REST framework)

| | |
|---|---|
| Folder | `backend/3thParty/MARS` |
| Upstream | https://github.com/andrea-magni/MARS |
| Tag | <!--mars-tag-->v.2.0.3<!--/mars-tag--> |
| Commit | <!--mars-commit-->e51c2b99ebcc6b85e0cc80db623cc8fa5e442d72<!--/mars-commit--> |
| Updated | <!--mars-date-->2026-11-13<!--/mars-date--> |
| Licence | MPL 2.0 (`MARS/LICENSE`) |
| Taken | `Source/`, `ThirdParty/mORMot/`, `LICENSE`, `README.md`, `SECURITY.md`, `version.txt` |
| Left out | Demos, docs, media, Packages, Setup, Utils, tests, www, Skills, ThirdParty/{DCS, Neslib.Yaml, Delphi-Mocks} |

Search paths in the host `.dproj` files: `MARS\Source`,
`MARS\ThirdParty\mORMot\Source` (JWT on Windows), and
`MARS\ThirdParty\delphi-jose-jwt\Source` plus `\Common` and `\JOSE` (JWT on Linux).

### delphi-jose-jwt (git submodule of MARS)

MARS references it as a submodule, which is **empty** in a release tarball. The
script fetches exactly the commit MARS pins.

| | |
|---|---|
| Folder | `backend/3thParty/MARS/ThirdParty/delphi-jose-jwt` |
| Upstream | https://github.com/paolo-rossi/delphi-jose-jwt |
| Commit | <!--jose-commit-->0c538d028532414db36ec2be6f6f832ee77adb55<!--/jose-commit--> |
| Licence | Apache 2.0 |
| Taken | `Source/` (`Common/`, `JOSE/`, `JOSE.inc`), `LICENSE`, `README.md` |

## Not vendored here

- **Indy, FireDAC, RTL**: part of RAD Studio 13.
- **Linux64 sysroot** (`deploy/linux-sysroot`): glibc link stubs for building the
  daemon without the RAD Studio Linux SDK.
