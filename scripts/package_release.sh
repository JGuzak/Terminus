#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 [-n|--no-log] [-t|--throttle N] /path/to/output_dir"
    exit 1
}

# Defaults
NOLOG=0
THROTTLE=6
OUTPUT_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--no-log)
            NOLOG=1
            shift
            ;;
        -t|--throttle)
            THROTTLE="$2"
            shift 2
            ;;
        *)
            OUTPUT_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    usage
fi

SRC_DIR="./src"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: Source directory '$SRC_DIR' not found."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Initialize log file if logging enabled
if [[ $NOLOG -eq 0 ]]; then
    LOG_FILE="$OUTPUT_DIR/extract_log_$(date +%Y%m%d_%H%M%S).log"
    echo "" > "$LOG_FILE"
fi

log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
    if [[ $NOLOG -eq 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
    fi
}

# Find leaf project directories
mapfile -t PROJECT_DIRS < <(
    find "$SRC_DIR" -type d ! -path "$SRC_DIR" -exec bash -c '
        shopt -s nullglob
        subdirs=("$0"/*/)
        (( ${#subdirs[@]} == 0 )) && echo "$0"
    ' {} \;
)

TOTAL_PROJECTS=${#PROJECT_DIRS[@]}
if [[ $TOTAL_PROJECTS -eq 0 ]]; then
    log "No project folders found."
    exit 0
fi

log "Found $TOTAL_PROJECTS leaf projects. Processing with throttle=$THROTTLE..."

# Progress counter file
PROGRESS_FILE="$(mktemp)"
echo 0 > "$PROGRESS_FILE"

# Spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        completed=$(wc -l < "$PROGRESS_FILE")
        pct=$(( 100 * completed / TOTAL_PROJECTS ))
        for i in $(seq 0 3); do
            printf "\r[%c] Progress: %d/%d projects (%d%%)" "${spinstr:i:1}" "$completed" "$TOTAL_PROJECTS" "$pct"
            sleep $delay
        done
    done
}

process_project() {
    PROJECT="$1"
    OUTPUT_DIR="$2"
    SRC_DIR="$3"
    PROGRESS_FILE="$4"

    REL_PATH="${PROJECT#"$SRC_DIR"/}"
    log ""
    log "Processing project: $REL_PATH"

    MODELS=( "$PROJECT"/*.stl "$PROJECT"/*.3mf )
    GCODE=( "$PROJECT"/*.gcode "$PROJECT"/*.bgcode )
    MD=( "$PROJECT"/*.md )
    PDF=( "$PROJECT"/*.pdf )

    MODELS=( "${MODELS[@]}" )
    GCODE=( "${GCODE[@]}" )
    MD=( "${MD[@]}" )
    PDF=( "${PDF[@]}" )

    if [[ ${#MODELS[@]} -eq 0 && ${#GCODE[@]} -eq 0 && ${#MD[@]} -eq 0 && ${#PDF[@]} -eq 0 ]]; then
        log "Skipping project (no exportable files): $REL_PATH"
        echo 1 >> "$PROGRESS_FILE"
        return
    fi

    PROJECT_OUT="$OUTPUT_DIR/$REL_PATH"
    mkdir -p "$PROJECT_OUT"

    for f in "${MODELS[@]}"; do [[ -f "$f" ]] || continue; log "  Copying model: $(basename "$f")"; cp -n "$f" "$PROJECT_OUT/"; done
    if [[ ${#GCODE[@]} -gt 0 ]]; then
        GCODE_OUT="$PROJECT_OUT/gcode"
        mkdir -p "$GCODE_OUT"
        for f in "${GCODE[@]}"; do [[ -f "$f" ]] || continue; log "  Copying gcode/bgcode: $(basename "$f")"; cp -n "$f" "$GCODE_OUT/"; done
    fi

    for md in "${MD[@]}"; do
        [[ -f "$md" ]] || continue
        pdf_name="$(basename "${md%.*}").pdf"
        pdf_existing="$PROJECT/$pdf_name"
        pdf_out="$PROJECT_OUT/$pdf_name"
        if [[ -f "$pdf_existing" ]]; then
            log "  Copying existing PDF: $pdf_name"
            cp -n "$pdf_existing" "$pdf_out"
        else
            log "  Generating PDF: $(basename "$md") → $pdf_name"
            pandoc -s "$md" -o "$pdf_out"
        fi
    done

    for f in "${PDF[@]}"; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        base_noext="${base%.*}"
        skip=0
        for mdfile in "${MD[@]}"; do [[ "${mdfile##*/}" == "$base_noext.md" ]] && skip=1; done
        [[ $skip -eq 1 ]] && continue
        log "  Copying PDF: $base"
        cp -n "$f" "$PROJECT_OUT/"
    done

    echo 1 >> "$PROGRESS_FILE"
}

export -f log process_project
export TOTAL_PROJECTS

# Run projects in parallel and show spinner
(
    printf "%s\n" "${PROJECT_DIRS[@]}" | parallel -j "$THROTTLE" process_project {} "$OUTPUT_DIR" "$SRC_DIR" "$PROGRESS_FILE"
) &
PARALLEL_PID=$!
spinner $PARALLEL_PID
wait $PARALLEL_PID

echo -e "\n"

# Handle root README.md
ROOT_README="./README.md"
if [[ -f "$ROOT_README" ]]; then
    ROOT_PDF="$OUTPUT_DIR/README.pdf"
    ROOT_EXISTING_PDF="./README.pdf"
    if [[ -f "$ROOT_EXISTING_PDF" ]]; then
        log "Copying root README.pdf"
        cp -n "$ROOT_EXISTING_PDF" "$ROOT_PDF"
    else
        log "Generating root README.pdf"
        pandoc -s "$ROOT_README" -o "$ROOT_PDF"
    fi
else
    log "No root README.md found."
fi

log ""
log "✅ Extraction and PDF handling complete. Files placed in: $OUTPUT_DIR"
if [[ $NOLOG -eq 0 ]]; then
    log "Log saved at: $LOG_FILE"
fi

rm -f "$PROGRESS_FILE"
