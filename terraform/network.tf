resource "azurerm_resource_group" "arcgis_rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "arcgis_vnet" {
  name                = var.vnet_name
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.arcgis_rg.location
  resource_group_name = azurerm_resource_group.arcgis_rg.name
}

resource "azurerm_subnet" "portal" {
  name                            = "snet-portal"
  resource_group_name             = azurerm_resource_group.arcgis_rg.name
  virtual_network_name            = azurerm_virtual_network.arcgis_vnet.name
  address_prefixes                = ["10.0.1.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "server" {
  name                            = "snet-server"
  resource_group_name             = azurerm_resource_group.arcgis_rg.name
  virtual_network_name            = azurerm_virtual_network.arcgis_vnet.name
  address_prefixes                = ["10.0.2.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "datastore" {
  name                            = "snet-datastore"
  resource_group_name             = azurerm_resource_group.arcgis_rg.name
  virtual_network_name            = azurerm_virtual_network.arcgis_vnet.name
  address_prefixes                = ["10.0.3.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "jumpbox" {
  name                            = "snet-jumpbox"
  resource_group_name             = azurerm_resource_group.arcgis_rg.name
  virtual_network_name            = azurerm_virtual_network.arcgis_vnet.name
  address_prefixes                = ["10.0.4.0/24"]
  default_outbound_access_enabled = false
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-jumpbox"
  location            = azurerm_resource_group.arcgis_rg.location
  resource_group_name = azurerm_resource_group.arcgis_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jumpbox.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_network_interface" "web" {
  name                = "nic-web"
  location            = azurerm_resource_group.arcgis_rg.location
  resource_group_name = azurerm_resource_group.arcgis_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.portal.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
  }

  tags = {
    environment = "lab"
    role        = "web"
  }
}

resource "azurerm_network_interface" "geoserver" {
  name                = "nic-geoserver"
  location            = azurerm_resource_group.arcgis_rg.location
  resource_group_name = azurerm_resource_group.arcgis_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.server.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.10"
  }

  tags = {
    environment = "lab"
    role        = "geoserver"
  }
}

resource "azurerm_network_interface" "postgis" {
  name                = "nic-postgis"
  location            = azurerm_resource_group.arcgis_rg.location
  resource_group_name = azurerm_resource_group.arcgis_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.datastore.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.10"
  }

  tags = {
    environment = "lab"
    role        = "postgis"
  }
}

resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-egress"
  resource_group_name = azurerm_resource_group.arcgis_rg.name
  location            = azurerm_resource_group.arcgis_rg.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = "lab"
    role        = "nat-egress"
  }
}

resource "azurerm_nat_gateway" "private_egress" {
  name                = "nat-private-egress"
  resource_group_name = azurerm_resource_group.arcgis_rg.name
  location            = azurerm_resource_group.arcgis_rg.location
  sku_name            = "Standard"

  tags = {
    environment = "lab"
    role        = "private-egress"
  }
}

resource "azurerm_nat_gateway_public_ip_association" "private_egress" {
  nat_gateway_id       = azurerm_nat_gateway.private_egress.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "portal" {
  subnet_id      = azurerm_subnet.portal.id
  nat_gateway_id = azurerm_nat_gateway.private_egress.id
}

resource "azurerm_subnet_nat_gateway_association" "server" {
  subnet_id      = azurerm_subnet.server.id
  nat_gateway_id = azurerm_nat_gateway.private_egress.id
}

resource "azurerm_subnet_nat_gateway_association" "datastore" {
  subnet_id      = azurerm_subnet.datastore.id
  nat_gateway_id = azurerm_nat_gateway.private_egress.id
}