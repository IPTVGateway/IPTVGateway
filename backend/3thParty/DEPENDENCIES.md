# Third-party dependencies

## MARS-Curiosity (REST framework): git submodule

| | |
|---|---|
| Folder | `backend/3thParty/MARS` (git submodule, shallow) |
| Upstream | https://github.com/andrea-magni/MARS |
| Tag | <!--mars-tag-->v.2.0.3<!--/mars-tag--> |
| Commit | <!--mars-commit-->e51c2b99ebcc6b85e0cc80db623cc8fa5e442d72<!--/mars-commit--> |
| Updated | <!--mars-date-->2026-11-13<!--/mars-date--> |
| Licence | MPL 2.0 (`MARS/LICENSE`) |

MARS has its own submodules. **delphi-jose-jwt** (JWT on Linux64) is required;
Delphi-Mocks is fetched too but not used.

| | |
|---|---|
| Folder | `backend/3thParty/MARS/ThirdParty/delphi-jose-jwt` |
| Upstream | https://github.com/paolo-rossi/delphi-jose-jwt |
| Commit | <!--jose-commit-->0c538d028532414db36ec2be6f6f832ee77adb55<!--/jose-commit--> |
| Licence | Apache 2.0 |

Search paths in the host `.dproj` files: `MARS\Source`,
`MARS\ThirdParty\mORMot\Source` (JWT on Windows), and
`MARS\ThirdParty\delphi-jose-jwt\Source` plus `\Common` and `\JOSE` (JWT on Linux).

### Getting it

```bash
git clone --recursive https://github.com/IPTVGateway/IPTVGateway.git
# already cloned without --recursive:
git submodule update --init --recursive --depth 1
```

The "Download ZIP" / release source archives on GitHub do **not** contain
submodules; use git. `deploy/docker/build.ps1` stops with this hint when the MARS
folder is empty.

### Upgrading

```powershell
powershell -File tools\update-mars.ps1 -Tag v.2.0.4
```

The script checks out the tag (MARS's submodules included), updates this file and
prints the release notes; read the **Upgrade notes**. Then clear the DCU folder,
build Win32 + Linux64, run the tests, and commit the new submodule pointer **on its
own** ("MARS 2.0.3 -> 2.0.4").

## Not vendored here

- **Indy, FireDAC, RTL**: part of RAD Studio 13.
- **Linux64 sysroot** (`deploy/linux-sysroot`): glibc link stubs for building the
  daemon without the RAD Studio Linux SDK.
