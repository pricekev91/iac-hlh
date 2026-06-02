#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
echo "Run as root"
exit 1
fi

echo "==> Installing prerequisites"
apt-get update
apt-get install -y curl wget ca-certificates gnupg lsb-release

BASE="https://repo.radeon.com/amdgpu-install"

echo "==> Detecting latest AMD installer version"
LATEST_VER="$(
curl -fsSL "${BASE}/"
| grep -oE 'href="[0-9]+.[0-9]+(.[0-9]+)?/'
| sed -E 's/^href="([0-9]+.[0-9]+(.[0-9]+)?)/$/\1/'
| sort -V
| tail -n1
)"

if [ -z "${LATEST_VER}" ]; then
echo "Could not detect latest amdgpu-install version"
exit 1
fi

echo "Latest version: ${LATEST_VER}"

CODENAME="
(
.
/
𝑒
𝑡
𝑐
/
𝑜
𝑠
−
𝑟
𝑒
𝑙
𝑒
𝑎
𝑠
𝑒
;
𝑒
𝑐
ℎ
𝑜
"
(./etc/os−release;echo"{VERSION_CODENAME:-}")"

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
URL="
𝐵
𝐴
𝑆
𝐸
/
BASE/{LATEST_VER}/${p}/"
if HTML="
(
𝑐
𝑢
𝑟
𝑙
−
𝑓
𝑠
𝑆
𝐿
"
(curl−fsSL"{URL}" 2>/dev/null)"; then
DEB="
(
𝑒
𝑐
ℎ
𝑜
"
(echo"{HTML}" | grep -oE 'amdgpu-install_[^"]+_all.deb' | head -n1 || true)"
if [ -n "${DEB}" ]; then
FOUND_PATH="${p}"
FOUND_DEB="${DEB}"
break
fi
fi
done

if [ -z "
𝐹
𝑂
𝑈
𝑁
𝐷
𝑃
𝐴
𝑇
𝐻
"
]
∣
∣
[
−
𝑧
"
FOUND 
P
​
 ATH"]∣∣[−z"{FOUND_DEB}" ]; then
echo "No compatible amdgpu-install package found for this host"
exit 1
fi

echo "Using path: ${FOUND_PATH}"
echo "Package: ${FOUND_DEB}"

TMP_DEB="/tmp/${FOUND_DEB}"
DEB_URL="
𝐵
𝐴
𝑆
𝐸
/
BASE/{LATEST_VER}/
𝐹
𝑂
𝑈
𝑁
𝐷
𝑃
𝐴
𝑇
𝐻
/
FOUND 
P
​
 ATH/{FOUND_DEB}"

echo "==> Downloading ${DEB_URL}"
wget -O "
𝑇
𝑀
𝑃
𝐷
𝐸
𝐵
"
"
TMP 
D
​
 EB""{DEB_URL}"

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
echo " amdgpu-install --version || true"
echo " amd-smi version || amd-smi --help || true"
echo " rocminfo | head -n 40 || true"
echo
echo "Reboot is recommended now."
