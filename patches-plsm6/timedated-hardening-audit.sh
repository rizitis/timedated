#!/bin/bash
#
# timedated-hardening-audit.sh
#
# Audits the timedated source tree against the OpenSSF "Compiler Options
# Hardening Guide for C and C++" (2026-06-30), using Patrick Volkerding's
# official Slackware SlackBuild flags as the baseline.
#
# It NEVER touches the system, never installs anything, and never modifies
# the source tree. All builds are out-of-tree, in a scratch directory.
#
# Phases:
#   0  environment      - what the toolchain already does by default
#   1  baseline build   - exactly Patrick's flags; what does GCC really get?
#   2  warnings audit   - Table 1 of the guide; zero binary impact
#   3  hardened build   - Table 2 of the guide; does it still compile?
#   4  ELF audit        - what mitigations are actually in the binaries
#   5  summary
#
# Usage:
#   ./timedated-hardening-audit.sh -s /path/to/timedated-VERSION
#   ./timedated-hardening-audit.sh -t /path/to/timedated-VERSION.tar.xz
#   ./timedated-hardening-audit.sh -e /usr/libexec/timedated   # ELF audit only
#
# Options:
#   -s DIR    source directory (unpacked)
#   -t FILE   source tarball (will be unpacked into the scratch dir)
#   -e FILE   ELF-audit an already-installed binary and exit
#   -o DIR    scratch/output dir (default: /tmp/timedated-audit)
#   -k        keep scratch dir contents from a previous run (skip rebuilds
#             whose build dir already exists)
#   -h        this help
#
# Requires: meson, ninja, gcc, binutils (readelf), file, python3
#

set -u -o pipefail

###############################################################################
# Config
###############################################################################

SRCDIR=""
TARBALL=""
ELF_ONLY=""
OUT="${OUT:-/tmp/timedated-audit}"
KEEP=0

# Patrick's SLKCFLAGS for x86_64, verbatim from timedated.SlackBuild:
SLKCFLAGS_X86_64="-O2 -march=x86-64 -mtune=generic -fPIC"
SLKCFLAGS_I686="-O2 -march=pentium4 -mtune=generic"
SLKCFLAGS_OTHER="-O2"

# Table 1 of the OpenSSF guide: compile-time only, zero binary impact.
# NOTE: no blanket -Werror. The guide explicitly says not to ship that.
WARNFLAGS="-Wall -Wextra -Wformat -Wformat=2 -Wconversion -Wsign-conversion \
-Wimplicit-fallthrough -Wtrampolines -Wbidi-chars=any -Wshadow -Wpointer-arith \
-Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition -Wvla \
-Wnull-dereference -Wdouble-promotion -Wwrite-strings"

# Table 2: runtime mitigations. -D_FORTIFY_SOURCE needs -O1 or higher, which
# the baseline -O2 provides. -U first, per the guide, to avoid redefinition
# warnings if the distro toolchain already predefines it.
HARDFLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 \
-fstrict-flex-arrays=3 -fstack-clash-protection -fstack-protector-strong \
-fcf-protection=full -fno-delete-null-pointer-checks -fno-strict-overflow \
-fno-strict-aliasing -ftrivial-auto-var-init=zero -fexceptions \
-fzero-init-padding-bits=all"
HARDLDFLAGS="-Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now \
-Wl,--as-needed -Wl,--no-copy-dt-needed-entries"

# meson setup options copied from the SlackBuild, so the comparison is fair.
MESONOPTS_FULL=(
  --prefix=/usr
  --libdir=lib64
  --libexecdir=/usr/libexec
  --bindir=/usr/bin
  --sbindir=/usr/sbin
  --includedir=/usr/include
  --datadir=/usr/share
  --mandir=/usr/man
  --sysconfdir=/etc
  --localstatedir=/var
  --buildtype=release
  -Dprivileged-group=wheel
  -Dhwclock_conf=/etc/hardwareclock
  -Dadjtime_conf=/etc/adjtime
  -Dntpd_conf=/etc/ntp.conf
  -Dntpd_rc=/etc/rc.d/rc.ntpd
)
MESONOPTS_MIN=( --prefix=/usr --buildtype=release )

