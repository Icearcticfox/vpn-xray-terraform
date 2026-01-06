terraform {
  required_version = ">= 1.7.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.38"
    }
  }

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "icefox_infra"

    workspaces {
      name = "vpn-xray-terraform"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "xray" {
  name      = var.droplet_name
  region    = var.region
  size      = var.size
  image     = "ubuntu-24-04-x64"
  ssh_keys  = [var.ssh_key_fingerprint]
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    xray_port            = var.xray_port
    xray_server_name     = var.xray_server_name
    xray_update_script   = file("${path.module}/scripts/xray-update.sh")
    xray_bootstrap_script = templatefile("${path.module}/scripts/xray-bootstrap.sh.tpl", {
      xray_port        = var.xray_port
      xray_server_name = var.xray_server_name
    })
  })
}

resource "digitalocean_firewall" "xray" {
  name = "${var.droplet_name}-firewall"

  droplet_ids = [digitalocean_droplet.xray.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.allowed_ssh_ips
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.xray_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
