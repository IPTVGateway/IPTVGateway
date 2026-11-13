# Third-party notices

IPTV Gateway's own code is MIT-licensed (see [LICENSE](LICENSE)). It vendors or
depends on the following third-party software, each under its own licence:

| Component | Where | Licence |
|---|---|---|
| [MARS-Curiosity](https://github.com/andrea-magni/MARS) 1.6.4 (REST framework) | `backend/3thParty/MARS-v.1.6.4/Source` | MPL 2.0 ([LICENSE](backend/3thParty/MARS-v.1.6.4/LICENSE)) |
| [mORMot](https://github.com/synopse/mORMot) (JWT, Windows builds), bundled with MARS | `backend/3thParty/MARS-v.1.6.4/ThirdParty/mORMot` | MPL 1.1 / GPL 2.0 / LGPL 2.1 (tri-license) |
| [delphi-jose-jwt](https://github.com/paolo-rossi/delphi-jose-jwt) (JWT, Linux builds), bundled with MARS | `backend/3thParty/MARS-v.1.6.4/ThirdParty/delphi-jose-jwt` | Apache 2.0 |
| glibc / libstdc++ link stubs (Linux64 sysroot for building without the RAD Studio Linux SDK) | `deploy/linux-sysroot` | LGPL 2.1+ / GPL 3 with GCC runtime exception |
| React, Vite, mpegts.js and other npm packages | `frontend/package.json` | MIT / Apache 2.0 (see each package) |

Embarcadero RAD Studio (Delphi, FireDAC, Indy) is required to build the backend
and is **not** included.
