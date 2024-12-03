# Packer Configuration for Building a QEMU-Based centos Image for OpenShift IPI

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ===========================
# Variables
# ===========================

variable "arch" {
  type        = string
  default     = "x86_64"
  description = "Architecture of the machine where the image will run"
}

variable "centos_version" {
  type        = string
  default     = "9"
  description = "RedHat CoreOS version to install"
}

variable "source_image_url" {
  type        = string
  default     = "https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
  description = "CentOS Stream QEMU image URL"
}

variable "source_image_checksum" {
  type        = string
  default     = "sha256:PUT_THE_ACTUAL_CHECKSUM_HERE"
  description = "Checksum of the CentOS image"
}

variable "output_directory" {
  type        = string
  default     = ".artifacts/centos-openshift"
  description = "Directory to store the built image artifacts"
}

variable "cluster_name" {
  type        = string
  default     = "ocp-libvirt"
  description = "Name of OpenShift cluster"
}

# ===========================
# Locals
# ===========================

locals {
  qemu_binary  = "${var.arch == "aarch64" ? "qemu-system-aarch64" : "qemu-system-x86_64"}"
  accelerator  = "kvm"  # Use "hvf" for macOS hosts if applicable
  cpu_model    = "${var.arch == "aarch64" ? "cortex-a57" : "host"}"
  machine_type = "${var.arch == "aarch64" ? "virt" : "pc"}"
  efi_boot     = "${var.arch == "aarch64" ? true : false}"
  efi_firmware_code = "${var.arch == "aarch64" ? "/usr/share/edk2/aarch64/QEMU_EFI.fd" : "/usr/share/edk2/x86_64/QEMU_EFI.fd"}"
  efi_firmware_vars = "${var.arch == "aarch64" ? "/usr/share/edk2/aarch64/QEMU_VARS.fd" : "/usr/share/edk2/x86_64/QEMU_VARS.fd"}"

  source_image_url      = "${var.source_image_url}"
  source_image_checksum = "${var.source_image_checksum}"
}

# ===========================
# Source Configuration
# ===========================

source "qemu" "centos-openshift" {
  iso_url      = "${local.source_image_url}"
  iso_checksum = "${local.source_image_checksum}"

  headless = true

  disk_compression = true
  disk_interface   = "virtio"
  disk_image       = true

  format       = "qcow2"
  vm_name      = "centos-${var.centos_version}.qcow2"
  boot_command = [] # centos uses Ignition; no need for boot commands
  net_device   = "virtio-net"

  output_directory = "${var.output_directory}"

  cpus   = 4
  memory = 8192

  qemu_binary       = "${local.qemu_binary}"
  accelerator       = "${local.accelerator}"
  cpu_model         = "${local.cpu_model}"
  machine_type      = "${local.machine_type}"
  efi_boot          = "${local.efi_boot}"
  efi_firmware_code = "${local.efi_firmware_code}"
  efi_firmware_vars = "${local.efi_firmware_vars}"

  qemuargs = [
    ["-drive", "if=virtio,file=${local.source_image_url},format=qcow2"],
    ["-netdev", "user,id=net0,hostfwd=tcp::2222-:22"],
    ["-device", "virtio-net,netdev=net0"],
    ["-machine", "q35,accel=kvm"],
  ]

  communicator     = "ssh"
  ssh_username     = "core"
  ssh_password     = "eroc"
  ssh_timeout      = "30m"
  shutdown_command = "sudo poweroff"
}

# ===========================
# Build Configuration
# ===========================

build {
  sources = ["source.qemu.centos-openshift"]

  provisioner "shell" {
    execute_command = "sudo {{ .Vars }} {{ .Path }}"

    scripts = [
      "${path.root}/scripts/haproxy.sh",
    ]

    environment_vars = [
      "CLUSTER_NAME=${var.cluster_name}",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "dnf install -y haproxy bind-utils",
      "cp /tmp/bootstrap.ign /opt/",
      "cp /tmp/master.ign /opt/",
      "cp /tmp/worker.ign /opt/",
      "cp /tmp/haproxy.cfg /etc/haproxy/",
      "systemctl enable --now haproxy"
    ]
  }

}
