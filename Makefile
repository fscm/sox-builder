# SPDX-FileCopyrightText: 2026 Frederico Martins
# SPDX-License-Identifier: GPL-3.0-only
# =============================================================================
# SoX (Sound eXchange) - static, universal build system for macOS
# =============================================================================
# See README.md for full documentation and DEPENDENCIES.txt for the dependency
# map (which this Makefile reads). Compatible with the GNU Make 3.81 that ships
# with macOS.
#
#   make                 build everything -> $(OUTPUT_DIR)/<arch|universal>$(DIST_PREFIX)/bin/sox
#   make help            list all targets
#   make flac            (re)build one dependency for every architecture
#   make flac-arm64      build one dependency for one architecture
#   make ARCHS=arm64     build a single architecture only
#
# Every setting below can be overridden on the command line, from the
# environment, or in an optional config.mk placed next to this Makefile.
# =============================================================================

SHELL := /bin/bash
.SUFFIXES:
.DEFAULT_GOAL := all

ifneq ($(shell uname -s),Darwin)
$(error This Makefile only supports macOS (Darwin))
endif

MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# Optional user overrides (versions, paths, flags, etc.)
-include $(MAKEFILE_DIR)config.mk

# -----------------------------------------------------------------------------
# 1. General configuration
# -----------------------------------------------------------------------------
# Architectures to build: 'x86_64 arm64' (universal) or just one of them.
ARCHS                    ?= x86_64 arm64
# Minimum macOS version of the produced binaries (arm64 requires >= 11.0).
MACOSX_DEPLOYMENT_TARGET ?= 11.0
TARGET_CC                ?= clang
TARGET_CXX               ?= clang++
MACOS_SDK                ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
JOBS                     ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
STRIP_BINARIES           ?= yes
# macOS installer package (.pkg) settings.
# Default: <current user name, lower case>.sox (e.g. user 'Alice' -> alice.sox)
PKG_IDENTIFIER           ?= $(shell id -un | tr '[:upper:]' '[:lower:]').sox
PKG_VERSION              ?= $(SOX_VERSION)
OPT_FLAGS                ?= -O2
# Old code bases (SoX 14.4.2, libmad, etc.) trip over errors that modern clang
# promotes from warnings. Downgrade them again.
LEGACY_WARN              ?= -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types
# Formats that 'make verify' requires in the final sox binary.
REQUIRED_FORMATS         ?= flac mp3 ogg opus wv amr-nb amr-wb
# Run autoreconf on SoX (needed: the 14.4.2 release predates Apple Silicon).
SOX_AUTORECONF           ?= yes

# -----------------------------------------------------------------------------
# 2. Folders (all relocatable. Avoid spaces in paths)
# -----------------------------------------------------------------------------
BASE_DIR          ?= $(patsubst %/,%,$(MAKEFILE_DIR))
DOWNLOAD_DIR      ?= $(BASE_DIR)/downloads     # source tarballs
TOOLCHAIN_DIR     ?= $(BASE_DIR)/toolchain     # pkgconf, autoconf, automake, ...
BUILD_DIR         ?= $(BASE_DIR)/build         # per-arch extracted/compiled sources
DEPS_DIR          ?= $(BASE_DIR)/deps          # per-arch static libs: $(DEPS_DIR)/<arch>
OUTPUT_DIR        ?= $(BASE_DIR)/dist          # final results (see 'make dist')
DEPENDENCIES_FILE ?= $(BASE_DIR)/DEPENDENCIES.txt
PACKAGE_DIR       ?= $(BASE_DIR)/packages      # .pkg installers (see 'make package')

# Install prefix recreated inside every $(OUTPUT_DIR)/<arch> and
# $(OUTPUT_DIR)/universal folder, e.g. dist/arm64/usr/local/bin/sox. Normalised
# to start with '/' and not end with one.
DIST_PREFIX       ?= /usr/local
# Folder (relative to the prefix) receiving the collected licence files. The SoX
# licences go directly inside it, every dependency's into vendors/<software_name>/.
# Normalised to neither start or end with '/'.
DIST_LICENSES_DIR ?= share/sox/licenses
# `magic.mgc` path inside the $(DIST_PREFIX) location. Normalised to neither
# start or end with '/'.
DIST_MAGIC_DIR    ?= share/sox

override DOWNLOAD_DIR      := $(abspath $(strip $(DOWNLOAD_DIR)))
override TOOLCHAIN_DIR     := $(abspath $(strip $(TOOLCHAIN_DIR)))
override BUILD_DIR         := $(abspath $(strip $(BUILD_DIR)))
override DEPS_DIR          := $(abspath $(strip $(DEPS_DIR)))
override OUTPUT_DIR        := $(abspath $(strip $(OUTPUT_DIR)))
override PACKAGE_DIR       := $(abspath $(strip $(PACKAGE_DIR)))
override DIST_PREFIX       := $(patsubst %/,%,/$(patsubst /%,%,$(strip $(DIST_PREFIX))))
override DIST_LICENSES_DIR := $(patsubst %/,%,$(patsubst /%,%,$(strip $(DIST_LICENSES_DIR))))
override DIST_MAGIC_DIR    := $(patsubst %/,%,$(patsubst /%,%,$(strip $(DIST_MAGIC_DIR))))

# Folder (inside OUTPUT_DIR) that holds the "main" result. Universal if several
# archs, else the single arch.
DIST_MAIN  = $(OUTPUT_DIR)/$(if $(word 2,$(ARCHS)),universal,$(firstword $(ARCHS)))$(DIST_PREFIX)

