#!/usr/bin/env bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root"
	exit 1
fi

echo "==> Installing prerequisites"
apt-get update
apt-get install -y curl wget ca-certificates gnupg lsb-release

echo "==> Configuring AMD apt keyring"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/amd.gpg.tmp
mv /etc/apt/keyrings/amd.gpg.tmp /etc/apt/keyrings/amd.gpg
chmod 0644 /etc/apt/keyrings/amd.gpg

BASE="https://repo.radeon.com/amdgpu-install"

echo "==> Detecting latest AMD installer version"
LATEST_VER="$({
	curl -fsSL "${BASE}/" \
		| sed -n 's/.*href="\([0-9][0-9.]*\)\/".*/\1/p' \
		| sort -V \
		| tail -n1
})"

if [ -z "${LATEST_VER}" ]; then
	echo "Could not detect latest amdgpu-install version"
	exit 1
fi

echo "Latest version: ${LATEST_VER}"

CODENAME="$({
	. /etc/os-release
	echo "${VERSION_CODENAME:-trixie}"
})"

CANDIDATES=(
	"debian/${CODENAME}"
	"debian/trixie"
	"debian/bookworm"
	"ubuntu/noble"
)

FOUND_PATH=""
FOUND_DEB=""

echo "==> Finding compatible installer package path"
for p in "${CANDIDATES[@]}"; do
	URL="${BASE}/${LATEST_VER}/${p}/"
	if HTML="$(curl -fsSL "${URL}" 2>/dev/null)"; then
		DEB="$(echo "${HTML}" | sed -n 's/.*href="\([^"]*amdgpu-install_[^"]*_all.deb\)".*/\1/p' | head -n1)"
		if [ -n "${DEB}" ]; then
			FOUND_PATH="${p}"
			FOUND_DEB="${DEB}"
			break
		fi
	fi
done

if [ -z "${FOUND_PATH}" ] || [ -z "${FOUND_DEB}" ]; then
	echo "No compatible amdgpu-install package found for this host"
	exit 1
fi

echo "Using path: ${FOUND_PATH}"
echo "Package: ${FOUND_DEB}"

TMP_DEB="/tmp/amdgpu-install_latest_all.deb"
DEB_URL="${BASE}/${LATEST_VER}/${FOUND_PATH}/${FOUND_DEB}"

echo "==> Downloading ${DEB_URL}"
wget -O "${TMP_DEB}" "${DEB_URL}"

echo "==> Installing amdgpu-install"
dpkg -i "${TMP_DEB}" || true
apt-get -f install -y

echo "==> Installing AMD GPU stack (graphics + rocm, no dkms)"
amdgpu-install -y --usecase=graphics,rocm --no-dkms

echo "==> Installing AMD SMI package(s) when available"
if apt-cache show amd-smi >/dev/null 2>&1; then
	apt-get install -y amd-smi
fi
if apt-cache show amd-smi-lib >/dev/null 2>&1; then
	apt-get install -y amd-smi-lib
fi

echo
echo "Install complete."
echo "Verification:"
echo "  amdgpu-install --version || true"
echo "  amd-smi version || amd-smi --help || true"
echo "  rocminfo | head -n 40 || true"
echo
echo "Reboot is recommended now."
echo
echo "Reboot is recommended now."
