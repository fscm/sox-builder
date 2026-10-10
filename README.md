# SoX static universal build for macOS

A self-contained `Makefile` that builds **SoX 14.4.2** from source on macOS
together with every library it can use, all linked **statically**, and produces
a **universal binary (x86_64 and arm64)** or a single-architecture binary.

It downloads all sources, builds its own small toolchain (GNU m4, autoconf,
automake, libtool, pkgconf, file), builds each dependency separately for each
architecture, and merges the results with `lipo`. Every dependency can be
rebuilt independently, so updates are cheap.

> The binary is as static as macOS allows: all third-party libraries are linked
> in, and only Apple system libraries and frameworks (`libSystem`, `libc++`,
> CoreAudio, etc.) stay dynamic. `make verify` checks this.

---

## 1. Prerequisites

| Requirement                  | Notes                                                                    |
|------------------------------|--------------------------------------------------------------------------|
| macOS                        | 11 (Big Sur) or newer recommended                                        |
| Xcode **Command Line Tools** | compiler, SDK, `make`, `lipo`, `perl`, `curl`, etc.                      |
| Internet access              | to download the sources (SourceForge, GitHub, xiph.org, GNU, astron.com) |
| ~3 GB free disk space        | sources, per-arch build trees, libraries                                 |

### Installing the macOS Command Line Tools

```sh
xcode-select --install
```

macOS shows a dialog, accept it and wait for the installation to finish. Check
with `xcode-select -p` (prints a path) and `clang --version`. Installing the
full Xcode from the App Store also provides them.

---

## 2. Quick start

```sh
make check-system     # optional: verify prerequisites
make                  # download, toolchain, libraries, SoX, and 'make dist'
make verify           # check architectures, static linkage and formats
```

Result (with the default `OUTPUT_DIR=dist` and `DIST_PREFIX=/usr/local`):

```
dist/
├── x86_64/usr/local/{bin,lib,include,share}     # one tree per architecture that was built
├── arm64/usr/local/{bin,lib,include,share}
└── universal/usr/local/{bin,lib,include,share}  # only when more than one arch was built
```

For example `dist/arm64/usr/local/bin/sox` and `dist/universal/usr/local/bin/sox`.
Each tree contains:

```
├── bin/sox (plus soxi, play, and rec symlinks)
├── include/sox.h
├── lib/libsox.a
├── share/man/            SoX man pages
├── share/sox/magic.mgc   libmagic database, the default path compiled into sox (<prefix>/share/sox/magic.mgc)
└── share/sox/licenses/   SoX licences, vendors/<software_name>/ holds each dependency's licences (see section 8)
```

You can copy a tree straight onto a target (for example
`sudo cp -R dist/universal/usr/local/ /usr/local/`) or package it.
Per-architecture trees contain thin binaries, the `universal` tree holds the
`lipo`-merged ones. With a single architecture (e.g. `ARCHS=arm64`) only that
arch's tree is created.

Useful variants:

```sh
make ARCHS=arm64                          # Apple Silicon only
make ARCHS=x86_64 MACOSX_DEPLOYMENT_TARGET=10.13
make TOOLCHAIN_DIR=$HOME/sox-toolchain DEPS_DIR=/Volumes/Fast/deps
make DIST_PREFIX=/opt/sox                 # dist/<arch>/opt/sox/bin/sox
make JOBS=1                               # serial inner builds, for debugging
```

Do **not** pass `-j` to the top-level `make`. Each package build uses `JOBS` for
parallelism (default: number of CPU cores). Note that `make -n` is not a
reliable dry run, because package builds are recursive make invocations and are
executed.

---

## 3. How it works

```
├── build/<arch>/<pkg>/    extracted and compiled sources for each architecture
├── deps/<arch>/           static libraries/headers installed for that architecture
│   └── .stamps/           one stamp file per installed package+version
├── dist/<arch>/<prefix>/  final per-arch output, dist/universal/<prefix>/ when several archs
├── downloads/             source tarballs (shared by everything)
├── packages/              final per-arch packages
└── toolchain/             native tools: m4, autoconf, automake, libtool, pkgconf, file
    └── .stamps/           one stamp file per installed tool+version
```

