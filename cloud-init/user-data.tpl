#cloud-config
hostname: ${VM_HOSTNAME}
manage_etc_hosts: true

users:
  - default
  - name: ${VM_USERNAME}
    groups:
      - adm
      - sudo
    shell: /bin/bash
    sudo:
      - ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

ssh_pwauth: false
disable_root: true

write_files:
  - path: /etc/cka-session
    owner: root:root
    permissions: "0644"
    content: |
      session_id=${SESSION_ID}
      vm_role=${VM_ROLE}
      exam_type=${EXAM_TYPE}

runcmd:
  - [ cloud-init-per, once, cka-disable-password-auth, sed, -i, "s/^#PasswordAuthentication yes/PasswordAuthentication no/", /etc/ssh/sshd_config ]
  - [ systemctl, reload, ssh ]
