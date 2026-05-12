#!/bin/bash
# build.sh  --  IsoGSM ARM64 / GFortran all-in-one build script
#
# Usage:
#   ./build.sh [options]
#
# Options:
#   --skip-patch   Skip patch application (if already applied)
#   --libs-only    Build libs only
#   --gsm-only     Build gsm only (libs must already be built)
#   -jN            Number of parallel make jobs (default: 1)
#   -h, --help     Show this help

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Output utilities
# ─────────────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}${BOLD}>>> $* <<<${NC}"; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  Option parsing
# ─────────────────────────────────────────────────────────────────────────────
SKIP_PATCH=0
BUILD_LIBS=1
BUILD_GSM=1
JOBS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-patch) SKIP_PATCH=1 ;;
        --libs-only)  BUILD_GSM=0 ;;
        --gsm-only)   BUILD_LIBS=0 ;;
        -j*)          JOBS="${1#-j}" ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown option: $1  (use --help to see usage)" ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
#  Path setup (auto-detected from script location)
# ─────────────────────────────────────────────────────────────────────────────
ISOGSM_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBS_DIR="$ISOGSM_DIR/libs"
GSM_DIR="$ISOGSM_DIR/gsm"
SYSVARS="$ISOGSM_DIR/def/sysvars.defs"
PATCH_FILE="$ISOGSM_DIR/isogsm_arm64_gfortran.patch"
CONFIGURE_LIBS="$LIBS_DIR/configure-libs"
CONFIGURE_MODEL="$GSM_DIR/configure-model"

info "IsoGSM root : $ISOGSM_DIR"

# ─────────────────────────────────────────────────────────────────────────────
#  Dependency check
# ─────────────────────────────────────────────────────────────────────────────
step "Checking dependencies"

for cmd in gfortran mpif90 mpirun gcc make patch; do
    if command -v "$cmd" &>/dev/null; then
        info "$(printf '%-10s' $cmd) : $(command -v $cmd)"
    else
        die "'$cmd' not found. Please install it."
    fi
done

gfortran --version | head -1
mpif90   --version | head -1

# ─────────────────────────────────────────────────────────────────────────────
#  MPI directory auto-detection
# ─────────────────────────────────────────────────────────────────────────────
MPICH_DIR="$(cd "$(dirname "$(command -v mpif90)")/.." && pwd)"
info "MPICH_DIR   : $MPICH_DIR"

# ─────────────────────────────────────────────────────────────────────────────
#  Apply patch
# ─────────────────────────────────────────────────────────────────────────────
step "Applying patch (isogsm_arm64_gfortran.patch)"

[[ -f "$PATCH_FILE" ]] || die "Patch file not found: $PATCH_FILE"

if [[ $SKIP_PATCH -eq 1 ]]; then
    warn "--skip-patch specified. Skipping patch."
elif patch --dry-run -R -p1 -s -f < "$PATCH_FILE" &>/dev/null; then
    info "Patch already applied. Skipping."
else
    # Not yet applied: verify it can be applied cleanly first
    if ! patch --dry-run -p1 -s -f < "$PATCH_FILE" &>/dev/null; then
        die "Cannot apply patch. Files are in an unexpected state.\n" \
            "    Run: patch --dry-run -p1 < $PATCH_FILE  for details."
    fi
    patch -p1 < "$PATCH_FILE"
    info "Patch applied."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Runtime source fixes (ARM64/GFortran compatibility)
# ─────────────────────────────────────────────────────────────────────────────
step "Applying runtime source fixes"

export ISOGSM_DIR
python3 - <<'PYEOF'
import re, os, sys

BASE = os.environ['ISOGSM_DIR']

def patch_file(relpath, transform_fn):
    full = os.path.join(BASE, relpath)
    with open(full) as f:
        orig = f.read()
    fixed = transform_fn(orig)
    if fixed != orig:
        with open(full, 'w') as f:
            f.write(fixed)
        print(f"[FIXED] {relpath}")
    else:
        print(f"[OK]    {relpath} (already fixed)")

