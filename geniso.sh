#!/bin/bash

set -e

# === CONFIGURATION ===
ISO_URL="https://cdimage.kali.org/kali-2025.2/kali-linux-2025.2-live-amd64.iso"
ISO_SHA256="68f1117052bb0a6aa0fc0dee3b6525de1f5bccbd74c275fb050fe357a3f318a7"
ISO_FILE="kali-linux-2025.2-live-amd64.iso"
EXTRACT_DIR="iso-extract"
KEY_DIR="secureboot-keys"
EFI_MOUNT="efi-mount"
EFI_MOUNT2="efi-mount2"
SIGNED_ISO="kali-live-secureboot.iso"

# === DEPENDENCY CHECK ===
REQUIRED_CMDS=(wget sha256sum xorriso openssl sbsign sbverify mokutil sudo mount)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo "Please install it and rerun the script."
        exit 1
    fi
done

# === 1. CHECK/DOWNLOAD ISO ===
if [ ! -f "$ISO_FILE" ]; then
    echo "ISO file not found. Downloading..."
    wget -O "$ISO_FILE" "$ISO_URL" || { echo "Download failed!"; exit 1; }
fi

echo "Verifying ISO hash..."
HASH=$(sha256sum "$ISO_FILE" | awk '{print $1}')
if [ "$HASH" != "$ISO_SHA256" ]; then
    echo "Hash mismatch! Expected: $ISO_SHA256, Got: $HASH"
    exit 1
fi
echo "ISO hash verified."

# === 2. EXTRACT ISO ===
if [ -d "$EXTRACT_DIR" ]; then
    read -p "'$EXTRACT_DIR' exists. Remove and re-extract? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && rm -rf "$EXTRACT_DIR" || { echo "Aborted."; exit 1; }
fi
mkdir "$EXTRACT_DIR"
xorriso -osirrox on -indev "$ISO_FILE" -extract / "$EXTRACT_DIR" || { echo "ISO extraction failed!"; exit 1; }

# === 3. GENERATE KEYS ===
if [ ! -d "$KEY_DIR" ]; then
    mkdir "$KEY_DIR"
fi
if [ ! -f "$KEY_DIR/MOK.key" ] || [ ! -f "$KEY_DIR/MOK.crt" ]; then
    echo "Generating Secure Boot keys..."
    openssl req -new -x509 -newkey rsa:2048 -keyout "$KEY_DIR/MOK.key" -out "$KEY_DIR/MOK.crt" -nodes -days 3650 -subj "/CN=Kali Secure Boot/"
    openssl x509 -in "$KEY_DIR/MOK.crt" -out "$KEY_DIR/MOK.cer" -outform DER
else
    echo "Keys already exist, skipping key generation."
fi

# === 4. MOUNT EFI PARTITIONS ===
if [ -d "$EFI_MOUNT" ]; then sudo umount "$EFI_MOUNT" || true; rm -rf "$EFI_MOUNT"; fi
if [ -d "$EFI_MOUNT2" ]; then sudo umount "$EFI_MOUNT2" || true; rm -rf "$EFI_MOUNT2"; fi
mkdir "$EFI_MOUNT" "$EFI_MOUNT2"
sudo mount -o loop "$EXTRACT_DIR/boot/grub/efi.img" "$EFI_MOUNT"
sudo mount -o loop "$EXTRACT_DIR/efi.img" "$EFI_MOUNT2"

# === 5. SIGN UNSIGNED FILES ===
echo "Signing EFI binaries and kernel..."

# Sign grubx64.efi
if [ -f "$EFI_MOUNT/EFI/boot/grubx64.efi" ]; then
    sudo sbsign --key "$KEY_DIR/MOK.key" --cert "$KEY_DIR/MOK.crt" \
        --output "$EFI_MOUNT/EFI/boot/grubx64.efi" "$EFI_MOUNT/EFI/boot/grubx64.efi"
else
    echo "Warning: grubx64.efi not found in $EFI_MOUNT/EFI/boot/"
fi

# Sign kernel
if [ -f "$EXTRACT_DIR/live/vmlinuz" ]; then
    sudo sbsign --key "$KEY_DIR/MOK.key" --cert "$KEY_DIR/MOK.crt" \
        --output "$EXTRACT_DIR/live/vmlinuz" "$EXTRACT_DIR/live/vmlinuz"
else
    echo "Warning: vmlinuz not found in $EXTRACT_DIR/live/"
fi

# (Optional) Copy MOK.cer for enrollment
sudo cp "$KEY_DIR/MOK.cer" "$EFI_MOUNT/EFI/boot/"

# === 6. VERIFY SIGNATURES ===
echo "Verifying signatures..."
sudo sbverify --cert "$KEY_DIR/MOK.crt" "$EFI_MOUNT/EFI/boot/grubx64.efi" || { echo "grubx64.efi signature verification failed!"; exit 1; }
sudo sbverify --cert "$KEY_DIR/MOK.crt" "$EXTRACT_DIR/live/vmlinuz" || { echo "vmlinuz signature verification failed!"; exit 1; }

# === 7. UNMOUNT EFI PARTITIONS ===
sudo umount "$EFI_MOUNT"
sudo umount "$EFI_MOUNT2"
rm -rf "$EFI_MOUNT" "$EFI_MOUNT2"

# === 8. REPACK ISO ===
echo "Repacking ISO..."
cd "$EXTRACT_DIR"
xorriso -as mkisofs \
  -iso-level 3 \
  -r -J -joliet-long \
  -V "KALI_CUSTOM" \
  -append_partition 2 0xef boot/grub/efi.img \
  -partition_cyl_align all \
  -isohybrid-gpt-basdat \
  -o "../$SIGNED_ISO" \
  .
cd ..

echo "Signed ISO created: $SIGNED_ISO"

# === 9. ENROLL MOK CERTIFICATE ===
echo "To enroll the Secure Boot certificate, run:"
echo "  sudo mokutil --import $KEY_DIR/MOK.cer"
echo "You will be prompted for a password. After reboot, enroll the key in the MOK Manager."
read -p "Reboot now to enroll the key? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    sudo reboot
else
    echo "Please reboot manually to complete MOK enrollment."
fi