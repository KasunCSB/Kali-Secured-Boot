#!/bin/bash

set -e

# --- Ensure script is run as root ---
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo or as root user."
    exit 1
fi

# --- Configuration variables ---
EXTRACT_DIR="iso-extract"
KEY_DIR="secureboot-keys"
EFI_MOUNT="efi-mount"
EFI_MOUNT2="efi-mount2"
SIGNED_ISO="kali-live-secureboot.iso"

# --- Check for required commands ---
REQUIRED_CMDS=(wget sha256sum xorriso openssl sbsign sbverify mokutil mount)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo "Please install it and rerun the script."
        exit 1
    fi
done

# --- ISO file selection and verification ---
shopt -s nullglob
iso_files=(*.iso)
shopt -u nullglob

if [ ${#iso_files[@]} -eq 0 ]; then
    echo "No ISO file found in the current directory."
    read -p "Enter ISO download URL: " ISO_URL
    read -p "Enter expected SHA256 hash: " ISO_SHA256
    read -p "Enter filename to save as (e.g. kali.iso): " ISO_FILE
    wget -O "$ISO_FILE" "$ISO_URL" || { echo "Download failed!"; exit 1; }
    HASH=$(sha256sum "$ISO_FILE" | awk '{print $1}')
    if [ "$HASH" != "$ISO_SHA256" ]; then
        echo "Hash mismatch! Expected: $ISO_SHA256, Got: $HASH"
        exit 1
    fi
    echo "ISO hash verified."
elif [ ${#iso_files[@]} -eq 1 ]; then
    ISO_FILE="${iso_files[0]}"
    echo "Found ISO: $ISO_FILE"
    read -p "Enter expected SHA256 hash for $ISO_FILE: " ISO_SHA256
    HASH=$(sha256sum "$ISO_FILE" | awk '{print $1}')
    if [ "$HASH" != "$ISO_SHA256" ]; then
        echo "Hash mismatch! Expected: $ISO_SHA256, Got: $HASH"
        exit 1
    fi
    echo "ISO hash verified."
else
    echo "Multiple ISO files found:"
    select ISO_FILE in "${iso_files[@]}"; do
        [ -n "$ISO_FILE" ] && break
    done
    read -p "Enter expected SHA256 hash for $ISO_FILE: " ISO_SHA256
    HASH=$(sha256sum "$ISO_FILE" | awk '{print $1}')
    if [ "$HASH" != "$ISO_SHA256" ]; then
        echo "Hash mismatch! Expected: $ISO_SHA256, Got: $HASH"
        exit 1
    fi
    echo "ISO hash verified."
fi

# --- Extract ISO contents ---
if [ -d "$EXTRACT_DIR" ]; then
    read -p "'$EXTRACT_DIR' exists. Remove and re-extract? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && rm -rf "$EXTRACT_DIR" || { echo "Aborted."; exit 1; }
fi
mkdir "$EXTRACT_DIR"
xorriso -osirrox on -indev "$ISO_FILE" -extract / "$EXTRACT_DIR" || { echo "ISO extraction failed!"; exit 1; }

# --- Generate Secure Boot keys if missing ---
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

# --- Mount EFI partitions from ISO ---
if [ -d "$EFI_MOUNT" ]; then umount "$EFI_MOUNT" || true; rm -rf "$EFI_MOUNT"; fi
if [ -d "$EFI_MOUNT2" ]; then umount "$EFI_MOUNT2" || true; rm -rf "$EFI_MOUNT2"; fi
mkdir "$EFI_MOUNT" "$EFI_MOUNT2"
mount -o loop "$EXTRACT_DIR/boot/grub/efi.img" "$EFI_MOUNT"
mount -o loop "$EXTRACT_DIR/efi.img" "$EFI_MOUNT2"

# --- Sign EFI binaries and kernel images ---
echo "Signing EFI binaries and kernel..."

# Sign grubx64.efi
if [ -f "$EFI_MOUNT/EFI/boot/grubx64.efi" ]; then
    sbsign --key "$KEY_DIR/MOK.key" --cert "$KEY_DIR/MOK.crt" \
        --output "$EFI_MOUNT/EFI/boot/grubx64.efi" "$EFI_MOUNT/EFI/boot/grubx64.efi"
else
    echo "Warning: grubx64.efi not found in $EFI_MOUNT/EFI/boot/"
fi

# Sign all kernel images except the file named exactly 'vmlinuz'
kernel_signed=false
for kernel in "$EXTRACT_DIR"/live/vmlinuz*; do
    [ -e "$kernel" ] || continue
    if [ "$(basename "$kernel")" != "vmlinuz" ]; then
        echo "Signing kernel: $(basename "$kernel")"
        sbsign --key "$KEY_DIR/MOK.key" --cert "$KEY_DIR/MOK.crt" \
            --output "$kernel" "$kernel"
        kernel_signed=true
    fi
done

if [ "$kernel_signed" = false ]; then
    echo "Warning: No kernel images were signed. Please check your ISO contents."
fi

# Copy MOK certificate for later enrollment
cp "$KEY_DIR/MOK.cer" "$EFI_MOUNT/EFI/boot/"

# --- Verify signatures of signed binaries ---
echo "Verifying signatures..."
sbverify --cert "$KEY_DIR/MOK.crt" "$EFI_MOUNT/EFI/boot/grubx64.efi" || { echo "grubx64.efi signature verification failed!"; exit 1; }

for kernel in "$EXTRACT_DIR"/live/vmlinuz*; do
    [ -e "$kernel" ] || continue
    if [ "$(basename "$kernel")" != "vmlinuz" ]; then
        echo "Verifying kernel: $(basename "$kernel")"
        sbverify --cert "$KEY_DIR/MOK.crt" "$kernel" || { echo "$(basename "$kernel") signature verification failed!"; exit 1; }
    fi
done

# --- Unmount EFI partitions and clean up ---
umount "$EFI_MOUNT"
umount "$EFI_MOUNT2"
rm -rf "$EFI_MOUNT" "$EFI_MOUNT2"

# --- Repack the ISO with signed binaries ---
echo "Repacking ISO..."
cd "$EXTRACT_DIR"
xorriso -as mkisofs \
  -iso-level 3 \
  -r -J -joliet-long \
  -V "Kali Signed" \
  -append_partition 2 0xef boot/grub/efi.img \
  -partition_cyl_align all \
  -isohybrid-gpt-basdat \
  -o "../$SIGNED_ISO" \
  .
cd ..

echo "Signed ISO created: $SIGNED_ISO"

# --- Instructions for enrolling the Secure Boot certificate ---
echo "To enroll the Secure Boot certificate, run:"
echo "  mokutil --import $KEY_DIR/MOK.cer"
echo "You will be prompted for a password. After reboot, enroll the key in the MOK Manager."
read -p "Reboot now to enroll the key? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    reboot
else
    echo "Please reboot manually to complete MOK enrollment."
fi