1. **Download**: each archive is fetched with `curl` into `downloads/` (and
   verified when a checksum is configured).
2. **Toolchain**: tools are built once with the host compiler and installed into
   `TOOLCHAIN_DIR`. They are put first on `PATH` for all other builds. `pkgconf`
   is used (with `--static`) so that static dependency chains resolve correctly,
   and automake supplies current `config.sub`/`config.guess` so 2000s-era
   packages recognise Apple Silicon.
3. **Libraries**: every library is built **once per architecture**
   (`clang -arch x86_64` / `-arch arm64`) as a static archive into
   `deps/<arch>`. Cross-compilation is used for the non-native architecture, so
   no Rosetta is required.
4. **SoX**: configured (after `autoreconf`, because the 14.4.2 release predates
   arm64) against `deps/<arch>`, built per architecture, then `make dist` copies
   each arch into `dist/<arch>/<prefix>` and merges them with `lipo` into
   `dist/universal/<prefix>`.

Rebuilds are driven by **stamp files** named `<package>-<version>.stamp`.
Changing a version creates a new stamp name and therefore triggers a rebuild
automatically. Dependents (e.g. SoX after a library rebuild) are rebuilt because
their stamps become older than their dependencies' stamps.

### Libraries and formats included

| Feature in SoX                                   | Provided by                                                                    |
|--------------------------------------------------|--------------------------------------------------------------------------------|
| FLAC                                             | flac (and libogg)                                                              |
| Ogg Vorbis                                       | libvorbis (and libogg)                                                         |
| Opus (read)                                      | opusfile plus opus (and libogg)                                                |
| MP3 decode / tags                                | libmad, libid3tag                                                              |
| MP3 encode (and LAME's own decoding)             | LAME 4.0 (and mpg123)                                                          |
| MP2 encode                                       | twolame                                                                        |
| WavPack                                          | wavpack                                                                        |
| AMR-NB / AMR-WB                                  | opencore-amr, vo-amrwbenc                                                      |
| Extra containers (CAF, W64, SD2, MAT, PAF, etc.) | libsndfile                                                                     |
| PNG spectrograms                                 | libpng (and zlib)                                                              |
| File-type detection                              | libmagic (from _file_), database installed with SoX under `<prefix>/share/sox` |
| GSM, LPC-10, WAV, AIFF, AU, VOC, raw, etc.       | built into SoX                                                                 |
| Playback/recording                               | CoreAudio (system frameworks)                                                  |

Not available because SoX itself does not support them: AAC/MP4, ffmpeg-based
formats. **Licensing:** this build includes GPL code (libmad, libid3tag, SoX's
GPL parts), so the resulting binary is distributed under the **GPL**.

---

## 4. Configuration

Every variable can be set on the command line (`make VAR=value`), in the
environment, or in an optional **`config.mk`** next to the Makefile (read
automatically):

```make
# config.mk example
TOOLCHAIN_DIR  = /opt/sox-toolchain
OUTPUT_DIR     = $(HOME)/sox-dist
ARCHS          = arm64
FLAC_VERSION   = 1.5.0
LAME_SHA256    = <sha256 of the lame tarball>
```

| Variable                   | Default                                  | Purpose                                                                                           |
|----------------------------|------------------------------------------|---------------------------------------------------------------------------------------------------|
| `ARCHS`                    | `x86_64 arm64`                           | architectures to build (one or both)                                                              |
| `MACOSX_DEPLOYMENT_TARGET` | `11.0`                                   | minimum macOS version (arm64 needs ≥ 11.0)                                                        |
| `BASE_DIR`                 | Makefile folder                          | root for the folders below                                                                        |
| `DOWNLOAD_DIR`             | `$(BASE_DIR)/downloads`                  | source tarballs                                                                                   |
| `TOOLCHAIN_DIR`            | `$(BASE_DIR)/toolchain`                  | native toolchain                                                                                  |
| `BUILD_DIR`                | `$(BASE_DIR)/build`                      | build trees                                                                                       |
| `DEPS_DIR`                 | `$(BASE_DIR)/deps`                       | per-arch static libraries                                                                         |
| `OUTPUT_DIR`               | `$(BASE_DIR)/dist`                       | root of the final per-arch / universal trees                                                      |
| `PACKAGE_DIR`              | `$(BASE_DIR)/packages`                   | where `make package` writes the `.pkg` files                                                      |
| `PKG_IDENTIFIER`           | `<username>.sox`                         | package identifier, default is the current user name in lower case plus `.sox` (e.g. `alice.sox`) |
| `PKG_VERSION`              | `$(SOX_VERSION)`                         | package version                                                                                   |
| `DIST_PREFIX`              | `/usr/local`                             | prefix recreated inside every `OUTPUT_DIR/<arch>` and `OUTPUT_DIR/universal` folder               |
| `DEPENDENCIES_FILE`        | `$(BASE_DIR)/DEPENDENCIES.txt`           | dependency map                                                                                    |
| `JOBS`                     | CPU count                                | parallelism inside each package build                                                             |
| `TARGET_CC` / `TARGET_CXX` | `clang` / `clang++`                      | compilers                                                                                         |
| `MACOS_SDK`                | `xcrun --show-sdk-path`                  | SDK used for `-isysroot`                                                                          |
| `OPT_FLAGS`                | `-O2`                                    | optimisation flags                                                                                |
| `LEGACY_WARN`              | `-Wno-error=...`                         | downgrades errors that modern clang raises on old code                                            |
| `STRIP_BINARIES`           | `yes`                                    | strip the final executables                                                                       |
| `REQUIRED_FORMATS`         | `flac mp3 ogg opus wv amr-nb amr-wb`     | formats `make verify` must find                                                                   |
| `SOX_AUTORECONF`           | `yes`                                    | run `autoreconf -fi` on SoX                                                                       |
| `SOX_EXTRA_LIBS`           | see Makefile                             | extra `LIBS` for SoX's configure link tests                                                       |
| `LIBMAGIC_DEFAULT_MAGIC`   | `$(DIST_PREFIX)/$(DIST_MAGIC_DIR)/magic` | default database path compiled into libmagic (`.mgc` is appended)                                 |
| `DIST_LICENSES_DIR`        | `share/sox/licenses`                     | folder (relative to the prefix) receiving the licence files (`make licenses`)                     |
| `DIST_MAGIC_DIR`           | `share/sox`                              | folder (relative to the prefix) where `make dist` puts `magic.mgc`                                |

Per package: `<PKG>_VERSION`, `<PKG>_URL`, `<PKG>_SHA256` (empty = no
verification), `<PKG>_CFG` (extra `./configure` options), plus the optional
hooks `<PKG>_CONFIGURE`, `_PRE`, `_BUILD`, `_INSTALL`, `_POST`. `<PKG>` is the
upper-cased package name with `-` replaced by `_` (`OPENCORE_AMR_VERSION`). Run
`make versions` to list the current versions.

The toolchain is **not relocatable** after being built (autoconf/automake record
absolute paths). If you change `TOOLCHAIN_DIR`, the tools are rebuilt in the new
location. Avoid spaces in all paths.

---

## 5. Targets

| Command                          | Effect                                                                                                       |
|----------------------------------|--------------------------------------------------------------------------------------------------------------|
| `make` / `make all`              | everything                                                                                                   |
| `make download`                  | download all sources only                                                                                    |
| `make toolchain`                 | build only the toolchain                                                                                     |
| `make deps`                      | build all libraries (all architectures)                                                                      |
| `make <name>`                    | build one package for all architectures, e.g. `make flac`                                                    |
| `make <name>-<arch>`             | one package, one architecture, e.g. `make flac-arm64`                                                        |
| `make sox`                       | build SoX per architecture (no `lipo` step)                                                                  |
| `make dist`                      | (re)create `OUTPUT_DIR/<arch>/<prefix>` for each built arch, plus `OUTPUT_DIR/universal/<prefix>` if several |
| `make rebuild-<name>`            | force-rebuild one package or tool                                                                            |
| `make clean-<name>`              | forget one package (stamp and build tree)                                                                    |
| `make licenses`                  | collect licence files from the source archives into every `dist` tree (part of `make`)                       |
| `make package`                   | build `.pkg` installers from the `dist` trees (see below)                                                    |
| `make verify`                    | check the universal (or single-arch) `sox`: architectures, system-only linkage, formats                      |
| `make info`, `versions`, `graph` | show configuration, versions, dependency map                                                                 |
| `make clean`                     | remove `build/`                                                                                              |
| `make distclean`                 | also remove toolchain, libraries and output                                                                  |
| `make purge`                     | also remove downloaded sources                                                                               |

Valid `<name>` values: the toolchain (`m4`, `autoconf`, `automake`, `libtool`,
`pkgconf`, and `file`), the libraries (`zlib`, `libogg`, `libvorbis`, `flac`,
`opus`, `opusfile`, `mpg123`, `lame`, `libmad`, `libid3tag`, `libsndfile`
`twolame`, `wavpack`, `opencore-amr`, `vo-amrwbenc`, `libpng`, and `libmagic`)
and `sox`.

### Building installer packages

```sh
make package    # runs 'make dist' first, then pkgbuild
```

One flat `.pkg` is created per architecture that was built, plus one for
`universal` when more than one was built. They are written to `packages/` in the
project root:

```
packages/
├── sox-14.4.2-darwin-x86_64.pkg
├── sox-14.4.2-darwin-arm64.pkg
└── sox-14.4.2-darwin-universal.pkg
```

Each package uses the matching `dist/<arch>` (or `dist/universal`) tree as its
payload, installed relative to `/`, so with the default prefix it installs
`/usr/local/bin/sox`, `/usr/local/lib/libsox.a`, and so on. The package
identifier defaults to `<username>.sox` (your user name in lower case, e.g.
`alice.sox`, override with `PKG_IDENTIFIER`) and the version is the SoX version
(`SOX_VERSION`). They are built with `pkgbuild` (part of macOS) and are
**unsigned**, sign them yourself with `productsign` if you distribute them.
You can inspect one with `pkgutil --payload-files packages/<file>.pkg`.

### Updating a dependency

```sh
make flac FLAC_VERSION=1.5.0     # or set FLAC_VERSION in config.mk
make                             # relink everything that depends on it, rebuild SoX, refresh dist/
```

A new version number gives a new stamp, so the package and everything that
depends on it rebuild automatically. To rebuild the _same_ version, use
`make rebuild-flac` and then `make`. Updating a toolchain tool works the same
way (`make pkgconf PKGCONF_VERSION=...`). Library builds do not automatically
rebuild when a tool changes. Run `make rebuild-<name>` for those you want
refreshed.

If a new version has a different download URL layout, also set `<PKG>_URL`.

---

## 6. Tracking dependencies: `DEPENDENCIES.txt`

`DEPENDENCIES.txt` is the single source of truth for build order, and the
Makefile **reads it**:

```
<package>: <space-separated direct dependencies>
```

For example `libsndfile: libogg libvorbis flac opus`. Lines starting with `#`
are comments. Use `make graph` to print what the Makefile understood.

**Adding a new library:**

1. Add it to `PACKAGES` in the Makefile.
2. Add `NEWLIB_VERSION`, `NEWLIB_URL` (and optionally `_SHA256`, `_CFG`) in
   section 4/5.
3. Add its line to `DEPENDENCIES.txt` and append it to the `sox:` line if SoX
   should use it.

---

## 7. Notes and troubleshooting

- **Configure results:** SoX auto-detects its libraries. If `make verify`
  reports a missing format, read `build/<arch>/sox/config.log` to see why the
  library check failed.
- **Build failures:** logs go to the terminal. To investigate, run
  `make <pkg>-<arch> JOBS=1` and inspect `build/<arch>/<pkg>/config.log`. Fix by
  passing `<PKG>_CFG`, or edit hooks in `config.mk`, then `make rebuild-<pkg>`.
- **Old compilers/SDKs:** if your clang does not know one of the `-Wno-error=`
  options in `LEGACY_WARN`, remove it via `config.mk`.
- **libmagic database location:** a `sed` edit applied automatically to the
  libmagic sources (`LIBMAGIC_PRE`) sets the compiled-in _default_ database path
  to `$(DIST_PREFIX)/share/sox/magic` (default `/usr/local/share/sox/magic`,
  libmagic appends `.mgc`). `make dist` copies the `magic.mgc` built here to
  exactly that place inside every dist tree
  (`dist/<arch>/usr/local/share/sox/magic.mgc`), so installing a tree or a
  `.pkg` puts the database where `sox` looks for it. The system copy is never
  read or modified. The `MAGIC` environment variable still overrides the path at
  run time. **The path is baked in when libmagic is built**, so after changing
  `DIST_PREFIX` or `DIST_MAGIC_DIR` run `make rebuild-libmagic` and then `make`.
- **`file` and `magic.mgc`:** the system `file` is never used. `file` is always
  built into the toolchain (same version as libmagic, `LIBMAGIC_VERSION`),
  because cross-building libmagic needs a host `file` of that exact version to
  compile the database. libmagic itself (library plus its own `file` program) is
  built for every architecture, and its `magic.mgc` is compiled unmodified, so
  the database format always matches the library.
- **How the path is changed:** `LIBMAGIC_PRE` runs `sed` on the `MAGIC = ...`
  line of `src/Makefile.am` and `src/Makefile.in` and fails the build if the
  line cannot be rewritten (checked with file 5.41, 5.45 and 5.48).
  If a future release changes that line, adjust `LIBMAGIC_PRE` in `config.mk`.
- **Mirrors:** if a download fails (SourceForge is occasionally unavailable),
  fetch the archive manually into `downloads/` under its original file name.
  Existing archives are not downloaded again.
- **Checksums:** SHA-256 values are shipped. Change `<PKG>_SHA256` for the
  versions you use if you want verified downloads.
- **LAME 4.0 and mpg123:** since 4.0, LAME uses the external `libmpg123` for MP3
  decoding instead of its bundled mpglib, so `mpg123` is built first (only the
  decoder library, no players) and `-lmpg123` is added to SoX's link libraries.
  The build prints a warning if `libmp3lame.a` ended up without mpg123 support.
  SoX itself decodes MP3 with libmad and only uses LAME for encoding.
  libsndfile's own MP3 support stays disabled (`--disable-mpeg`).
- **`sox --version` prints `SoX v` without a number:** this is a known bug of
  SoX 14.4.2 with optimising clang (SourceForge SoX patch #104, sox_ng issue
  #159). `sox_version()` and `sox_version_info()` are declared `LSX_RETURN_PURE`
  (`__attribute__((pure))`) in `src/sox.h`, although they fill function-local
  static buffers on first use. The compiler may therefore drop the call and just
  use the still-empty buffer's address, giving an empty version string (or
  `(null)` with LTO). It does not happen with gcc at `-O2`, which is why it
  shows up on macOS. `SOX_FIX_VERSION` (run first by `SOX_PRE`) uses `sed` to
  remove `LSX_RETURN_PURE` from exactly those two declarations in `src/sox.h`,
  and fails the build if the attribute is still present afterwards. The edit was
  verified against the real 14.4.2 sources: with clang at `-O3` and with
  `-O2 -flto` the unpatched build prints `SoX v` / `SoX v(null)` and the fixed
  one prints `SoX v14.4.2`. To build without it, override `SOX_PRE` in
  `config.mk` (keep the `autoreconf` and `LIBS` parts of the default).
- **Plugins:** formats and effects are linked in statically. Dynamic loading of
  plugins (libltdl) is disabled.

---

## 8. License and third-party notices

> This section is informational and **not legal advice**. Check each component's
> own licence files (they are collected by `make licenses`) before
> redistributing.

### This project

The build scripts (`Makefile`, `DEPENDENCIES.txt`, `README.md`) are licensed
under the **GNU General Public License v3.0 only** (`GPL-3.0-only`), see
[`LICENSE`](LICENSE).

### The resulting binaries

The `sox` executable, `libsox.a` and the `.pkg` installers contain third-party
code under the licences below. Because the `sox` program itself and
libmad/libid3tag are GPL code, the combined binaries are distributed under the
GPL (version 3, which is compatible with all the components, including the
Apache-2.0 AMR codecs). When you redistribute them you must also provide the
corresponding source (the archives listed by `make versions` plus these scripts,
or a written offer) and keep the licence notices.

| Component                         | Used for                | Licence (SPDX)                                                            |
|-----------------------------------|-------------------------|---------------------------------------------------------------------------|
| SoX (`sox` program)               | the tool                | GPL-2.0-or-later                                                          |
| SoX (libsox)                      | the library             | LGPL-2.1-or-later                                                         |
| libmad, libid3tag                 | MP3 decoding and tags   | GPL-2.0-or-later                                                          |
| LAME                              | MP3 encoding            | LGPL-2.0-or-later                                                         |
| mpg123 (libmpg123)                | decoding for LAME 4.x   | LGPL-2.1-only                                                             |
| twolame                           | MP2 encoding            | LGPL-2.1-or-later                                                         |
| libsndfile                        | extra container formats | LGPL-2.1-or-later                                                         |
| opencore-amr, vo-amrwbenc         | AMR-NB / AMR-WB         | Apache-2.0                                                                |
| flac (libFLAC)                    | FLAC                    | BSD-3-Clause (libraries; the `flac` programs are GPL but are not shipped) |
| libogg, libvorbis, opus, opusfile | Ogg / Vorbis / Opus     | BSD-3-Clause                                                              |
| wavpack                           | WavPack                 | BSD-3-Clause                                                              |
| libmagic (from _file_)            | file-type detection     | BSD-2-Clause                                                              |
| libpng                            | PNG spectrograms        | libpng-2.0                                                                |
| zlib                              | compression             | Zlib                                                                      |

The identifiers above reflect the upstream projects' published licences at the
time of writing and can change between versions. The files collected into
`licenses/` are authoritative.

The build tools (m4, autoconf, automake, libtool, pkgconf, file) only run on
your machine, are not part of the output, and are not covered here. Patents are
a separate matter from copyright licences. Check the codecs (AMR in particular)
for your use.

### Where the licence files end up

`make licenses` (also run by `make` and required by `make package`) reads the
original source archives in `downloads/` and copies every root-level `COPYING*`,
`LICENSE*`/`LICENCE*`, `COPYRIGHT*`, `NOTICE*`, `LGPL*` and `GPL*` file (plus
any `<PKG>_LICENSE_FILES`, e.g. zlib's `README`, which contains its licence)
into each `dist` tree:

```
dist/<arch|universal>/usr/local/share/sox/licenses/
├── COPYING, LGPL.txt               SoX licences
└── vendors/<software_name>/...     one folder per dependency (flac, lame, libmad, etc.)
```

The location follows `DIST_PREFIX` and `DIST_LICENSES_DIR`. A warning is printed
for any package from which no licence file could be found. Since the `.pkg`
installers are built from these trees, they install the licences too.

---

## 9. Contributing

Contributions are welcome! See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to
contribute.

This project has a [Code of Conduct](CODE_OF_CONDUCT.md). By interacting with
this repository, organization, or community you agree to abide by its terms.

### Basic steps

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Submit a pull request