# -----------------------------------------------------------------------------
# 3. What gets built
# -----------------------------------------------------------------------------
# Native build tools -> $(TOOLCHAIN_DIR). Cross-building libmagic needs a host
# 'file' of exactly the same version to compile magic.mgc so 'file' is always
# built.
TOOLS    := m4 autoconf automake libtool pkgconf file
# Static libraries -> $(DEPS_DIR)/<arch>   (order/relations: DEPENDENCIES.txt)
PACKAGES := zlib libogg libvorbis flac opus opusfile mpg123 lame libmad libid3tag \
            libsndfile twolame wavpack opencore-amr vo-amrwbenc libpng libmagic
ALL_PKGS := $(PACKAGES) sox
DL_LIST  := $(filter-out file,$(TOOLS)) $(ALL_PKGS)

# -----------------------------------------------------------------------------
# 4. Versions, download URLs and (optional) SHA-256 checksums.
#    Bump a version here (or in config.mk) and run: make rebuild-<package>
#    Set <PKG>_SHA256 to enable checksum verification of that download.
# -----------------------------------------------------------------------------
# --- toolchain ---
M4_VERSION       ?= 1.4.21
M4_URL           ?= https://ftp.gnu.org/gnu/m4/m4-$(M4_VERSION).tar.xz
M4_SHA256        ?= f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66
AUTOCONF_VERSION ?= 2.73
AUTOCONF_URL     ?= https://ftp.gnu.org/gnu/autoconf/autoconf-$(AUTOCONF_VERSION).tar.xz
AUTOCONF_SHA256  ?= 9fd672b1c8425fac2fa67fa0477b990987268b90ff36d5f016dae57be0d6b52e
AUTOMAKE_VERSION ?= 1.19
AUTOMAKE_URL     ?= https://ftp.gnu.org/gnu/automake/automake-$(AUTOMAKE_VERSION).tar.xz
AUTOMAKE_SHA256  ?= e3e2c2e3abf37898138db5b6c1d1dc35c9160c5978be7947d2c741705251d445
LIBTOOL_VERSION  ?= 2.6.2
LIBTOOL_URL      ?= https://ftp.gnu.org/gnu/libtool/libtool-$(LIBTOOL_VERSION).tar.xz
LIBTOOL_SHA256   ?= 2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e
PKGCONF_VERSION  ?= 3.0.7
PKGCONF_URL      ?= https://distfiles.ariadne.space/pkgconf/pkgconf-$(PKGCONF_VERSION).tar.xz
PKGCONF_SHA256   ?= c926ff491cbd9a331a589160811bd97ab1749b4d5198a519338f2cdfabe6940a
# 'file' tool = same source/version as libmagic (see below)
FILE_VERSION      = $(LIBMAGIC_VERSION)
FILE_URL          = $(LIBMAGIC_URL)
FILE_SHA256       = $(LIBMAGIC_SHA256)

# --- libraries ---
ZLIB_VERSION         ?= 1.3.2
ZLIB_URL             ?= https://github.com/madler/zlib/releases/download/v$(ZLIB_VERSION)/zlib-$(ZLIB_VERSION).tar.xz
ZLIB_SHA256          ?= d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3
LIBOGG_VERSION       ?= 1.3.6
LIBOGG_URL           ?= https://downloads.xiph.org/releases/ogg/libogg-$(LIBOGG_VERSION).tar.xz
LIBOGG_SHA256        ?= 5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
LIBVORBIS_VERSION    ?= 1.3.7
LIBVORBIS_URL        ?= https://downloads.xiph.org/releases/vorbis/libvorbis-$(LIBVORBIS_VERSION).tar.xz
LIBVORBIS_SHA256     ?= b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
FLAC_VERSION         ?= 1.5.0
FLAC_URL             ?= https://downloads.xiph.org/releases/flac/flac-$(FLAC_VERSION).tar.xz
FLAC_SHA256          ?= f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920
OPUS_VERSION         ?= 1.6.1
OPUS_URL             ?= https://downloads.xiph.org/releases/opus/opus-$(OPUS_VERSION).tar.gz
OPUS_SHA256          ?= 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
OPUSFILE_VERSION     ?= 0.12
OPUSFILE_URL         ?= https://downloads.xiph.org/releases/opus/opusfile-$(OPUSFILE_VERSION).tar.gz
OPUSFILE_SHA256      ?= 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b
MPG123_VERSION       ?= 1.33.7
MPG123_URL           ?= https://mpg123.de/download/mpg123-$(MPG123_VERSION).tar.bz2
MPG123_SHA256        ?= 31d0e35a4ca567ec9b5ebda6c3062bb4435d6d3eacd6ef0d95cadd7854dc03ee
LAME_VERSION         ?= 4.0
LAME_URL             ?= https://downloads.sourceforge.net/project/lame/lame/$(LAME_VERSION)/lame-$(LAME_VERSION).tar.gz
LAME_SHA256          ?= 3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
LIBMAD_VERSION       ?= 0.15.1b
LIBMAD_URL           ?= https://downloads.sourceforge.net/project/mad/libmad/$(LIBMAD_VERSION)/libmad-$(LIBMAD_VERSION).tar.gz
LIBMAD_SHA256        ?= bbfac3ed6bfbc2823d3775ebb931087371e142bb0e9bb1bee51a76a6e0078690
LIBID3TAG_VERSION    ?= 0.15.1b
LIBID3TAG_URL        ?= https://downloads.sourceforge.net/project/mad/libid3tag/$(LIBID3TAG_VERSION)/libid3tag-$(LIBID3TAG_VERSION).tar.gz
LIBID3TAG_SHA256     ?= 63da4f6e7997278f8a3fef4c6a372d342f705051d1eeb6a46a86b03610e26151
LIBSNDFILE_VERSION   ?= 1.2.2
LIBSNDFILE_URL       ?= https://github.com/libsndfile/libsndfile/releases/download/$(LIBSNDFILE_VERSION)/libsndfile-$(LIBSNDFILE_VERSION).tar.xz
LIBSNDFILE_SHA256    ?= 3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e
TWOLAME_VERSION      ?= 0.4.0
TWOLAME_URL          ?= https://downloads.sourceforge.net/project/twolame/twolame/$(TWOLAME_VERSION)/twolame-$(TWOLAME_VERSION).tar.gz
TWOLAME_SHA256       ?= cc35424f6019a88c6f52570b63e1baf50f62963a3eac52a03a800bb070d7c87d
WAVPACK_VERSION      ?= 5.9.0
WAVPACK_URL          ?= https://github.com/dbry/WavPack/releases/download/$(WAVPACK_VERSION)/wavpack-$(WAVPACK_VERSION).tar.xz
WAVPACK_SHA256       ?= b5291bc4e6d69ebbd3da3800c5bf4a70f19bb92679b23e09b3b612c1e648d1ff
OPENCORE_AMR_VERSION ?= 0.1.6
OPENCORE_AMR_URL     ?= https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-$(OPENCORE_AMR_VERSION).tar.gz
OPENCORE_AMR_SHA256  ?= 483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1
VO_AMRWBENC_VERSION  ?= 0.1.3
VO_AMRWBENC_URL      ?= https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-$(VO_AMRWBENC_VERSION).tar.gz
VO_AMRWBENC_SHA256   ?= 5652b391e0f0e296417b841b02987d3fd33e6c0af342c69542cbb016a71d9d4e
LIBPNG_VERSION       ?= 1.6.59
LIBPNG_URL           ?= https://downloads.sourceforge.net/project/libpng/libpng16/$(LIBPNG_VERSION)/libpng-$(LIBPNG_VERSION).tar.xz
LIBPNG_SHA256        ?= d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
LIBMAGIC_VERSION     ?= 5.48
LIBMAGIC_URL         ?= https://astron.com/pub/file/file-$(LIBMAGIC_VERSION).tar.gz
LIBMAGIC_SHA256      ?= ed14656883b23a364b4057c05595d93252da9bc473d30106519519d0da141283

