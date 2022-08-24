terraform {
  required_version = "~> 1.1.8"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.1.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 3.2.0"
    }
  }
}

module "subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.subnet_addrs.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 8
    },
    {
      name     = "vm"
      new_bits = 8
    },
    {
      name     = "pe"
      new_bits = 8
    },
  ]
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "cloudinit" {}
provider "tls" {}

data "cloudinit_config" "cloudinit" {
  base64_encode = true
  gzip          = true
  part {
    content_type = "text/cloud-config"
    content      = file("${path.module}/cloud-init/tailscale.yaml")
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/cloud-init/tailscale.sh", {
      tailscale_auth_key = var.tailscale_auth_key
      tailscale_routes = join(",",
        [
          module.subnet_addrs.network_cidr_blocks["default"],
          module.subnet_addrs.network_cidr_blocks["vm"],
          module.subnet_addrs.network_cidr_blocks["pe"]
        ]
      )
    })
  }
}

resource "azurerm_resource_group" "ts_sample" {
  name     = local.rg.name
  location = local.rg.location
}

resource "azurerm_virtual_network" "default" {
  name                = "vnet-default"
  resource_group_name = azurerm_resource_group.ts_sample.name
  location            = azurerm_resource_group.ts_sample.location
  address_space       = [module.subnet_addrs.base_cidr_block]
}

resource "azurerm_subnet" "default" {
  name                 = "snet-default"
  resource_group_name  = azurerm_resource_group.ts_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["default"]]
}


resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.ts_sample.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = [module.subnet_addrs.network_cidr_blocks["vm"]]
}

resource "azurerm_subnet" "pe" {
  name                                           = "snet-pe"
  resource_group_name                            = azurerm_resource_group.ts_sample.name
  virtual_network_name                           = azurerm_virtual_network.default.name
  address_prefixes                               = [module.subnet_addrs.network_cidr_blocks["pe"]]
}

resource "azurerm_network_security_group" "router" {
  name                = "nsg-router"
  resource_group_name = azurerm_resource_group.ts_sample.name
  location            = azurerm_resource_group.ts_sample.location
}

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default"
  resource_group_name = azurerm_resource_group.ts_sample.name
  location            = azurerm_resource_group.ts_sample.location
}

resource "azurerm_network_security_rule" "tailscale_inbound" {
  name                        = "Tailscale"
  resource_group_name         = azurerm_resource_group.ts_sample.name
  network_security_group_name = azurerm_network_security_group.router.name
  priority                    = 1010
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = 41641
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_interface" "router" {
  name                          = "nic-router"
  resource_group_name           = azurerm_resource_group.ts_sample.name
  location                      = azurerm_resource_group.ts_sample.location
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.default.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "target" {
  name                          = "nic-target"
  resource_group_name           = azurerm_resource_group.ts_sample.name
  location                      = azurerm_resource_group.ts_sample.location
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "router" {
  network_interface_id      = azurerm_network_interface.router.id
  network_security_group_id = azurerm_network_security_group.router.id
}

resource "azurerm_network_interface_security_group_association" "target" {
  network_interface_id      = azurerm_network_interface.target.id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "router" {
  name                            = "vmrouter"
  resource_group_name             = azurerm_resource_group.ts_sample.name
  location                        = azurerm_resource_group.ts_sample.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.router.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    diff_disk_settings {
      option = "Local"
    }
    disk_size_gb = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  custom_data = data.cloudinit_config.cloudinit.rendered
}

resource "azurerm_virtual_machine_extension" "aad_login_linux_router" {
  name                       = "AADLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.router.id
  publisher                  = "Microsoft.Azure.ActiveDirectory.LinuxSSH"
  type                       = "AADLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_linux_virtual_machine" "target" {
  name                            = "vmtarget"
  resource_group_name             = azurerm_resource_group.ts_sample.name
  location                        = azurerm_resource_group.ts_sample.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.target.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    diff_disk_settings {
      option = "Local"
    }
    disk_size_gb = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "aad_login_linux_target" {
  name                       = "AADLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.target.id
  publisher                  = "Microsoft.Azure.ActiveDirectory.LinuxSSH"
  type                       = "AADLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_private_dns_zone" "sample_site_web" {
  name                = "privatelink.web.core.windows.net"
  resource_group_name = azurerm_resource_group.ts_sample.name
}

resource "azurerm_private_dns_zone" "sample_site_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.ts_sample.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sample_site_web" {
  name                  = "pdnsz-link-sample-site-web"
  resource_group_name   = azurerm_resource_group.ts_sample.name
  private_dns_zone_name = azurerm_private_dns_zone.sample_site_web.name
  virtual_network_id    = azurerm_virtual_network.default.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "sample_site_blob" {
  name                  = "pdnsz-link-sample-site-blob"
  resource_group_name   = azurerm_resource_group.ts_sample.name
  private_dns_zone_name = azurerm_private_dns_zone.sample_site_blob.name
  virtual_network_id    = azurerm_virtual_network.default.id
}


resource "azurerm_storage_account" "sample_site" {
  name                     = "${var.prefix}tssample"
  resource_group_name      = azurerm_resource_group.ts_sample.name
  location                 = azurerm_resource_group.ts_sample.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    default_action = "Deny"
  }

  static_website {
    index_document = "index.html"
  }
}

resource "azurerm_private_endpoint" "sample_site_web" {
  name                = "pe-sample-site-web"
  resource_group_name = azurerm_resource_group.ts_sample.name
  location            = azurerm_resource_group.ts_sample.location
  subnet_id           = azurerm_subnet.pe.id

  private_dns_zone_group {
    name                 = "pdnsz-group-sample-site-web"
    private_dns_zone_ids = [azurerm_private_dns_zone.sample_site_web.id]
  }

  private_service_connection {
    name                           = "pe-connection-sample-site-web"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.sample_site.id
    subresource_names              = ["web"]
  }
}

resource "azurerm_private_endpoint" "sample_site_blob" {
  name                = "pe-sample-site-blob"
  resource_group_name = azurerm_resource_group.ts_sample.name
  location            = azurerm_resource_group.ts_sample.location
  subnet_id           = azurerm_subnet.pe.id

  private_dns_zone_group {
    name                 = "pdnsz-group-sample-site-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.sample_site_blob.id]
  }

  private_service_connection {
    name                           = "pe-connection-sample-site-blob"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.sample_site.id
    subresource_names              = ["blob"]
  }
}