NUMJOBS="-j $(( $(nproc 2>/dev/null || echo 2) + 1 ))"

###############################################################################
# Output helpers
###############################################################################

if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

hdr()  { printf '\n%s=== %s ===%s\n' "$B" "$*" "$N"; }
sub()  { printf '\n%s--- %s ---%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sOK  %s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %sNO  %s %s\n' "$R" "$N" "$*"; }
warn() { printf '  %s??  %s %s\n' "$Y" "$N" "$*"; }
info() { printf '       %s\n' "$*"; }
die()  { printf '%sfatal:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

###############################################################################
# Argument parsing
###############################################################################

while getopts "s:t:e:o:kh" opt; do
  case "$opt" in
    s) SRCDIR="$(readlink -f "$OPTARG")" ;;
    t) TARBALL="$(readlink -f "$OPTARG")" ;;
    e) ELF_ONLY="$(readlink -f "$OPTARG")" ;;
    o) OUT="$(readlink -f "$OPTARG")" ;;
    k) KEEP=1 ;;
    h) sed -n '3,40p' "$0" | sed 's/^# \?//' ; exit 0 ;;
    *) exit 1 ;;
  esac
done

###############################################################################
# ELF audit - the part that tells you what actually shipped
###############################################################################

elf_audit() {
  local f="$1" hits=0
  [ -f "$f" ] || { warn "not found: $f"; return 1; }

  local ftype dyn prog notes syms
  ftype="$(file -b "$f" 2>/dev/null)"
  case "$ftype" in *ELF*) ;; *) return 1 ;; esac

  prog="$(readelf -lW "$f" 2>/dev/null)"
  dyn="$(readelf -dW "$f" 2>/dev/null)"
  notes="$(readelf -nW "$f" 2>/dev/null)"
  # --dyn-syms alone misses statically-linked cases; ask for both.
  syms="$(readelf -sW "$f" 2>/dev/null)"

  printf '\n  %s%s%s\n' "$B" "$f" "$N"
  info "$(echo "$ftype" | cut -c1-100)"

  # --- PIE / ASLR ---------------------------------------------------------
  local etype
  etype="$(readelf -hW "$f" 2>/dev/null | awk '/^  Type:/{print $2}')"
  if [ "$etype" = "DYN" ]; then
    if echo "$dyn" | grep -q 'FLAGS_1.*PIE' || echo "$ftype" | grep -q 'pie executable'; then
      ok "PIE            full ASLR for the executable itself"
    else
      ok "DYN object     (shared library, or PIE without DF_1_PIE)"
    fi
  else
    bad "not PIE       ($etype) -- executable loads at a fixed address, no ASLR"
    hits=$((hits+1))
  fi

  # --- NX / noexecstack ---------------------------------------------------
  local gs
  gs="$(echo "$prog" | awk '/GNU_STACK/{print $7}')"
  if [ -z "$gs" ]; then
    bad "no GNU_STACK  kernel must assume executable stack"
    hits=$((hits+1))
  elif echo "$prog" | grep -q 'GNU_STACK.*RWE'; then
    bad "exec stack    -Wl,-z,noexecstack missing or a trampoline forced it"
    hits=$((hits+1))
  else
    ok "noexecstack    stack marked non-executable"
  fi

  # --- RELRO --------------------------------------------------------------
  local relro=0 now=0
  echo "$prog" | grep -q 'GNU_RELRO' && relro=1
  echo "$dyn" | grep -qE 'BIND_NOW|FLAGS_1.*NOW' && now=1
  if [ "$relro" = 1 ] && [ "$now" = 1 ]; then
    ok "full RELRO     GOT read-only after startup, lazy binding off"
  elif [ "$relro" = 1 ]; then
    warn "partial RELRO .got.plt still writable -- GOT overwrite still possible"
    info "add -Wl,-z,now for full RELRO"
    hits=$((hits+1))
  else
    bad "no RELRO      relocations stay writable for the process lifetime"
    hits=$((hits+1))
  fi

  # --- Stack protector ----------------------------------------------------
  if echo "$syms" | grep -q '__stack_chk_fail'; then
    ok "stack canary   __stack_chk_fail present"
  else
    warn "no canary     no __stack_chk_fail reference"
    info "either -fstack-protector* is off, or the strong heuristic found"
    info "no function worth instrumenting (small daemons: quite possible)"
  fi

  # --- FORTIFY_SOURCE -----------------------------------------------------
  # Must exclude __stack_chk_fail / __stack_chk_guard: those come from
  # -fstack-protector, not from _FORTIFY_SOURCE, and they end in _chk.
  # readelf -sW prints both .dynsym and .symtab, so de-duplicate as well.
  local fchk nchk
  fchk="$(echo "$syms" | grep -oE '__[a-z0-9_]+_chk\b' \
          | grep -v '^__stack_chk' | sort -u)"
  nchk="$(printf '%s' "$fchk" | grep -c . )"
  if [ "$nchk" -gt 0 ]; then
    ok "FORTIFY        $nchk distinct fortified libc call(s)"
    info "$(printf '%s' "$fchk" | tr '\n' ' ')"
  else
    warn "no FORTIFY    zero *_chk@GLIBC symbols"
    info "either _FORTIFY_SOURCE is off, or this code calls no fortifiable"
    info "libc function (memcpy/strcpy/sprintf/snprintf/...)"
  fi

  # --- Intel CET ----------------------------------------------------------
  if echo "$notes" | grep -q 'IBT'; then
    ok "CET IBT        indirect branch tracking (anti-JOP)"
  else
    bad "no IBT        -fcf-protection=full not applied"
    hits=$((hits+1))
  fi
  if echo "$notes" | grep -q 'SHSTK'; then
    ok "CET SHSTK      shadow stack (anti-ROP)"
  else
    bad "no SHSTK      -fcf-protection=full not applied"
    hits=$((hits+1))
  fi

  # --- RPATH / RUNPATH ----------------------------------------------------
  if echo "$dyn" | grep -qE 'RPATH|RUNPATH'; then
    bad "RPATH/RUNPATH $(echo "$dyn" | grep -E 'RPATH|RUNPATH' | head -1 | sed 's/^ *//')"
    info "a writable directory here is a privilege-escalation vector in a"
    info "root daemon; Slackware packages should carry none"
    hits=$((hits+1))
  else
    ok "no RPATH       clean dynamic section"
  fi

  # --- setuid sanity ------------------------------------------------------
  if [ -u "$f" ] || [ -g "$f" ]; then
    warn "setuid/setgid $(stat -c '%A %U:%G' "$f")"
  fi

  # --- Notes on what cannot be seen in the ELF ----------------------------
  info ""
  info "not detectable from the ELF: -fstack-clash-protection,"
  info "-fstrict-flex-arrays, -ftrivial-auto-var-init, -fno-strict-overflow"

  return "$hits"
}