# --- SoX itself ---
SOX_VERSION ?= 14.4.2
SOX_URL     ?= https://downloads.sourceforge.net/project/sox/sox/$(SOX_VERSION)/sox-$(SOX_VERSION).tar.gz
SOX_SHA256  ?=

# -----------------------------------------------------------------------------
# 5. Per-package configure options / hooks
#    <PKG>_CFG       extra ./configure arguments (autotools packages)
#    <PKG>_CONFIGURE complete replacement for the configure command
#    <PKG>_PRE       shell commands run in the source dir before configure
#    <PKG>_BUILD     replacement for the build command   (default: make -jN)
#    <PKG>_INSTALL   replacement for the install command (default: make install)
#    <PKG>_POST      shell commands run after install
#    In these snippets $$pfx is the per-arch install prefix.
# -----------------------------------------------------------------------------
PKGCONF_CFG      ?= --disable-shared --enable-static
FILE_CFG         ?= --disable-shared --enable-static --disable-zlib --disable-bzlib --disable-xzlib --disable-zstdlib --disable-lzlib --disable-libseccomp

# clang rejects several GCC-only optimisation flags hard-coded in these
# 2004-era configure scripts.
LEGACY_GCC_FIX = LC_ALL=C sed -e 's/-fno-strength-reduce//g' -e 's/-fstrength-reduce//g' -e 's/-fforce-mem//g' -e 's/-fthread-jumps//g' -e 's/-fcse-follow-jumps//g' -e 's/-fcse-skip-blocks//g' -e 's/-fregmove//g' -e 's/-fexpensive-optimizations//g' -e 's/-fschedule-insns2//g' -e 's/-fschedule-insns//g' configure > configure.tmp && mv configure.tmp configure && chmod +x configure

# <PKG>_LICENSE_FILES: extra root-level files that hold a licence (picked up by
# 'make licenses')
ZLIB_LICENSE_FILES ?= README

