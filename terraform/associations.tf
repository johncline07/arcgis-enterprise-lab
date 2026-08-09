resource "azurerm_subnet_network_security_group_association" "portal" {
  subnet_id                 = azurerm_subnet.portal.id
  network_security_group_id = azurerm_network_security_group.portal.id
}

resource "azurerm_subnet_network_security_group_association" "server" {
  subnet_id                 = azurerm_subnet.server.id
  network_security_group_id = azurerm_network_security_group.server.id
}

resource "azurerm_subnet_network_security_group_association" "datastore" {
  subnet_id                 = azurerm_subnet.datastore.id
  network_security_group_id = azurerm_network_security_group.datastore.id
}

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  subnet_id                 = azurerm_subnet.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}