# ── fixrd.F / fixrd_clim.F / fixrd2.F ──────────────────────────────────────
def fix_fixrd(src):
    lines = src.split('\n')

    new_lines = []
    for line in lines:
        # 1. "      parameter(mbuf=N)" → "      integer, parameter :: mbuf=N"
        m = re.match(r'^(\s+)parameter\(mbuf=(.+)\)\s*$', line, re.IGNORECASE)
        if m:
            line = f'{m.group(1)}integer, parameter :: mbuf={m.group(2)}'

        # 2. "      character*1 cbuf(mbuf)" → "      character*1, allocatable :: cbuf(:)"
        if re.match(r'^\s+character\*1 cbuf\(mbuf\)\s*$', line, re.IGNORECASE):
            line = re.sub(r'character\*1 cbuf\(mbuf\)',
                          'character*1, allocatable :: cbuf(:)', line, flags=re.IGNORECASE)

        # 3. "      real*4, allocatable :: data4" → "      real, allocatable :: data4"
        if re.match(r'^\s+real\*4,\s+allocatable\s*::\s*data4', line, re.IGNORECASE):
            line = re.sub(r'\breal\*4\b', 'real', line, flags=re.IGNORECASE)

        new_lines.append(line)

    # 4. Insert "      allocate(cbuf(mbuf))" after the #endif that closes
    #    the "allocate(data4(...))" block, if not already present.
    if not any('allocate(cbuf(mbuf))' in l.lower() for l in new_lines):
        insert_at = None
        for i, line in enumerate(new_lines):
            if 'allocate' in line.lower() and 'data4' in line.lower():
                for j in range(i + 1, min(i + 5, len(new_lines))):
                    if re.match(r'\s*#endif\b', new_lines[j], re.IGNORECASE):
                        insert_at = j + 1
                        break
                break
        if insert_at is not None:
            new_lines.insert(insert_at, '      allocate(cbuf(mbuf))')

    # 5. Insert "      deallocate(cbuf)" before the LAST "close(lugb)",
    #    if not already present.
    if not any('deallocate(cbuf)' in l.lower() for l in new_lines):
        last_close = None
        for i, line in enumerate(new_lines):
            if re.match(r'^\s+close\s*\(\s*lugb\s*\)\s*$', line, re.IGNORECASE):
                last_close = i
        if last_close is not None:
            new_lines.insert(last_close, '      deallocate(cbuf)')

    return '\n'.join(new_lines)

for f in ['gsm/src/sfcl/fixrd.F',
          'gsm/src/sfcl/fixrd_clim.F',
          'gsm/src/p2sig/fixrd2.F']:
    patch_file(f, fix_fixrd)

# ── rdgb.F ──────────────────────────────────────────────────────────────────
def fix_rdgb(src):
    lines = src.split('\n')
    new_lines = []
    for line in lines:
        # 1. Remove "      PARAMETER(LLGRIB=...)" line entirely
        if re.match(r'^\s+PARAMETER\s*\(\s*LLGRIB\s*=', line, re.IGNORECASE):
            continue
        # 2. "      CHARACTER GRIB(LLGRIB)*1" → "      CHARACTER, ALLOCATABLE :: GRIB(:)"
        if re.match(r'^\s+CHARACTER\s+GRIB\s*\(\s*LLGRIB\s*\)\s*\*\s*1', line, re.IGNORECASE):
            indent = re.match(r'^(\s+)', line).group(1)
            line = f'{indent}CHARACTER, ALLOCATABLE :: GRIB(:)'
        new_lines.append(line)

    # 3. Insert "      ALLOCATE(GRIB(LGRIB))" before "CALL BAREAD(LUGB,...)"
    if not any('ALLOCATE(GRIB(' in l.upper() for l in new_lines):
        for i, line in enumerate(new_lines):
            if re.match(r'^\s+CALL BAREAD\s*\(\s*LUGB\b', line, re.IGNORECASE):
                new_lines.insert(i, '      ALLOCATE(GRIB(LGRIB))')
                break

    # 4. Insert "      DEALLOCATE(GRIB)" after "CALL W3FI63(...)"
    if not any('DEALLOCATE(GRIB)' in l.upper() for l in new_lines):
        for i, line in enumerate(new_lines):
            if re.match(r'^\s+CALL W3FI63\b', line, re.IGNORECASE):
                new_lines.insert(i + 1, '      DEALLOCATE(GRIB)')
                break

    return '\n'.join(new_lines)

patch_file('libs/lib/w3lib/rdgb.F', fix_rdgb)

# ── gsm_runs/runscr/mpisub.in (template) ────────────────────────────────────
# configure-scr generates mpisub from mpisub.in, so we fix the template.
# configure-scr must be re-run after this fix to regenerate mpisub.
def fix_mpisub_in(src):
    # Already fixed if PBS_NODEFILE conditional with --oversubscribe is present
    if 'if [ -n "$PBS_NODEFILE"' in src and '--oversubscribe' in src:
        return src
    # Replace "@MPIEXEC@  @MPIEXEC_ARGS@ $args ..." + post-run mpdexit lines
    src = re.sub(
        r'@MPIEXEC@  @MPIEXEC_ARGS@ \$args 1>\$here_dir/\$outs\.ft\$hx 2>&1\ncc=\$\?\n#\n\./mpdexit\.sh\nmpdallexit\n',
        'if [ -n "$PBS_NODEFILE" ] ; then\n'
        '\t@MPIEXEC@ --oversubscribe -hostfile $PBS_NODEFILE $args'
        ' 1>$here_dir/$outs.ft$hx 2>&1\n'
        'else\n'
        '\t@MPIEXEC@ --oversubscribe $args 1>$here_dir/$outs.ft$hx 2>&1\n'
        'fi\n'
        'cc=$?\n',
        src
    )
    return src