ZLIB_CONFIGURE   ?= ./configure --prefix="$$pfx" --static
LIBOGG_CFG       ?= --quiet --enable-silent-rules
# libvorbis: configure hard-codes the obsolete linker flag -force_cpusubtype_ALL
# for Darwin, which ld rejects (notably when building x86_64 on an arm64 host).
LIBVORBIS_PRE    ?= LC_ALL=C sed -e 's/-force_cpusubtype_ALL//g' configure > configure.tmp && mv configure.tmp configure && chmod +x configure
LIBVORBIS_CFG    ?= --quiet --enable-silent-rules --with-ogg="$$pfx" --disable-docs --disable-examples --disable-oggtest
FLAC_CFG         ?= --quiet --enable-silent-rules --with-ogg="$$pfx" --disable-cpplibs --disable-doxygen-docs --disable-examples --disable-thorough-tests --disable-oggtest
OPUS_CFG         ?= --quiet --enable-silent-rules --disable-doc --disable-extra-programs
OPUSFILE_CFG     ?= --quiet --enable-silent-rules --disable-http --disable-examples --disable-doc
# mpg123: only the decoder library is needed (LAME 4.x uses it for decoding)
MPG123_CFG       ?= --quiet --enable-silent-rules --disable-components --enable-libmpg123 --disable-modules
# LAME 4.x: decoding goes through libmpg123 (found via pkg-config in $$pfx). The
# decoder stays enabled so mpg123 is used. Warn if it was not linked in.
LAME_CFG         ?= --quiet --enable-silent-rules --disable-frontend --disable-gtktest
LAME_POST        ?= if ! nm "$$pfx/lib/libmp3lame.a" 2>/dev/null | grep -q mpg123_; then echo "WARNING: libmp3lame was built WITHOUT libmpg123 decoding support (check build/<arch>/lame/config.log)"; fi
LIBMAD_PRE       ?= $(LEGACY_GCC_FIX)
LIBMAD_CFG       ?= --quiet --enable-silent-rules --disable-debugging --disable-aso --enable-fpm=64bit
LIBMAD_POST      ?= mkdir -p "$$pfx/lib/pkgconfig"; printf 'prefix=%s\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: mad\nDescription: MPEG audio decoder\nVersion: $(LIBMAD_VERSION)\nLibs: -L$${libdir} -lmad\nCflags: -I$${includedir}\n' "$$pfx" > "$$pfx/lib/pkgconfig/mad.pc"
LIBID3TAG_PRE    ?= $(LEGACY_GCC_FIX); for f in compat.c frametype.c; do if [ -f $$f ]; then touch $$f; fi; done
LIBID3TAG_CFG    ?= --quiet --enable-silent-rules --disable-debugging
LIBSNDFILE_CFG   ?= --quiet --enable-silent-rules  --disable-sqlite --disable-alsa --disable-mpeg --disable-full-suite
TWOLAME_CFG      ?= --quiet --enable-silent-rules
TWOLAME_BUILD    ?= $(MAKE) -C libtwolame -j$(JOBS)
TWOLAME_INSTALL  ?= $(MAKE) -C libtwolame install && $(MAKE) install-pkgconfigDATA
WAVPACK_CFG      ?= --quiet --enable-silent-rules --disable-apps --disable-asm --disable-man --disable-tests
OPENCORE_AMR_CFG ?= --quiet --enable-silent-rules
VO_AMRWBENC_CFG  ?= --quiet --enable-silent-rules
LIBPNG_CFG       ?= --quiet --enable-silent-rules

# libmagic: compiled-in DEFAULT database location is rewritten (with sed, in
# src/Makefile.am and src/Makefile.in) to $(DIST_PREFIX)/$(DIST_MAGIC_DIR)/magic.
# libmagic appends '.mgc', so sox reads $(DIST_PREFIX)/$(DIST_MAGIC_DIR)/magic.mgc.
# 'make dist' copies the (unmodified) magic.mgc built here to exactly that place
# in every dist tree. Changing DIST_PREFIX / DIST_MAGIC_DIR therefore needs
# 'make rebuild-libmagic'
LIBMAGIC_DEFAULT_MAGIC ?= $(DIST_PREFIX)/$(DIST_MAGIC_DIR)/magic
LIBMAGIC_PRE     ?= for f in src/Makefile.am src/Makefile.in; do LC_ALL=C sed -e 's|^MAGIC = .*|MAGIC = $(LIBMAGIC_DEFAULT_MAGIC)|' $$f > $$f.tmp && mv $$f.tmp $$f; grep -q '^MAGIC = $(LIBMAGIC_DEFAULT_MAGIC)$$' $$f || { echo "ERROR: could not set the default magic path in $$f"; exit 1; }; done; touch aclocal.m4; sleep 1; touch configure; sleep 1; find . -name Makefile.in -exec touch {} +; touch config.h.in
LIBMAGIC_CFG     ?= --quiet --enable-silent-rules --enable-zlib --disable-bzlib --disable-xzlib --disable-zstdlib --disable-lzlib --disable-libseccomp

# SoX: libraries are auto-detected by its configure script. Static archives do
# not record their own dependencies in the link tests, so list them in LIBS.
SOX_EXTRA_LIBS   ?= -lmpg123 -lopusfile -lopus -lvorbisfile -lvorbisenc -lvorbis -lFLAC -logg -lz -lm -lc++
# sox_version()/sox_version_info() are declared 'pure' in src/sox.h although
# they fill static buffers. Optimising clang (macOS) then drops the call and
# 'sox --version' prints 'SoX v' without the number. The sed below removes
# LSX_RETURN_PURE from exactly those two declarations (and fails the build if
# it is still there afterwards).
SOX_FIX_VERSION  ?= LC_ALL=C sed -e '/^LSX_RETURN_VALID_Z LSX_RETURN_PURE$$/{N;N;N;/sox_version(void);/s/ LSX_RETURN_PURE//;}' -e '/^LSX_RETURN_VALID LSX_RETURN_PURE$$/{N;N;N;/sox_version_info(void);/s/ LSX_RETURN_PURE//;}' src/sox.h > src/sox.h.tmp && mv src/sox.h.tmp src/sox.h; if grep -B3 -E '^sox_version(_info)?\(void\);' src/sox.h | grep -q LSX_RETURN_PURE; then echo "ERROR: could not remove LSX_RETURN_PURE from sox_version()/sox_version_info()"; exit 1; fi
SOX_PRE          ?= $(SOX_FIX_VERSION); $(if $(filter yes,$(SOX_AUTORECONF)),autoreconf -fi,:); export LIBS="$(SOX_EXTRA_LIBS)"
SOX_CFG          ?= --quiet --enable-silent-rules --without-libltdl

