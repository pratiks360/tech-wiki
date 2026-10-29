---
title: Arch Linux + Windows 11 Dual Boot with rEFInd
summary: Install Arch beside Windows on one UEFI SSD, reuse the Windows EFI partition, and use rEFInd to pick the OS (Windows default) — plus the BitLocker, Fast Startup and EFI-access gotchas.
emoji: 💽
---

# Arch Linux + Windows 11 Dual Boot with rEFInd

Putting Arch next to Windows on a single UEFI/GPT SSD is easy to get *almost* right: Arch installs fine but Windows keeps booting first, the Windows drive asks for a password in Linux, or the boot menu flickers. This covers the whole path and the traps that cost time.

**Setup this was written against:** Windows 11 Pro, UEFI + GPT, 240 GB SSD (C:, a spare 82 GB E:, a 200 MB EFI partition), 1 TB HDD (D:), 15 GB USB stick.

---

## 🛠️ 1. Windows prep

### Step 1: Confirm UEFI/GPT and find the partitions
```powershell
Get-Disk | ft Number,FriendlyName,BusType,Size,PartitionStyle
Get-Partition | ft DiskNumber,PartitionNumber,DriveLetter,Size,Type
```
*You want `PartitionStyle` GPT on the SSD and a 100–500 MB `System` (EFI) partition.*

### Step 2: Turn off Fast Startup
```powershell
powercfg /h off
```
*Fast Startup leaves NTFS hibernated; Linux then refuses or corrupts writes to it.*

### Step 3: Check BitLocker on every drive
```powershell
manage-bde -status
```
> **Crucial:** a padlock with a warning triangle (or "Protection Off") means **encrypted but suspended**, not decrypted. Windows reads it freely; Linux sees a BitLocker volume and asks for a password. Fully decrypt a data drive with `manage-bde -off D:` and wait for "Fully Decrypted". Win 11 can enable BitLocker silently when you sign in with a Microsoft account — recovery key is at `https://account.microsoft.com/devices/recoverykey`.

### Step 4: Secure Boot
Turn it off in firmware (the Arch ISO is not signed for it), or sign the bootloader.

---

## 💾 2. Make the Arch USB

### Step 1: Download and verify
Get the ISO and its `sha256sums.txt` from `https://geo.mirror.pkgbuild.com/iso/latest/`.
```powershell
(Get-FileHash .\archlinux-2026.10.01-x86_64.iso -Algorithm SHA256).Hash.ToLower()
```
*Compare with the line in `sha256sums.txt`.*

### Step 2: Write it raw to the USB (erases it)
Use Rufus in **DD image mode**, or a script that opens `\.\PhysicalDriveN` from an **elevated** PowerShell and writes in 4 MB, sector-aligned blocks. Check the disk number first — this wipes it.

> After writing, Windows shows the stick with no usable partitions and may offer to format it. Don't.

---

## 🐧 3. Install Arch

Boot the USB (firmware boot menu, UEFI entry), then follow the standard install guide:

- Delete the old E: partition and make a Linux root (ext4) from that space.
- **Reuse the existing 200 MB EFI partition. Do not format it** — that deletes Windows' bootloader.
- Mount it at `/boot/efi`.

---

## 🔁 4. rEFInd

### Step 1: Install from inside the system
```bash
sudo pacman -S refind
sudo refind-install
```
*If Arch won't boot yet, boot the USB, mount root at `/mnt`, EFI at `/mnt/boot/efi`, `arch-chroot /mnt`, then run the same two commands.*

### Step 2: Config (`EFI/refind/refind.conf` on the EFI partition)
```text
timeout 10
use_nvram false
showtools reboot, shutdown, firmware
scanfor manual
default_selection "Windows 11"

menuentry "Windows 11" {
    icon /EFI/refind/icons/os_win.png
    loader /EFI/Microsoft/Boot/bootmgfw.efi
    graphics on
}

menuentry "Arch Linux" {
    icon /EFI/refind/icons/os_arch.png
    loader /EFI/Linux/arch-linux.efi
    options "root=PARTUUID=<your-root-partuuid> rw"
}
```
*Left/right moves across the OS icons; down goes to the tools row (reboot/shutdown/firmware). `default_selection` matches the menuentry name.*

### Step 3: Stop the start-up flicker
Remove `resolution max`, `enable_mouse` and `enable_touch`. Forcing a screen-mode switch and redrawing for mouse/touch show up as flicker. If it persists, the theme's `banner_scale fillscreen` is stretching a large background; set `banner_scale noscale` after the theme `include`, or use a smaller theme.

---

## 🔍 5. Editing the EFI partition from Windows

```powershell
mountvol S: /S      # mount the EFI partition as S:
Get-Content S:\EFI\refind\refind.conf
mountvol S: /D      # unmount
```
> **Crucial:** this only works from a genuinely **elevated** shell. `bcdedit` giving "Access is denied" means you are not elevated. Back up `refind.conf` before editing.

---

## 🐛 Troubleshooting

**Symptom: reboot after install goes straight to Windows.**
Arch's bootloader isn't first in the boot order. Install rEFInd (above) or run `efibootmgr -v` and reorder.

**Symptom: Linux asks for a password opening D:/C:.**
Either the normal file-manager mount prompt (use your user password) or a BitLocker volume — see Windows prep, Step 3.

**Not verified in the original session:** the flicker fix and the Windows-default change were applied but the boot screen was not re-checked afterwards.
