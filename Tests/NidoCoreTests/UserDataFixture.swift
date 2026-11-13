// SPDX-License-Identifier: Apache-2.0
//
// Fixture: the exact user-data `CloudInitSeed.userData` produced before M3c for
// `username: "nido"` and `publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"`
// (captured from the code before the provisioning profile existed). A VM without a profile
// must keep producing these exact bytes.

import NidoCore

let userDataBeforeM3c = #"""
#cloud-config
disable_root: true
ssh_pwauth: false
users:
  - name: nido
    lock_passwd: true
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6"
write_files:
  - path: /etc/systemd/system/nido-shares.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Shared folders of the Mac (Nido)
      After=local-fs.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecCondition=/bin/sh -c "mkdir -p /mnt/nido && { mountpoint -q /mnt/nido || mount -t virtiofs -o nosuid,nodev nido /mnt/nido; }"
      ExecStart=/bin/true

      [Install]
      WantedBy=multi-user.target
  - path: /etc/nido/rosetta-binfmt.conf
    permissions: "0644"
    content: |
      :rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:F
  - path: /etc/systemd/system/nido-rosetta.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Rosetta for x86_64 binaries (Nido)
      After=local-fs.target systemd-binfmt.service
      PartOf=systemd-binfmt.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecCondition=/bin/sh -c "mkdir -p /media/rosetta && { mountpoint -q /media/rosetta || mount -t virtiofs -o ro,nosuid,nodev rosetta /media/rosetta; }"
      ExecStart=/usr/lib/systemd/systemd-binfmt /etc/nido/rosetta-binfmt.conf

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, nido-shares.service, nido-rosetta.service]

"""#

/// `userDataBeforeM3c` plus the one addition of M3b: missing SSH host keys regenerated at
/// every boot (`CloudInitSeed.regenerateHostKeysBootCommand`).
let userDataBeforeM3cWithHostKeys = userDataBeforeM3c + "bootcmd:\n  - " + CloudInitSeed.regenerateHostKeysBootCommand + "\n"