# -----------------------------------------------------------------------------
# 6. Internals
# -----------------------------------------------------------------------------
NATIVE_ARCH   := $(shell uname -m)
triple_x86_64 := x86_64-apple-darwin
triple_arm64  := aarch64-apple-darwin

VALID_ARCHS := x86_64 arm64
$(foreach a,$(ARCHS),$(if $(filter $(a),$(VALID_ARCHS)),,$(error Unsupported architecture '$(a)'; use x86_64 and/or arm64)))
$(if $(strip $(ARCHS)),,$(error ARCHS is empty))
$(if $(triple_$(NATIVE_ARCH)),,$(error Unsupported host architecture '$(NATIVE_ARCH)'))
SYSROOT_FLAGS := $(if $(MACOS_SDK),-isysroot $(MACOS_SDK))

# ---- read DEPENDENCIES.txt -> <PKG>_DEPS variables ----
$(if $(wildcard $(DEPENDENCIES_FILE)),,$(error Cannot find $(DEPENDENCIES_FILE)))
uc = $(shell echo '$(1)' | tr 'a-z-' 'A-Z_')
DEP_TOKENS := $(shell sed -e 's/[\#].*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' -e '/^$$/d' -e 's/:[[:space:]]*/:/' -e 's/[[:space:]][[:space:]]*/:/g' '$(DEPENDENCIES_FILE)')
$(foreach t,$(DEP_TOKENS),$(eval $(call uc,$(firstword $(subst :, ,$(t))))_DEPS := $(wordlist 2,100,$(subst :, ,$(t)))))

# ---- helpers ----
pv      = $($(call uc,$(1))_$(2))
archive = $(DOWNLOAD_DIR)/$(notdir $(call pv,$(1),URL))
stamp   = $(DEPS_DIR)/$(2)/.stamps/$(1)-$(call pv,$(1),VERSION).stamp
tstamp  = $(TOOLCHAIN_DIR)/.stamps/$(1)-$(call pv,$(1),VERSION).stamp
TOOLCHAIN_STAMPS := $(foreach t,$(TOOLS),$(call tstamp,$(t)))

# Environment for native toolchain builds
tool_exports = export PATH="$(TOOLCHAIN_DIR)/bin:$$PATH"; \
	export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CC="$(TARGET_CC) -arch $(NATIVE_ARCH) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CFLAGS="$(OPT_FLAGS) $(LEGACY_WARN)"; \
	export MAKEINFO=true HELP2MAN=true; \
	unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR LIBS CPPFLAGS LDFLAGS;

# Environment for per-architecture library builds ($(1) = arch; needs $$pfx set)
arch_exports = export PATH="$(TOOLCHAIN_DIR)/bin:$$PATH"; \
	export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CC="$(TARGET_CC) -arch $(1) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CXX="$(TARGET_CXX) -arch $(1) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -stdlib=libc++"; \
	export CFLAGS="$(OPT_FLAGS) $(LEGACY_WARN)"; \
	export CXXFLAGS="$(OPT_FLAGS)"; \
	export CPPFLAGS="-I$$pfx/include"; \
	export LDFLAGS="-L$$pfx/lib"; \
	export PKG_CONFIG="$(TOOLCHAIN_DIR)/bin/pkgconf --static"; \
	export PKG_CONFIG_LIBDIR="$$pfx/lib/pkgconfig:$$pfx/share/pkgconfig"; \
	unset PKG_CONFIG_PATH LIBS; \
	export AR=ar RANLIB=ranlib; \
	export ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes; \
	export MAKEINFO=true;

# Refresh config.sub/config.guess so old packages recognise arm64 macOS
refresh_config = for f in config.sub config.guess; do for t in $$(find . -name $$f -type f); do cp "$$(ls $(TOOLCHAIN_DIR)/share/automake-*/$$f | tail -n 1)" "$$t"; done; done

autoconf_cmd  = ./configure --prefix="$$pfx" --host=$(triple_$(2)) --build=$(triple_$(NATIVE_ARCH)) --enable-static --disable-shared --disable-dependency-tracking $(call pv,$(1),CFG)
configure_cmd = $(if $(call pv,$(1),CONFIGURE),$(call pv,$(1),CONFIGURE),$(call autoconf_cmd,$(1),$(2)))

download = @set -e; mkdir -p "$(DOWNLOAD_DIR)"; \
	echo ">>> Downloading $(call pv,$(1),URL)"; \
	curl -sfL --retry 3 --connect-timeout 10 -o "$@.part" "$(call pv,$(1),URL)"; \
	if [ -n "$(call pv,$(1),SHA256)" ]; then echo "$(call pv,$(1),SHA256)  $@.part" | shasum -a 256 -c -; fi; \
	mv "$@.part" "$@"

build_tool = @set -e; \
	echo ">>> [toolchain] $(1) $(call pv,$(1),VERSION)"; \
	src="$(BUILD_DIR)/toolchain/$(1)"; \
	rm -rf "$$src"; mkdir -p "$$src" "$(dir $@)"; \
	tar -xf "$(call archive,$(1))" -C "$$src" --strip-components=1; \
	cd "$$src"; \
	$(tool_exports) \
	./configure --quiet --enable-silent-rules --prefix="$(TOOLCHAIN_DIR)" $(call pv,$(1),CFG); \
	$(MAKE) -j$(JOBS); \
	if [ -L "$(TOOLCHAIN_DIR)/bin/$(1)" ]; then rm -f "$(TOOLCHAIN_DIR)/bin/$(1)"; fi; \
	$(MAKE) install; \
	if [ "$(1)" = "pkgconf" ]; then ln -sf pkgconf "$(TOOLCHAIN_DIR)/bin/pkg-config"; fi; \
	touch "$@"

