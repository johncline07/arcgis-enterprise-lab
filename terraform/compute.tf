resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-jumpbox"
  resource_group_name = azurerm_resource_group.arcgis_rg.name
  location            = azurerm_resource_group.arcgis_rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = "vm-jumpbox"
  resource_group_name = azurerm_resource_group.arcgis_rg.name
  location            = azurerm_resource_group.arcgis_rg.location
  size                = "Standard_D2s_v7"
  admin_username      = "azureadmin"

  network_interface_ids = [
    azurerm_network_interface.jumpbox.id,
  ]

  admin_ssh_key {
    username   = "azureadmin"
    public_key = file("~/.ssh/arcgis-jumpbox.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "22.04.202602250"
  }

  disable_password_authentication = true

}

locals {
  private_vms = {
    web = {
      name    = "vm-web"
      size    = "Standard_D2s_v7"
      nic_id  = azurerm_network_interface.web.id
      role    = "web"
      disk_gb = 64
    }

    geoserver = {
      name    = "vm-geoserver"
      size    = "Standard_D2s_v7"
      nic_id  = azurerm_network_interface.geoserver.id
      role    = "geoserver"
      disk_gb = 64
    }

    postgis = {
      name    = "vm-postgis"
      size    = "Standard_D2s_v7"
      nic_id  = azurerm_network_interface.postgis.id
      role    = "postgis"
      disk_gb = 64
    }
  }
}

resource "azurerm_linux_virtual_machine" "private" {
  for_each = local.private_vms

  name                = each.value.name
  resource_group_name = azurerm_resource_group.arcgis_rg.name
  location            = azurerm_resource_group.arcgis_rg.location
  size                = each.value.size
  admin_username      = "azureadmin"

  network_interface_ids = [
    each.value.nic_id
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = "azureadmin"
    public_key = file(pathexpand("~/.ssh/arcgis-internal.pub"))
  }

  os_disk {
    name                 = "disk-${each.value.name}-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.disk_gb
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "rhel-byos"
    sku       = "rhel-lvm98-gen2"
    version   = "9.8.2026062323"
  }

  plan {
    name      = "rhel-lvm98-gen2"
    product   = "rhel-byos"
    publisher = "redhat"
  }

  tags = {
    environment = "lab"
    role        = "web"
  }
}

moved {
  from = azurerm_linux_virtual_machine.web
  to   = azurerm_linux_virtual_machine.private["web"]
}