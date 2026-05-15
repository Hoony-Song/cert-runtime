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
      - ${SSH_PUBLIC_KEY}${ADMIN_SSH_KEY_LINE}

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
  - path: /home/${VM_USERNAME}/.ssh/session_vm
    owner: ${VM_USERNAME}:${VM_USERNAME}
    permissions: "0600"
    encoding: b64
    content: ${SSH_PRIVATE_KEY_B64}
  - path: /home/${VM_USERNAME}/.ssh/config
    owner: ${VM_USERNAME}:${VM_USERNAME}
    permissions: "0600"
    content: |
      Host cka0001 cka0002 cka0003
        User ${VM_USERNAME}
        IdentityFile ~/.ssh/session_vm
        StrictHostKeyChecking accept-new
        UserKnownHostsFile ~/.ssh/known_hosts

runcmd:
  - [ chown, -R, ${VM_USERNAME}:${VM_USERNAME}, /home/${VM_USERNAME}/.ssh ]
  - [ chmod, "0700", /home/${VM_USERNAME}/.ssh ]
  - [ cloud-init-per, once, cka-disable-password-auth, sed, -i, "s/^#PasswordAuthentication yes/PasswordAuthentication no/", /etc/ssh/sshd_config ]
  - [ systemctl, reload, ssh ]
