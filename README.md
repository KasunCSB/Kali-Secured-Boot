# Kali Secured Boot - Run Kali Linux on Secure Boot Enabled Devices

## Table of Contents

- [The Problem](#the-problem)
- [Options](#options)
  - [Option 1: Add GRUB Bootloader Hash](#option-1-add-grub-bootloader-hash)
  - [Option 2: Sign Kali's Bootloader and Kernel](#option-2-sign-kalis-bootloader-and-kernel)
- [Requirements](#requirements)
- [Quick Script](#quick-script)
- [Manual Step-by-Step Process](#manual-step-by-step-process)
  1. [Install Dependencies](#1-install-dependencies)
  2. [Extract the ISO](#2-extract-the-iso)
  3. [Generate Secure Boot Keys](#3-generate-secure-boot-keys)
  4. [Mount the EFI Partition Image](#4-mount-the-efi-partition-image)
  5. [Inspect Signatures](#5-inspect-signatures)
  6. [Sign Boot Files and Kernel](#6-sign-boot-files-and-kernel)
  7. [Optional: Add Key for Enrollment](#7-optional-add-key-for-enrollment)
  8. [Verify New Signatures](#8-verify-new-signatures)
  9. [Repack the Modified ISO](#9-repack-the-modified-iso)
  10. [Flash the ISO to USB](#10-flash-the-iso-to-usb)
  11. [Create Shared Partition (Optional)](#11-create-shared-partition-optional)
- [Enroll Certificate on MOK Manager](#enroll-certificate-on-mok-manager)
- [Important Notes](#important-notes)

## The Problem
Kali Linux, the very popular penetration tetsing OS, itself doesn't support Secure Boot out-of-the-box because its bootloader and kernal is not signed with a trusted certificate. As a result, UEFI firmware refuses to load them when Secure Boot is on. It doesn't make sense if you've dedicated hardware to run only Kali, but in general, most folks doesn't have that facility. If you wish to dual-boot Kali with Windows or use Kali as a live USB booting, this problem comes in to play. Secure Boot, which is a core hardware security feature, prevents tampering or unauthorized code execution at boot. Thus, it's generally recommended to keep it enabled as an extra security layer. So how do we keep the both? In that case, you've several options.

## Options
### Option 1: Add GRUB Bootloader Hash
If you prefer option 1, head over to your BIOS, look for an option (in the Secure Boot section) which allows you to add the BL file hash to the DB. - You have to choose `grubx64.efi` file. Give it a name and save it. Upon next boot, again head to BIOS, Change boot order to make GRUB as the first option. From there, you can easily switch between OSes.

### Option 2: Sign Kali's Bootloader and Kernel
Sign Kali’s bootloader files and kernel with your own certificate, rebuild the ISO with the signed files, and enroll the certificate via MOK Manager.

## Requirements
- Kali live ISO (from the official [Kali website](https://www.kali.org/get-kali/#kali-live))
- A Linux system (e.g., Ubuntu, Kali, Debian)
- USB flash drive (8GB+)
- Internet connection
- Patience

## Quick Script
If you're lacking the final requirement, you can directly execute the shell script `geniso.sh` as follows, place the iso on the same path of the script, and run it, the script will do the rest.

Run below as ROOT.
```bash
apt update
apt install -y sbsigntool efitools isolinux shim-signed mokutil
chmod +x geniso.sh
./geniso.sh
```

Assuming everything executed without errors, you'll have a newly cooked Kali Signed ISO, which can be flashed as a live image or install it to dual-boot with another OS.

## Manual Step-by-Step Process

### 1. Install Dependencies
```bash
sudo apt update
sudo apt install -y sbsigntool efitools isolinux shim-signed mokutil
```

### 2. Extract the ISO
```bash
mkdir iso-extract
xorriso -osirrox on -indev kali-linux-2025.1a-live-amd64.iso -extract / iso-extract
```

### 3. Generate Secure Boot Keys
```bash
mkdir secureboot-keys
cd secureboot-keys
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.key -out MOK.crt -nodes -days 3650 -subj "/CN=Kali Secure Boot/"
openssl x509 -in MOK.crt -out MOK.cer -outform DER
cd ..
```

### 4. Mount the EFI Partition Image
```bash
mkdir efi-mount
mkdir efi-mount efi-mount2
sudo mount -o loop iso-extract/boot/grub/efi.img efi-mount
sudo mount -o loop iso-extract/efi.img efi-mount2
```

### 5. Inspect Signatures
Usually you need to sign all the unsigned boot files including 'grubx64.efi' and 'vmlinuz' (kernel).
These files are typically found on following directories. (This subjects to change with the .iso image version)

`/boot/grub/efi.img/`
`/EFI/boot/`
`/efi.img`
`/live/`

The UEFI .img files are mounted earlier, so look in the other directories for unsigned files. Check the signatures of each file by issuing:

```bash
sbverify --list <signed-efi-file>
```
Take a note on files missing a signature. Then sign them all using your own key. For example:

### 6. Sign Boot Files and Kernel
```bash
sudo sbsign --key secureboot-keys/MOK.key --cert secureboot-keys/MOK.crt   --output efi-mount/EFI/boot/grubx64.efi efi-mount/EFI/boot/grubx64.efi

sudo sbsign --key secureboot-keys/MOK.key --cert secureboot-keys/MOK.crt   --output iso-extract/live/vmlinuz iso-extract/live/vmlinuz<version>
```

### 7. Optional: Add Key for Enrollment
```bash
sudo cp secureboot-keys/MOK.cer efi-mount/EFI/boot/
```

### 8. Verify New Signatures
```bash
sudo sbverify --cert secureboot-keys/MOK.crt efi-mount/EFI/boot/grubx64.efi
# You should see: Signature verification OK
```

### 9. Repack the Modified ISO
Now you're ready to repack the modified ISO image. Here, we create a UEFI-bootable ISO image, omitting MBR option. As the original Kali ISO both carry UEFI and Legacy support, it creates additional EFI Partitions upon flashing, making conflicts with the later `Kali Shared` USB Partition creation.

```bash
cd iso-extract
xorriso -as mkisofs   -iso-level 3   -r -J -joliet-long   -V "KALI_CUSTOM"   -append_partition 2 0xef boot/grub/efi.img   -partition_cyl_align all   -isohybrid-gpt-basdat   -o ../kali-live-secureboot.iso   .
```

### 10. Flash the ISO to USB

Now you have modified Kali ISO in hand, so you're ready to write it to the USB drive. Format it (recommended) and issue the following command to commence the process:

```bash
sudo dd if=kali-live-secureboot.iso of=/dev/sdX conv=fsync bs=4M status=progress
```
`sd'X'` represents the drive assigned to the USB. To find it, issue 
```bash
sudo fdisk -l
```
before flashing.

After flashing, you'll see something like this:
```bash
893+1 records in
893+1 records out
3748147200 bytes (3.7 GB, 3.5 GiB) copied, 998.442 s, 3.8 MB/s
```
Now you have successfully created the Kali bootable USB. verify (in gparted in Kali, or Disks in Ubuntu) if the USB has two partitons with ISO9660 and FAT file systems. (reconnect USB to see it)

### 11. Create Shared Partition (Optional)
If you have remaining space left on USB, You can easily create a `Kali Shared` Space, to make it easier to transfer files between Windows (host OS) and live Kali. Simply format the rest as NTFS, and label it as `Kali Shared` (or whatever)

## Enroll Certificate on MOK Manager
```bash
sudo mokutil --import secureboot-keys/MOK.cer
# Enter a password for MOK enrollment
```
Reboot, enroll the key via MOK Manager, and you’re done.

## Important Notes
1. You may need to disable Secure Boot temporarily until the process completes.  
2. If BitLocker is enabled, disabling Secure Boot may trigger a recovery; re-enable it afterward.  
3. You might see more partitions rather than `Kali Shared` in USB on Windows systems. These partitions are almost unsupported by Windows and you can ignore them. If you really want to hide them from appearing in the Explorer, you can do a simple registry modification as follows:

    - Open Registry Editor (Win+R, regedit)
    - Navigate to:

    `Computer\HKEY_LOCAL_MACHINE\SYSTEM\MountedDevices`

    You'll see entries like `\DosDevices\D:`. Rename all unnecessary partitions by adding a `#` prefix. (exg: `#\DosDevices\D:`)
    You can also change the drive letter of it to `Z`. So the future drive letter assignments of other drives will be alphebetical.
   
    Alternatively, you can create a Offline Key on the same registry tree, and adding the same DWORD name, and modify value to `1` under `Offline`.

5. I've added my own signed BL files from the Kali Live image (v2025.1a) here. So you can also replace those files on the original ISO and repack skipping signing steps.
