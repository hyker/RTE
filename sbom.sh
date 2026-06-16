#!/usr/bin/env bash
#
# sbom.sh - Generate CycloneDX SBOMs for the RTE project.
#
# Produces three CycloneDX JSON documents:
#   sbom-rte.cdx.json    - the RTE service itself: custodes Go modules, the
#                          tdx submodule, and the Ubuntu OS packages inside
#                          server/base-image.raw (exact installed versions,
#                          read via debugfs; no mount, no sudo)
#   sbom-tools.cdx.json  - the bundled analysis tools and their dependencies:
#                          checksec (Go), aeskeyfind, dependency-check (Java),
#                          and the tool packages installed in the image
#                          (cppcheck, binwalk, the JRE for dependency-check)
#   sbom-client.cdx.json - the client side: npm packages bundled into
#                          bundle.js (from package-lock.json) AND the OS
#                          packages inside the client hosting VM
#                          (client/vm/vm-disk-prod.qcow2: nginx, certbot, ...)
#
# Usage: ./sbom.sh [--spec 1.5|1.6] [--outdir DIR]
#   defaults: --spec 1.6 --outdir <repo root>
#
# Requires: syft, cyclonedx (cyclonedx-cli), jq, git, parted, debugfs
#           qemu-img (only when scanning the qcow2 client VM disk)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="1.6"
OUTDIR="$ROOT"
IMAGE="$ROOT/server/base-image.raw"
CLIENT_IMAGE="$ROOT/client/vm/vm-disk-prod.qcow2"

# deb packages that belong to the analysis tools, not the RTE platform:
# cppcheck + binwalk (add-payload.sh) and the JRE stack pulled in solely to
# run dependency-check (default-jre-headless and its companions)
# These need to be maintained when adding or removing tools from the RTE
TOOL_DEB_PKGS='["cppcheck","binwalk","python3-binwalk","default-jre-headless","openjdk-21-jre-headless","java-common","ca-certificates-java"]'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --spec)   SPEC="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

case "$SPEC" in
    1.5) CDX_VERSION="v1_5" ;;
    1.6) CDX_VERSION="v1_6" ;;
    *) echo "Unsupported spec version: $SPEC (use 1.5 or 1.6)" >&2; exit 1 ;;
esac

DEBUGFS="$(command -v debugfs || echo /usr/sbin/debugfs)"
for tool in syft cyclonedx jq git parted; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool (see header of this script)" >&2; exit 1; }
done
[[ -x "$DEBUGFS" ]] || { echo "Missing required tool: debugfs (e2fsprogs)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION="$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo unknown)"

# file metadata off: keep the SBOMs about packages, not evidence-file entries
export SYFT_FILE_METADATA_SELECTION=none

# --- 1. Source scans ----------------------------------------------------------
echo "[1/4] Scanning source dependencies..."
syft scan "dir:$ROOT/server" \
    --source-name RTE --source-version "$VERSION" \
    --exclude './payload/custodes/tools/**' --exclude '**/.github/**' \
    --exclude '**/*.raw' --exclude '**/*.img' --exclude '**/*.qcow2' --exclude '**/*.iso' \
    -o "cyclonedx-json@$SPEC=$TMP/rte-src.cdx.json" -q
syft scan "dir:$ROOT/server/payload/custodes/tools" \
    --source-name RTE-analysis-tools --source-version "$VERSION" \
    --exclude '**/.github/**' \
    -o "cyclonedx-json@$SPEC=$TMP/tools-src.cdx.json" -q
syft scan "dir:$ROOT/client" \
    --source-name RTE-client --source-version "$VERSION" \
    --exclude './node_modules/**' --exclude '**/*.qcow2' --exclude '**/*.iso' --exclude '**/*.img' \
    -o "cyclonedx-json@$SPEC=$TMP/client-src.cdx.json" -q

# --- 2. OS packages: dpkg databases read out of the built VM images ------------
RTE_BOMS=("$TMP/rte-src.cdx.json")
TOOLS_BOMS=("$TMP/tools-src.cdx.json")
CLIENT_BOMS=("$TMP/client-src.cdx.json")

# extract_os_bom <image> <source-name> <output-bom>
# Reads the dpkg database from a disk image (raw, or qcow2 which is converted
# first; -U lets it read even while a VM holds a write lock) and writes a
# CycloneDX BOM of the installed OS packages. Returns nonzero if no rootfs is
# found or a needed tool is missing.
extract_os_bom() {
    local image="$1" srcname="$2" outbom="$3"
    local raw="$image" stage
    stage="$(mktemp -d "$TMP/rootfs.XXXXXX")"
    mkdir -p "$stage/var/lib/dpkg" "$stage/etc" "$stage/usr/lib"

    # qcow2 (anything but *.raw) must be flattened to raw before debugfs can read it
    if [[ "$image" != *.raw ]]; then
        command -v qemu-img >/dev/null || { echo "WARNING: qemu-img missing; cannot read $image" >&2; return 1; }
        raw="$TMP/$(basename "$image").raw"
        qemu-img convert -U -O raw "$image" "$raw" 2>/dev/null || { echo "WARNING: qemu-img convert failed for $image" >&2; return 1; }
    fi

    # Find the root ext4 partition: try each one until /var/lib/dpkg/status appears
    local found="" offset
    while IFS=: read -r _num start _end _size fstype _rest; do
        [[ "$fstype" == ext4 ]] || continue
        offset="${start%B}"
        if "$DEBUGFS" -R 'cat /var/lib/dpkg/status' "$raw?offset=$offset" \
                2>/dev/null > "$stage/var/lib/dpkg/status" \
                && grep -q '^Package:' "$stage/var/lib/dpkg/status"; then
            found="$offset"
            break
        fi
    done < <(parted -ms "$raw" unit B print 2>/dev/null | tail -n +3)

    if [[ -z "$found" ]]; then
        echo "WARNING: could not locate dpkg database in $image; its OS packages NOT included" >&2
        [[ "$raw" != "$image" ]] && rm -f "$raw"
        return 1
    fi
    # os-release lets syft qualify deb PURLs with the distro
    "$DEBUGFS" -R 'cat /usr/lib/os-release' "$raw?offset=$found" \
        2>/dev/null > "$stage/usr/lib/os-release" || true
    cp "$stage/usr/lib/os-release" "$stage/etc/os-release" 2>/dev/null || true
    syft scan "dir:$stage" --source-name "$srcname" --source-version "$VERSION" \
        -o "cyclonedx-json@$SPEC=$outbom" -q
    [[ "$raw" != "$image" ]] && rm -f "$raw"   # free the multi-GB converted image promptly
    return 0
}