build_pkg = @set -e; \
	pfx="$(DEPS_DIR)/$(2)"; \
	echo ">>> [$(2)] $(1) $(call pv,$(1),VERSION)"; \
	src="$(BUILD_DIR)/$(2)/$(1)"; \
	rm -rf "$$src"; mkdir -p "$$src" "$$pfx/.stamps"; \
	tar -xf "$(call archive,$(1))" -C "$$src" --strip-components=1; \
	cd "$$src"; \
	$(call arch_exports,$(2)) \
	$(refresh_config); \
	$(or $(call pv,$(1),PRE),:); \
	$(call configure_cmd,$(1),$(2)); \
	$(or $(call pv,$(1),BUILD),$(MAKE) -j$(JOBS)); \
	$(or $(call pv,$(1),INSTALL),$(MAKE) install); \
	$(or $(call pv,$(1),POST),:); \
	touch "$@"

# ---- rule templates ----
define DL_TEMPLATE
$(call archive,$(1)):
	$$(call download,$(1))
endef

define TOOL_TEMPLATE
$(call tstamp,$(1)): $(call archive,$(1)) $(foreach d,$(call pv,$(1),DEPS),$(call tstamp,$(d)))
	+$$(call build_tool,$(1))
.PHONY: $(1) clean-$(1) rebuild-$(1)
$(1): $(call tstamp,$(1))
clean-$(1):
	@rm -f "$(TOOLCHAIN_DIR)"/.stamps/$(1)-*.stamp
	@rm -rf "$(BUILD_DIR)/toolchain/$(1)"
rebuild-$(1): clean-$(1)
	@$$(MAKE) $(1)
endef

define PKG_PHONY
.PHONY: $(1) clean-$(1) rebuild-$(1)
$(1): $(foreach a,$(ARCHS),$(1)-$(a))
clean-$(1):
	@rm -f "$(DEPS_DIR)"/*/.stamps/$(1)-*.stamp
	@rm -rf "$(BUILD_DIR)"/*/$(1)
rebuild-$(1): clean-$(1)
	@$$(MAKE) $(1)
endef

define PKG_TEMPLATE
$(call stamp,$(1),$(2)): $(call archive,$(1)) $(foreach d,$(filter-out $(TOOLS),$(call pv,$(1),DEPS)),$(call stamp,$(d),$(2))) | $(TOOLCHAIN_STAMPS)
	+$$(call build_pkg,$(1),$(2))
.PHONY: $(1)-$(2)
$(1)-$(2): $(call stamp,$(1),$(2))
endef

$(foreach p,$(DL_LIST),$(eval $(call DL_TEMPLATE,$(p))))
$(foreach t,$(TOOLS),$(eval $(call TOOL_TEMPLATE,$(t))))
$(foreach p,$(ALL_PKGS),$(eval $(call PKG_PHONY,$(p))))
$(foreach p,$(ALL_PKGS),$(foreach a,$(ARCHS),$(eval $(call PKG_TEMPLATE,$(p),$(a)))))

# -----------------------------------------------------------------------------
# 7. Main targets
# -----------------------------------------------------------------------------
.PHONY: all check-system download toolchain deps dist licenses package verify \
	info versions graph help clean distclean purge

all: check-system dist licenses
	@echo ""
	@echo "Build finished: $(DIST_MAIN)/bin/sox   (run 'make verify' to check it)"

check-system:
	@set -e; ok=1; \
	echo "Checking build prerequisites..."; \
	for t in clang clang++ make tar curl perl xcrun lipo otool strip shasum sed awk; do \
	  if command -v $$t >/dev/null 2>&1; then echo "  [ok]      $$t"; else echo "  [MISSING] $$t"; ok=0; fi; \
	done; \
	if xcode-select -p >/dev/null 2>&1; then echo "  [ok]      Command Line Tools ($$(xcode-select -p))"; \
	else echo "  [MISSING] Command Line Tools - run: xcode-select --install"; ok=0; fi; \
	if [ -z "$(MACOS_SDK)" ]; then echo "  [MISSING] macOS SDK (xcrun --show-sdk-path failed)"; ok=0; fi; \
	[ $$ok = 1 ] || { echo "Prerequisites missing - see README.md"; exit 1; }

download: $(foreach p,$(DL_LIST),$(call archive,$(p)))
	@echo "All source archives are in $(DOWNLOAD_DIR)"

toolchain: $(TOOLS)
deps: $(PACKAGES)

