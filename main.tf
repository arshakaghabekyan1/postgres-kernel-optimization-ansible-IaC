# Configure the Google Cloud provider
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
  backend "gcs" {
    bucket = "PUT_YOUR_BUCKET_HERE"
    prefix = "terraform/postgresql"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Create VPC
resource "google_compute_network" "vpc" {
  name                    = "postgresql-vpc"
  auto_create_subnetworks = false
}

# Create Subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "postgresql-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Firewall rules for PostgreSQL and SSH
resource "google_compute_firewall" "postgresql" {
  name    = "postgresql-firewall"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "5432"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["postgresql"]
}

# Master instance
resource "google_compute_instance" "master" {
  name         = "postgresql-master"
  machine_type = var.machine_type
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      // Include this block to give the VM an external IP address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key)}"
  }

  tags = ["postgresql", "master"]

  metadata_startup_script = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3 python3-pip
              EOF

  service_account {
    scopes = ["cloud-platform"]
  }
}

# Slave instance
resource "google_compute_instance" "slave" {
  name         = "postgresql-slave"
  machine_type = var.machine_type
  zone         = "${var.region}-b"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      // Include this block to give the VM an external IP address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key)}"
  }

  tags = ["postgresql", "slave"]

  metadata_startup_script = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3 python3-pip
              EOF

  service_account {
    scopes = ["cloud-platform"]
  }
}

# Create Ansible inventory file
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tmpl",
    {
      master_ip = google_compute_instance.master.network_interface[0].access_config[0].nat_ip
      slave_ip  = google_compute_instance.slave.network_interface[0].access_config[0].nat_ip
      ssh_user  = var.ssh_user
    }
  )
  filename = "inventory.ini"
}

# Run Ansible playbook
resource "null_resource" "ansible_provisioner" {
  depends_on = [
    google_compute_instance.master,
    google_compute_instance.slave,
    local_file.ansible_inventory
  ]

  provisioner "local-exec" {
    command = <<-EOT
      sleep 30  # Wait for instances to be fully ready
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        -i inventory.ini \
        --private-key ${var.ssh_private_key} \
        postgresql_playbook.yml
    EOT
  }

  triggers = {
    instance_ids = "${google_compute_instance.master.id},${google_compute_instance.slave.id}"
  }
}

# Output the instance IPs
output "master_public_ip" {
  value = google_compute_instance.master.network_interface[0].access_config[0].nat_ip
}

output "slave_public_ip" {
  value = google_compute_instance.slave.network_interface[0].access_config[0].nat_ip
}

# Variables
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "machine_type" {
  description = "VM Machine Type"
  type        = string
  default     = "n2-standard-2"  # 2 vCPU, 8GB RAM
}

variable "ssh_user" {
  description = "SSH Username"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Path to SSH public key file"
  type        = string
}

variable "ssh_private_key" {
  description = "Path to SSH private key file"
  type        = string
}