echo "[2/4] Scanning OS packages in VM images..."
# Server image: split into tool packages (-> tools SBOM) and platform (-> RTE SBOM).
if [[ -r "$IMAGE" ]] && extract_os_bom "$IMAGE" RTE-base-image "$TMP/os.cdx.json"; then
    # split_os <output> <jq-selector applied to each component>
    split_os() {
        jq --argjson tools "$TOOL_DEB_PKGS" "
            (.components | map(select($2))) as \$keep
            | ((\$keep | map(.\"bom-ref\")) + [.metadata.component.\"bom-ref\"]) as \$refs
            | .components = \$keep
            | .dependencies = ((.dependencies // [])
                | map(select(.ref as \$r | \$refs | index(\$r)))
                | map(.dependsOn = ((.dependsOn // []) | map(select(. as \$d | \$refs | index(\$d))))))
        " "$TMP/os.cdx.json" > "$1"
    }
    split_os "$TMP/os-tools.cdx.json" '.type == "library" and (.name as $n | $tools | index($n))'
    split_os "$TMP/os-rte.cdx.json"   '(.name as $n | $tools | index($n)) | not'
    RTE_BOMS+=("$TMP/os-rte.cdx.json")
    TOOLS_BOMS+=("$TMP/os-tools.cdx.json")
elif [[ ! -r "$IMAGE" ]]; then
    echo "WARNING: $IMAGE not found; server OS packages NOT included (build the image first)" >&2
fi

# Client hosting VM: all its OS packages go to the client SBOM.
if [[ -r "$CLIENT_IMAGE" ]] && extract_os_bom "$CLIENT_IMAGE" RTE-client-vm "$TMP/client-os.cdx.json"; then
    CLIENT_BOMS+=("$TMP/client-os.cdx.json")
elif [[ ! -r "$CLIENT_IMAGE" ]]; then
    echo "WARNING: $CLIENT_IMAGE not found; client VM OS packages NOT included (build the client VM first)" >&2
fi

# --- 3. Merge per target, pin spec version, add submodule components -----------
echo "[3/4] Merging and adding submodule components..."

# submodule_json <path...>: emit a JSON array of components for git submodules
submodule_json() {
    for path in "$@"; do
        commit="$(git -C "$ROOT" submodule status "$path" | awk '{gsub(/^[+-]/, "", $1); print $1}')"
        url="$(git -C "$ROOT" config --file "$ROOT/.gitmodules" "submodule.$path.url")"
        jq -n --arg name "$(basename "$path")" --arg commit "$commit" --arg url "$url" '{
            type: "application",
            "bom-ref": ("submodule:" + $name + "@" + $commit),
            name: $name,
            version: $commit,
            purl: ("pkg:github/" + ($url | sub("^https://github.com/"; "") | sub("\\.git$"; "")) + "@" + $commit),
            externalReferences: [{type: "vcs", url: $url}]
        }'
    done | jq -s .
}

# assemble <output-basename> <metadata-name> <extra-components-json> <bom-file...>
assemble() {
    local out="$1" name="$2" extra="$3"; shift 3
    cyclonedx merge --input-files "$@" \
        --name "$name" --version "$VERSION" \
        --output-file "$TMP/$out.merged.json" >/dev/null
    cyclonedx convert --input-file "$TMP/$out.merged.json" \
        --output-file "$TMP/$out.converted.json" \
        --output-format json --output-version "$CDX_VERSION" >/dev/null
    jq --argjson extra "$extra" '.components = ((.components // []) + $extra)' \
        "$TMP/$out.converted.json" > "$TMP/$out.final.json"
    cyclonedx validate --input-file "$TMP/$out.final.json" \
        --input-format json --input-version "$CDX_VERSION" --fail-on-errors >/dev/null
    cp "$TMP/$out.final.json" "$OUTDIR/$out.cdx.json"
}

assemble sbom-rte RTE \
    "$(submodule_json server/tdx)" "${RTE_BOMS[@]}"
assemble sbom-tools RTE-analysis-tools \
    "$(submodule_json server/payload/custodes/tools/checksec server/payload/custodes/tools/aeskeyfind)" \
    "${TOOLS_BOMS[@]}"
assemble sbom-client RTE-client "[]" "${CLIENT_BOMS[@]}"

# --- 4. Summary (all three validated against the CycloneDX schema above) -------
echo "[4/4] All SBOMs validated against CycloneDX $SPEC schema."
echo
for out in sbom-rte sbom-tools sbom-client; do
    f="$OUTDIR/$out.cdx.json"
    printf '%s  (%s components)\n' "$f" "$(jq '.components | length' "$f")"
    jq -r '.components | group_by(.purl // "" | split("/")[0]) |
           map("  \(length)\t\(.[0].purl // "(no purl)" | split("/")[0])")[]' "$f"
done
