locals {
  subnet_addrs = {
    base_cidr_block = "192.168.0.0/16"
  }
  rg = {
    name     = "rg-tailscale-sample"
    location = "japaneast"
  }
}