if [ -n "$ELF_ONLY" ]; then
  hdr "ELF audit only"
  elf_audit "$ELF_ONLY"
  exit 0
fi

###############################################################################
# Prepare
###############################################################################

[ -n "$SRCDIR$TARBALL" ] || die "need -s SRCDIR or -t TARBALL (or -e BINARY). Try -h."

for t in gcc readelf file; do
  command -v "$t" >/dev/null || die "missing required tool: $t"
done
command -v meson >/dev/null || die "meson not found -- timedated is a meson project"
NINJA="${NINJA:-ninja}"
command -v "$NINJA" >/dev/null || die "ninja not found (set \$NINJA if it is named differently)"

mkdir -p "$OUT" || die "cannot create $OUT"
REPORT="$OUT/report.txt"

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "no such tarball: $TARBALL"
  rm -rf "$OUT/src"
  mkdir -p "$OUT/src"
  tar xf "$TARBALL" -C "$OUT/src" || die "tar extraction failed"
  SRCDIR="$(find "$OUT/src" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [ -n "$SRCDIR" ] || die "tarball contained no top-level directory"
fi
[ -f "$SRCDIR/meson.build" ] || die "$SRCDIR has no meson.build"

case "$(uname -m)" in
  x86_64) SLKCFLAGS="$SLKCFLAGS_X86_64" ;;
  i?86)   SLKCFLAGS="$SLKCFLAGS_I686" ;;
  *)      SLKCFLAGS="$SLKCFLAGS_OTHER" ;;