# $(1) = output folder name (an arch, or 'universal'), $(2) = archs merged into
# it. One arch -> files are copied; several -> merged with lipo.
dist_assemble = out="$(OUTPUT_DIR)/$(1)$(DIST_PREFIX)"; first="$(DEPS_DIR)/$(firstword $(2))"; \
	echo ">>> dist: $(1) [$(2)] -> $$out"; \
	rm -rf "$(OUTPUT_DIR)/$(1)"; mkdir -p "$$out/bin" "$$out/lib" "$$out/include"; \
	for n in sox soxi play rec; do \
	  f="$$first/bin/$$n"; o="$$out/bin/$$n"; \
	  if [ ! -e "$$f" ] && [ ! -L "$$f" ]; then continue; fi; \
	  if [ -L "$$f" ]; then ln -s "$$(readlink "$$f")" "$$o"; \
	  elif [ "$(words $(2))" = "1" ]; then cp "$$f" "$$o"; \
	  else lipo -create $(foreach a,$(2),"$(DEPS_DIR)/$(a)/bin/$$n") -output "$$o"; fi; \
	  if [ ! -L "$$o" ] && [ "$(STRIP_BINARIES)" = "yes" ]; then strip -x "$$o"; fi; \
	done; \
	if [ -f "$$first/lib/libsox.a" ]; then \
	  if [ "$(words $(2))" = "1" ]; then cp "$$first/lib/libsox.a" "$$out/lib/libsox.a"; \
	  else lipo -create $(foreach a,$(2),"$(DEPS_DIR)/$(a)/lib/libsox.a") -output "$$out/lib/libsox.a"; fi; \
	  cp "$$first/include/sox.h" "$$out/include/"; \
	fi; \
	for m in man1/sox.1 man1/soxi.1 man1/play.1 man1/rec.1 man7/soxformat.7 man3/libsox.3; do \
	  if [ -f "$$first/share/man/$$m" ]; then \
	    mkdir -p "$$out/share/man/$$(dirname $$m)"; cp "$$first/share/man/$$m" "$$out/share/man/$$m"; \
	  fi; \
	done; \
	if [ -f "$$first/share/misc/magic.mgc" ]; then \
	  mkdir -p "$$out/$(DIST_MAGIC_DIR)"; cp "$$first/share/misc/magic.mgc" "$$out/$(DIST_MAGIC_DIR)/magic.mgc"; \
	else echo "    note: magic.mgc not found in $$first/share/misc (run: make rebuild-libmagic)"; fi; \
	echo "    $$(lipo -info "$$out/bin/sox")";

dist: $(foreach a,$(ARCHS),$(call stamp,sox,$(a)))
	@set -e; \
	$(foreach a,$(ARCHS),$(call dist_assemble,$(a),$(a))) \
	$(if $(word 2,$(ARCHS)),$(call dist_assemble,universal,$(ARCHS)),rm -rf "$(OUTPUT_DIR)/universal";) \
	true

# ---- licences ---------------------------------------------------------------
# Collected from the ORIGINAL source archives (so 'make clean' does not matter):
#   SoX             -> <tree><prefix>/<DIST_LICENSES_DIR>/
#   each dependency -> <tree><prefix>/<DIST_LICENSES_DIR>/vendors/<software_name>/
#  Root-level files named COPYING*, LICEN[CS]E*, COPYRIGHT*, NOTICE*, LGPL*,
#  GPL* (and <PKG>_LICENSE_FILES) are copied.
lic_collect = tmp="$(BUILD_DIR)/licenses-src/$(1)"; rm -rf "$$tmp"; mkdir -p "$$tmp"; \
	tar -xf "$(call archive,$(1))" -C "$$tmp" --strip-components=1; \
	dest="$$stage/$(if $(filter sox,$(1)),,vendors/$(1))"; mkdir -p "$$dest"; n=0; \
	for f in $$(find "$$tmp" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICEN[CS]E*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname 'LGPL*' -o -iname 'GPL*' $(foreach x,$(call pv,$(1),LICENSE_FILES),-o -name '$(x)') \)); do \
	  cp "$$f" "$$dest/"; n=$$((n+1)); \
	done; \
	if [ $$n -eq 0 ]; then echo "    WARNING: no licence file found in $(1)"; else echo "    $(1): $$n file(s)"; fi; \
	rm -rf "$$tmp";

licenses: dist $(foreach p,$(ALL_PKGS),$(call archive,$(p)))
	@set -e; stage="$(BUILD_DIR)/licenses"; \
	rm -rf "$$stage" "$(BUILD_DIR)/licenses-src"; mkdir -p "$$stage"; \
	echo ">>> licenses: collecting from source archives"; \
	$(foreach p,$(ALL_PKGS),$(call lic_collect,$(p))) \
	for t in $(ARCHS) $(if $(word 2,$(ARCHS)),universal); do \
	  d="$(OUTPUT_DIR)/$$t$(DIST_PREFIX)/$(DIST_LICENSES_DIR)"; \
	  rm -rf "$$d"; mkdir -p "$$d"; cp -R "$$stage/." "$$d/"; \
	  echo "    -> $$d"; \
	done; \
	rm -rf "$$stage" "$(BUILD_DIR)/licenses-src"

# Build one .pkg per built arch (and one for 'universal' when several archs were
# built) from the matching $(OUTPUT_DIR)/<arch> tree. The trees already contain
# the install prefix (e.g. usr/local/...), so the payload root is installed at
#  '/'. $(1) = dist sub-folder / name suffix: an arch or 'universal'.
pkg_build = out="$(PACKAGE_DIR)/sox-$(SOX_VERSION)-darwin-$(1).pkg"; \
	if [ ! -d "$(OUTPUT_DIR)/$(1)" ]; then echo "Missing $(OUTPUT_DIR)/$(1) - run 'make dist' first"; exit 1; fi; \
	rm -f "$$out"; \
	echo ">>> package: $$out"; \
	pkgbuild --root "$(OUTPUT_DIR)/$(1)" --identifier "$(PKG_IDENTIFIER)" --version "$(PKG_VERSION)" \
	  --install-location / --ownership recommended --filter '/\.DS_Store$$' "$$out" >/dev/null; \
	echo "    $$(ls -lh "$$out" | awk '{print $$5}')  $$out";