patch_file('gsm_runs/runscr/mpisub.in', fix_mpisub_in)

# ── def/sysvars.defs (add LD_LIBRARY_PATH to NICKNAME-MARCH HEADER block) ───
# configure-scr regenerates gsm_runs/HEADER from this block on every run via
# def/get_sysvars, so the fix must live here rather than in HEADER directly.
LD_LINE = 'export LD_LIBRARY_PATH=/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}'

def fix_sysvars_header(src):
    if LD_LINE in src:
        return src
    # Read NICKNAME from configure-libs
    nickname = ''
    cfg = os.path.join(BASE, 'libs/configure-libs')
    with open(cfg) as f:
        for ln in f:
            m = re.match(r'^NICKNAME=(.+)', ln.strip())
            if m:
                nickname = m.group(1).strip()
                break
    if not nickname:
        print('[WARN]  NICKNAME not found in configure-libs. Skipping sysvars.defs.')
        return src
    lines = src.split('\n')
    new_lines = []
    in_target = False
    for line in lines:
        if f':{nickname}-mpi:HEADER=<<EOF' in line:
            in_target = True
        if line == 'EOF':
            in_target = False
        new_lines.append(line)
        if in_target and line.strip() == 'ulimit -s unlimited':
            new_lines.append(LD_LINE)
    return '\n'.join(new_lines)

patch_file('def/sysvars.defs', fix_sysvars_header)
PYEOF

info "Runtime source fixes complete."

# ─────────────────────────────────────────────────────────────────────────────
#  Path configuration
# ─────────────────────────────────────────────────────────────────────────────
step "Configuring paths"

# sysvars.defs: GRSM_BASE_DIR
info "GRSM_BASE_DIR = $ISOGSM_DIR"
sed -i "s|^GRSM_BASE_DIR=.*|GRSM_BASE_DIR=$ISOGSM_DIR|" "$SYSVARS"

# sysvars.defs: NICKNAME:roses:MPICH_DIR
# Read NICKNAME from configure-libs and update the matching entry
NICKNAME="$(grep '^NICKNAME=' "$CONFIGURE_LIBS" | cut -d= -f2)"
info "NICKNAME = $NICKNAME, MPICH_DIR = $MPICH_DIR"

if grep -q "^NICKNAME:${NICKNAME}:MPICH_DIR=" "$SYSVARS"; then
    sed -i "s|^NICKNAME:${NICKNAME}:MPICH_DIR=.*|NICKNAME:${NICKNAME}:MPICH_DIR=$MPICH_DIR|" "$SYSVARS"
else
    warn "No NICKNAME:${NICKNAME}:MPICH_DIR entry found in sysvars.defs."
    warn "Add it manually or change NICKNAME in configure-libs."
fi

# configure-model: LIBS_DIR
info "LIBS_DIR = $LIBS_DIR"
sed -i "s|^LIBS_DIR=.*|LIBS_DIR=$LIBS_DIR|" "$CONFIGURE_MODEL"

# ─────────────────────────────────────────────────────────────────────────────
#  Build libs
# ─────────────────────────────────────────────────────────────────────────────
if [[ $BUILD_LIBS -eq 1 ]]; then
    step "Building libs"
    cd "$LIBS_DIR"

    info "Running configure-libs..."
    ./configure-libs

    info "make clean ..."
    make clean

    info "make (jobs=$JOBS) ..."
    make -j"$JOBS"

    info "libs build complete."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Build gsm
# ─────────────────────────────────────────────────────────────────────────────
if [[ $BUILD_GSM -eq 1 ]]; then
    step "Building gsm"
    cd "$GSM_DIR"

    info "Running configure-model..."
    ./configure-model

    info "make clean ..."
    make clean

    info "make (jobs=$JOBS) ..."
    make -j"$JOBS"

    info "gsm build complete."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Build report
# ─────────────────────────────────────────────────────────────────────────────
step "Build complete"

if [[ $BUILD_GSM -eq 1 ]]; then
    echo ""
    info "Executables generated ($GSM_DIR/bin/):"
    for x in "$GSM_DIR/bin/"*.x; do
        printf "    %s\n" "$(basename "$x")"
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Generate run scripts (configure-scr)
# ─────────────────────────────────────────────────────────────────────────────
step "Generating run scripts"
cd "$ISOGSM_DIR/gsm_runs"
info "Running configure-scr gsm..."
./configure-scr gsm
info "Run scripts generated."

# ─────────────────────────────────────────────────────────────────────────────
#  Final summary
# ─────────────────────────────────────────────────────────────────────────────
step "Done"

echo ""
info "Build finished successfully."
echo ""
echo "  To run the model:"
echo "    cd $ISOGSM_DIR/gsm_runs"
echo "    ./gsm"
echo ""
echo "  Note: LD_LIBRARY_PATH=/usr/local/lib is set in gsm_runs/HEADER."