esac

exec > >(tee "$REPORT") 2>&1

hdr "timedated hardening audit"
info "source:   $SRCDIR"
info "scratch:  $OUT"
info "report:   $REPORT"
info "date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

###############################################################################
# Phase 0 - environment
###############################################################################

hdr "Phase 0 - toolchain defaults"
info "This is what Slackware's gcc already does before any SlackBuild flag."

sub "versions"
info "$(gcc --version | head -1)"
info "$(ld --version | head -1)"
info "$(meson --version 2>/dev/null | head -1 | sed 's/^/meson /')"
info "$(getconf GNU_LIBC_VERSION 2>/dev/null)"
info "kernel $(uname -r)  arch $(uname -m)"

sub "gcc build-time defaults"
GCCCFG="$(gcc -v 2>&1 | grep -o '\-\-enable-default[^ ]*\|--enable-cet[^ ]*\|--with-default[^ ]*')"
if [ -n "$GCCCFG" ]; then
  echo "$GCCCFG" | while read -r l; do info "$l"; done
else
  info "no --enable-default-* in the gcc configure line"
  info "=> upstream GCC defaults: no PIE, no SSP, no FORTIFY unless asked"
fi

sub "predefined macros at -O2"
PRE="$(gcc -O2 -dM -E - </dev/null 2>/dev/null)"
if echo "$PRE" | grep -q '_FORTIFY_SOURCE'; then
  ok "$(echo "$PRE" | grep '_FORTIFY_SOURCE')"
else
  bad "_FORTIFY_SOURCE is NOT predefined -- nothing fortified unless the"
  info "SlackBuild passes it, and Patrick's timedated.SlackBuild does not"
fi
echo "$PRE" | grep -q '__SSP_STRONG__' \
  && ok "__SSP_STRONG__ predefined (stack protector on by default)" \
  || bad "no __SSP_STRONG__ -- stack protector off by default"
echo "$PRE" | grep -q '__PIE__' \
  && ok "__PIE__ predefined (PIE by default)" \
  || bad "no __PIE__ -- executables are not PIE by default"
echo "$PRE" | grep -q '__CET__' \
  && ok "__CET__ predefined (control-flow protection on by default)" \
  || bad "no __CET__ -- no IBT/SHSTK by default"

###############################################################################
# Build helper
###############################################################################

# do_build <name> <cflags> <ldflags>
do_build() {
  local name="$1" cflags="$2" ldflags="$3"
  local bd="$OUT/build-$name" log="$OUT/$name.log"

  if [ "$KEEP" = 1 ] && [ -f "$bd/build.ninja" ]; then
    info "reusing existing $bd (-k)"
    return 0
  fi

  rm -rf "$bd"
  ( cd "$SRCDIR" || exit 1
    export CFLAGS="$cflags"
    export CXXFLAGS="$cflags"
    export LDFLAGS="$ldflags"
    if ! meson setup "${MESONOPTS_FULL[@]}" "$bd" . >"$log" 2>&1; then
      echo "[audit] full option set rejected, retrying minimal" >>"$log"
      rm -rf "$bd"
      meson setup "${MESONOPTS_MIN[@]}" "$bd" . >>"$log" 2>&1 || exit 2
    fi
    "$NINJA" -C "$bd" $NUMJOBS >>"$log" 2>&1 || exit 3
  )
  local rc=$?
  case "$rc" in
    0) ok "build '$name' succeeded  ($log)" ;;
    2) bad "build '$name': meson setup FAILED  ($log)"; tail -20 "$log" | sed 's/^/       /' ;;
    3) bad "build '$name': compile FAILED  ($log)"
       grep -m10 -E 'error:|FAILED' "$log" | sed 's/^/       /' ;;
  esac
  return $rc
}