package: licenses
	@set -e; \
	command -v pkgbuild >/dev/null 2>&1 || { echo "pkgbuild not found (it is part of macOS)"; exit 1; }; \
	mkdir -p "$(PACKAGE_DIR)"; \
	$(foreach a,$(ARCHS),$(call pkg_build,$(a))) \
	$(if $(word 2,$(ARCHS)),$(call pkg_build,universal)) \
	true

verify:
	@set -e; bin="$(DIST_MAIN)/bin/sox"; \
	[ -x "$$bin" ] || { echo "Missing $$bin - run 'make' first"; exit 1; }; \
	echo "Architectures : $$(lipo -archs "$$bin")"; \
	echo "Linked against:"; \
	otool -L "$$bin" | grep -E '^[[:space:]]' | sed 's/^[[:space:]]*/    /'; \
	bad=$$(otool -L "$$bin" | grep -E '^[[:space:]]' | awk '{print $$1}' | grep -Ev '^(/usr/lib/|/System/Library/)' || true); \
	if [ -n "$$bad" ]; then echo "ERROR: non-system dynamic libraries found:"; echo "$$bad"; exit 1; fi; \
	fmts=$$("$$bin" --help 2>&1 | grep 'AUDIO FILE FORMATS' || true); \
	echo "$$fmts"; missing=""; \
	for f in $(REQUIRED_FORMATS); do echo "$$fmts" | grep -qw -- "$$f" || missing="$$missing $$f"; done; \
	if [ -n "$$missing" ]; then \
	  echo "ERROR: formats missing from sox:$$missing"; \
	  echo "       check $(BUILD_DIR)/<arch>/sox/config.log"; exit 1; \
	fi; \
	echo "OK: only system libraries are linked and all required formats are present."

# -----------------------------------------------------------------------------
# 8. Information / housekeeping
# -----------------------------------------------------------------------------
info:
	@echo "Architectures          : $(ARCHS)   (host: $(NATIVE_ARCH))"
	@echo "Deployment target      : macOS $(MACOSX_DEPLOYMENT_TARGET)"
	@echo "SDK                    : $(MACOS_SDK)"
	@echo "Parallel jobs          : $(JOBS)"
	@echo "Downloads              : $(DOWNLOAD_DIR)"
	@echo "Toolchain              : $(TOOLCHAIN_DIR)"
	@echo "Build trees            : $(BUILD_DIR)"
	@echo "Static libs (per arch) : $(DEPS_DIR)/<arch>"
	@echo "Output                 : $(OUTPUT_DIR)/<arch|universal>$(DIST_PREFIX)"
	@echo "Packages               : $(PACKAGE_DIR)/sox-$(SOX_VERSION)-darwin_<arch|universal>.pkg ($(PKG_IDENTIFIER))"
	@echo "Dependency map         : $(DEPENDENCIES_FILE)"

versions:
	@$(foreach p,$(TOOLS) $(ALL_PKGS),echo "  $(p) $(call pv,$(p),VERSION)";)

graph:
	@$(foreach p,$(TOOLS) $(ALL_PKGS),echo "  $(p): $(call pv,$(p),DEPS)";)

help:
	@echo "SoX static universal build for macOS"
	@echo ""
	@echo "  make                    build the toolchain, all libraries and SoX"
	@echo "  make dist               (re)assemble $(OUTPUT_DIR)/<arch>$(DIST_PREFIX) (and universal) from the per-arch builds"
	@echo "  make licenses           collect licence files into $(OUTPUT_DIR)/<tree>$(DIST_PREFIX)/$(DIST_LICENSES_DIR)"
	@echo "  make package            build .pkg installers (one per arch plus universal) into $(PACKAGE_DIR)"
	@echo "  make verify             check architectures, linkage and formats of the result"
	@echo "  make check-system       check prerequisites"
	@echo "  make download           download all source archives only"
	@echo "  make toolchain          build only the native toolchain"
	@echo "  make deps               build only the libraries (all architectures)"
	@echo "  make <name>             build one package (all architectures), e.g. make flac"
	@echo "  make <name>-<arch>      build one package for one arch, e.g. make flac-arm64"
	@echo "  make rebuild-<name>     force a rebuild of one package (then run 'make')"
	@echo "  make clean-<name>       forget one package (stamp plus build tree)"
	@echo "  make info | versions | graph"
	@echo "  make clean              remove build trees"
	@echo "  make distclean          also remove toolchain, libraries and output"
	@echo "  make purge              distclean and remove downloaded sources"
	@echo ""
	@echo "Toolchain : $(TOOLS)"
	@echo "Libraries : $(PACKAGES)"
	@echo "Target    : sox"
	@echo "Override variables on the command line or in config.mk (see README.md)."

clean:
	rm -rf "$(BUILD_DIR)"

distclean: clean
	@for d in "$(DEPS_DIR)" "$(TOOLCHAIN_DIR)" "$(OUTPUT_DIR)" "$(PACKAGE_DIR)"; do \
	  if [ "$$d" = "/" ] || [ "$$d" = "$$HOME" ] || [ "$$d" = "/usr" ] || [ "$$d" = "/usr/local" ]; then \
	    echo "Refusing to delete $$d"; exit 1; fi; \
	done
	rm -rf "$(DEPS_DIR)" "$(TOOLCHAIN_DIR)" "$(OUTPUT_DIR)" "$(PACKAGE_DIR)"

purge: distclean
	rm -rf "$(DOWNLOAD_DIR)"
