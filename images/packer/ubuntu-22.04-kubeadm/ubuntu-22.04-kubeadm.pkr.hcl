packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

variable "image_name" {
  type        = string
  description = "Golden Image 이름이다. qcow2 파일명과 metadata 이름에 동일하게 사용한다."
  default     = "cka-ubuntu-22.04-kubeadm-1.30-v1"
}

variable "source_image_path" {
  type        = string
  description = "Runtime Node 또는 빌드 호스트에 미리 내려받은 Ubuntu 22.04 cloud image 경로이다."
  default     = "/var/lib/cka/images/source/ubuntu-22.04-server-cloudimg-amd64.img"
}

variable "source_image_checksum" {
  type        = string
  description = "Ubuntu 22.04 cloud image checksum이다. 실제 빌드 전 source image의 sha256 값으로 교체한다."
  default     = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

variable "output_root" {
  type        = string
  description = "빌드 산출물을 저장할 로컬 디렉토리이다. 산출 qcow2는 Git에 저장하지 않는다."
  default     = "/var/lib/cka/images/base"
}

variable "ssh_username" {
  type        = string
  description = "빌드 중 Packer communicator가 사용할 임시 사용자이다. 운영 세션 SSH key 정책과 별개이다."
  default     = "ubuntu"
}

variable "kubernetes_version" {
  type        = string
  description = "Golden Image에 설치할 Kubernetes 패키지 버전이다."
  default     = "1.30.8-1.1"
}

variable "kubernetes_minor" {
  type        = string
  description = "Kubernetes apt 저장소 minor 버전이다."
  default     = "v1.30"
}

variable "crictl_version" {
  type        = string
  description = "Golden Image에 설치할 crictl 버전이다."
  default     = "v1.30.1"
}

variable "yq_version" {
  type        = string
  description = "Golden Image에 설치할 yq 버전이다."
  default     = "v4.44.6"
}

locals {
  output_directory = "${var.output_root}/${var.image_name}"
}

source "qemu" "ubuntu_22_04_kubeadm" {
  accelerator      = "kvm"
  boot_wait        = "5s"
  cpus             = 2
  disk_compression = true
  disk_image       = true
  format           = "qcow2"
  headless         = true
  iso_checksum     = var.source_image_checksum
  iso_url          = var.source_image_path
  memory           = 4096
  output_directory = local.output_directory
  shutdown_command = "sudo shutdown -P now"
  ssh_timeout      = "20m"
  ssh_username     = var.ssh_username
  vm_name          = "${var.image_name}.qcow2"

  qemuargs = [
    ["-serial", "stdio"],
    ["-display", "none"]
  ]
}

build {
  name    = "ubuntu-22.04-kubeadm"
  sources = ["source.qemu.ubuntu_22_04_kubeadm"]

  provisioner "shell" {
    environment_vars = [
      "KUBERNETES_VERSION=${var.kubernetes_version}",
      "KUBERNETES_MINOR=${var.kubernetes_minor}",
      "CRICTL_VERSION=${var.crictl_version}",
      "YQ_VERSION=${var.yq_version}"
    ]
    scripts = [
      "images/packer/ubuntu-22.04-kubeadm/scripts/00-install-base-packages.sh",
      "images/packer/ubuntu-22.04-kubeadm/scripts/10-install-containerd.sh",
      "images/packer/ubuntu-22.04-kubeadm/scripts/20-install-kubernetes-tools.sh",
      "images/packer/ubuntu-22.04-kubeadm/scripts/30-install-exam-tools.sh",
      "images/packer/ubuntu-22.04-kubeadm/scripts/90-clean-golden-image.sh",
      "images/packer/ubuntu-22.04-kubeadm/scripts/99-validate-cloud-init.sh"
    ]
  }
}