find_elfs() {
  find "$1" -type f ! -name '*.o' ! -name '*.a' ! -name '*.p' \
    ! -path '*/meson-private/*' ! -path '*/meson-info/*' \
    ! -name 'sanity_check*' \
    -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print 2>/dev/null
}

# probe_flags <compile|link> <flags...> -> echoes only the supported ones.
# Necessary because the OpenSSF set spans GCC 12..15: -fstrict-flex-arrays
# needs 13, -fzero-init-padding-bits needs 15. Slackware-current and
# Slackware 15.0 will not accept the same list.
probe_flags() {
  local mode="$1"; shift
  local keep=() f
  # A link probe needs a real main(); /dev/null links with "undefined
  # reference to main" and would reject every single flag.
  local probe="${OUT:-/tmp}/.probe.c"
  printf 'int main(void){return 0;}\n' > "$probe" 2>/dev/null || probe=""
  for f in "$@"; do
    if [ "$mode" = link ]; then
      if [ -n "$probe" ] && gcc "$f" "$probe" -o /dev/null >/dev/null 2>&1; then
        keep+=("$f")
      else
        printf '  %s--  %s dropped (linker rejects): %s\n' "$Y" "$N" "$f" >&2
      fi
    else
      if gcc -Werror "$f" -x c -c /dev/null -o /dev/null >/dev/null 2>&1; then
        keep+=("$f")
      else
        printf '  %s--  %s dropped (compiler rejects): %s\n' "$Y" "$N" "$f" >&2
      fi
    fi
  done
  [ -n "$probe" ] && rm -f "$probe"
  printf '%s' "${keep[*]:-}"
}

###############################################################################
# Phase 1 - baseline: exactly what Patrick ships
###############################################################################

hdr "Phase 1 - baseline build (Patrick's flags, verbatim)"
info "CFLAGS=\"$SLKCFLAGS\""
info "LDFLAGS unset, --buildtype=release"

do_build baseline "$SLKCFLAGS" ""
BASE_RC=$?

if [ "$BASE_RC" = 0 ]; then
  sub "what the compiler ACTUALLY received"
  CC_JSON="$OUT/build-baseline/compile_commands.json"
  if [ -f "$CC_JSON" ]; then
    python3 - "$CC_JSON" <<'PY'
import json, sys, re, collections
cmds = json.load(open(sys.argv[1]))
if not cmds:
    print("       (compile_commands.json is empty)"); sys.exit()
c = cmds[0]
line = c.get("command") or " ".join(c.get("arguments", []))
args = line.split()
interesting = [a for a in args if a.startswith(("-O","-f","-W","-D","-m","-g"))]
print("       first translation unit: %s" % c.get("file","?"))
for a in interesting:
    print("         %s" % a)
opt = [a for a in args if re.fullmatch(r"-O\w?", a)]
print()
if len(opt) > 1:
    print("       NOTE: multiple -O levels present: %s" % " ".join(opt))
    print("             the LAST one wins -> %s" % opt[-1])
    if opt[-1] != "-O2":
        print("             meson's --buildtype=release (-O3) is overriding")
        print("             SLKCFLAGS -O2, or vice versa. Verify this.")
    else:
        print("             SLKCFLAGS -O2 wins over meson's release -O3. Good:")
        print("             -O2 is what the OpenSSF guide assumes.")
elif opt:
    print("       optimisation level: %s" % opt[0])
