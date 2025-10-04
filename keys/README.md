# MOK Keys for Secure Boot

This directory contains the Machine Owner Key (MOK) used for signing kernel modules to work with Secure Boot.

## Files

- `LOCALMOK.priv` - Private key for signing kernel modules (DO NOT SHARE)
- `LOCALMOK.der` - Public certificate for enrollment in Secure Boot

## Purpose

These keys are used to:
1. Sign ZFS kernel modules (.ko files) during the container build process
2. Enroll the public certificate in the system's MOK database for Secure Boot verification

## Security Notes

- The private key (`LOCALMOK.priv`) is excluded from version control via .gitignore
- Only the public certificate (`LOCALMOK.der`) should be shared
- Keep the private key secure - it can be used to sign malicious kernel modules

## Enrollment

To use these keys with Secure Boot:

### Option 1: Use the enrollment script
```bash
sudo ./keys/enroll-mok.sh
```
Follow the prompts and reboot when instructed.

### Option 2: Manual enrollment
1. Boot the system and access the MOK manager during boot
2. Enroll `LOCALMOK.der` as a trusted key
3. The signed kernel modules will then load successfully with Secure Boot enabled

## Regeneration

### Option 1: Use the justfile command (recommended)
```bash
just regen-mok
```

### Option 2: Manual regeneration
If you need to regenerate these keys manually:
```bash
cd keys/mok
openssl req -new -x509 -newkey rsa:2048 \
  -keyout LOCALMOK.priv \
  -outform DER -out LOCALMOK.der \
  -nodes -days 36500 \
  -subj "/CN=LOCALMOK/"
chmod 600 LOCALMOK.priv
```

**Note:** Regenerating keys will require re-enrollment in Secure Boot and rebuilding container images.