PY
  else
    warn "no compile_commands.json (old meson?) -- falling back to ninja"
    "$NINJA" -C "$OUT/build-baseline" -t commands 2>/dev/null | head -1 \
      | tr ' ' '\n' | grep -E '^-[OfWDm]' | sed 's/^/         /'
  fi

  sub "baseline binaries"
  BASE_ELFS="$(find_elfs "$OUT/build-baseline")"
  if [ -z "$BASE_ELFS" ]; then
    warn "no ELF binaries found in the build dir"
  else
    for e in $BASE_ELFS; do elf_audit "$e"; done
  fi
fi

###############################################################################
# Phase 2 - warnings audit (Table 1: zero binary impact)
###############################################################################

hdr "Phase 2 - warnings audit"
info "OpenSSF Table 1. These change no code -- only diagnostics."
info "No blanket -Werror: the guide says never ship that in a source tree."

do_build warnings "$SLKCFLAGS $WARNFLAGS" ""
WARN_RC=$?
WLOG="$OUT/warnings.log"

if [ -f "$WLOG" ]; then
  NWARN=$(grep -c 'warning:' "$WLOG")
  sub "total: $NWARN warnings"

  if [ "$NWARN" -gt 0 ]; then
    echo "  by category (this is your triage order):"
    grep -o '\[-W[a-z0-9=-]*\]' "$WLOG" | sort | uniq -c | sort -rn \
      | sed 's/^/    /'

    echo
    echo "  by file:"
    grep 'warning:' "$WLOG" | sed 's/:[0-9]*:[0-9]*:.*//' \
      | sed "s|$SRCDIR/||" | sort | uniq -c | sort -rn | head -20 | sed 's/^/    /'

    echo
    echo "  ${B}HIGH PRIORITY${N} -- integer conversions in a root daemon that"
    echo "  parses D-Bus input. Every one of these is a candidate for the"
    echo "  same class of bug as the signed/unsigned overflow already fixed:"
    grep -E 'warning:.*\[-W(conversion|sign-conversion|sign-compare)\]' "$WLOG" \
      | sed "s|$SRCDIR/||" | head -40 | sed 's/^/    /'
    CONVN=$(grep -cE 'warning:.*\[-W(conversion|sign-conversion|sign-compare)\]' "$WLOG")
    [ "$CONVN" -gt 40 ] && echo "    ... and $((CONVN-40)) more (see $WLOG)"

    echo
    echo "  ${B}ALWAYS A BUG${N} -- these should be zero:"
    for w in implicit-fallthrough implicit-function-declaration \
             int-conversion incompatible-pointer-types return-type \
             format-security null-dereference uninitialized vla; do
      n=$(grep -c "\[-W$w\]" "$WLOG")
      [ "$n" -gt 0 ] && printf '    %-34s %s\n' "-W$w" "$n"
    done
    grep -E "\[-W(implicit-fallthrough|int-conversion|incompatible-pointer-types|return-type|format-security|null-dereference)\]" \
      "$WLOG" | sed "s|$SRCDIR/||" | head -20 | sed 's/^/    /'
  else
    ok "clean under the full Table 1 warning set -- that is unusual and good"
  fi
fi

###############################################################################
# Phase 3 - hardened build (Table 2)
###############################################################################

hdr "Phase 3 - hardened build"
info "OpenSSF Table 2 on top of Patrick's flags. Question this answers:"
info "does timedated even COMPILE hardened? If yes, the case for enabling"
info "it is a lot easier to make."

sub "probing which hardening flags this toolchain accepts"
HARDFLAGS="$(probe_flags compile $HARDFLAGS)"
HARDLDFLAGS="$(probe_flags link $HARDLDFLAGS)"
echo
info "CFLAGS  += $HARDFLAGS"
info "LDFLAGS += $HARDLDFLAGS"

do_build hardened "$SLKCFLAGS $HARDFLAGS" "$HARDLDFLAGS"
HARD_RC=$?

if [ "$HARD_RC" = 0 ]; then
  sub "hardened binaries"
  HARD_ELFS="$(find_elfs "$OUT/build-hardened")"
  for e in $HARD_ELFS; do elf_audit "$e"; done

  sub "size cost"
  if [ -n "${BASE_ELFS:-}" ]; then
    for h in $HARD_ELFS; do
      bn="$(basename "$h")"
      b="$(echo "${BASE_ELFS:-}" | grep "/$bn\$" | head -1)"
      if [ -n "$b" ] && [ -f "$b" ]; then
        sb=$(stat -c %s "$b"); sh=$(stat -c %s "$h")
        printf '  %-24s %8d -> %8d bytes  (%+d%%)\n' \
          "$bn" "$sb" "$sh" "$(( (sh - sb) * 100 / (sb>0?sb:1) ))"
      fi
    done
  fi

  sub "smoke test"
  for h in $HARD_ELFS; do
    if "$h" --version >/dev/null 2>&1 || "$h" --help >/dev/null 2>&1; then
      ok "$(basename "$h") runs (--version/--help)"
    else
      warn "$(basename "$h") gave no clean --version/--help exit"
      info "expected for a D-Bus daemon that wants the system bus; not a failure"
    fi
  done
  info ""
  info "A compile is not a validation. Before believing anything here:"
  info "  - install the hardened build in a VM or container"
  info "  - exercise SetTime / SetTimezone / SetLocalRTC / SetNTP over D-Bus"
  info "  - re-check the RTCTimeUSec + LocalRTC path specifically"
  info "  -ftrivial-auto-var-init=zero and -fstrict-flex-arrays=3 are the two"
  info "   flags here most likely to change behaviour, not just codegen"
else
  bad "hardened build failed -- see $OUT/hardened.log"
  info "Try bisecting: drop -fzero-init-padding-bits=all first (GCC 15+ only),"
  info "then -fstrict-flex-arrays=3, then -ftrivial-auto-var-init=zero."
fi

###############################################################################
# Phase 4 - the installed system binary, if present
###############################################################################

hdr "Phase 4 - installed system binaries"
FOUND=0
for cand in /usr/libexec/timedated /usr/sbin/timedated /usr/bin/timedated; do
  if [ -f "$cand" ]; then FOUND=1; elf_audit "$cand"; fi
done
if [ "$FOUND" = 0 ]; then
  info "no installed timedated binary found in the usual places"
  info "(if it lives elsewhere: $0 -e /path/to/binary)"
fi

###############################################################################
# Phase 5 - summary
###############################################################################

hdr "Summary"

printf '  %-28s %s\n' "baseline build"  "$([ "${BASE_RC:-1}" = 0 ] && echo OK || echo FAILED)"
printf '  %-28s %s\n' "warnings build"  "$([ "${WARN_RC:-1}" = 0 ] && echo OK || echo FAILED)"
printf '  %-28s %s\n' "hardened build"  "$([ "${HARD_RC:-1}" = 0 ] && echo OK || echo FAILED)"
[ -f "$WLOG" ] && printf '  %-28s %s\n' "warnings found" "$(grep -c 'warning:' "$WLOG")"
[ -f "$WLOG" ] && printf '  %-28s %s\n' "  of which conversions" \
  "$(grep -cE '\[-W(conversion|sign-conversion|sign-compare)\]' "$WLOG")"

echo
echo "  Full report:      $REPORT"
echo "  Baseline log:     $OUT/baseline.log"
echo "  Warnings log:     $WLOG"
echo "  Hardened log:     $OUT/hardened.log"
echo
echo "  What to do with this:"
echo "   1. Phase 2 is the only part that is unambiguously yours to act on."
echo "      Fix real conversion bugs in the source; that is upstream work"
echo "      and needs nobody's permission."
echo "   2. Phase 1 vs 3 is evidence, not a patch. Do NOT change SLKCFLAGS"
echo "      in a SlackBuild you submit -- build flags are distribution"
echo "      policy, set once in the toolchain, not per package."
echo "   3. If Phase 3 is clean and Phase 4 shows mitigations missing, that"
echo "      is a concrete, empirical thing to raise with Pat: one package"
echo "      that already builds hardened with no source changes."
