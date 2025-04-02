###############################################################################
# 1) Terraform & Providers
###############################################################################
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
  required_version = ">= 1.0.0"
}

# Configure the Azure provider (relying on 'az login' credentials)
provider "azurerm" {
  features {}
}

###############################################################################
# 2) Virtual Machine Creation with Mongo DB
###############################################################################

variable "prefix" {
  default = "vm-with-mongo"
}

resource "azurerm_resource_group" "yna" {
  name     = "${var.prefix}-resources"
  location = "West Europe"
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.yna.location
  resource_group_name = azurerm_resource_group.yna.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.yna.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "main" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.yna.location
  resource_group_name = azurerm_resource_group.yna.name

  ip_configuration {
    name                          = "ip-configuration"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.yna.id
  }
}

resource "azurerm_public_ip" "yna" {
  name                = "vm-with-mongo-publicIP"
  resource_group_name = azurerm_resource_group.yna.name
  location            = azurerm_resource_group.yna.location
  allocation_method   = "Static"
}

resource "azurerm_virtual_machine" "main" {
  name                  = "${var.prefix}-vm"
  location              = azurerm_resource_group.yna.location
  resource_group_name   = azurerm_resource_group.yna.name
  network_interface_ids = [azurerm_network_interface.main.id]
  vm_size               = "Standard_DS1_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  storage_os_disk {
    name              = "vm-with-mongo-myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "vm-with-mongo"
    admin_username = "testadmin"
    admin_password = "Password1234!"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  tags = {
    environment = "staging"
  }
}
resource "azurerm_virtual_machine_extension" "mongo_install" {
  name                 = "mongoInstall"
  virtual_machine_id   = azurerm_virtual_machine.main.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  # This command runs AFTER the VM is provisioned, MongoDB Installation and Setup.
  settings = <<-SETTINGS
    {
      "commandToExecute": "sudo apt-get install gnupg curl && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --yes -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor && echo 'deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse' | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list && sudo apt-get update && sudo apt-get install -y mongodb-org=7.0.11 mongodb-org-database=7.0.11 mongodb-org-server=7.0.11 mongodb-mongosh mongodb-org-shell=7.0.11 mongodb-org-mongos=7.0.11 mongodb-org-tools=7.0.11 mongodb-org-database-tools-extra=7.0.11 && sudo systemctl start mongod && sudo systemctl daemon-reload && sudo systemctl enable mongod"
    }
  SETTINGS
}

###############################################################################
# 3) Setting up Blob Storage with Mongo DB Backup
###############################################################################

variable "blobprefix" {
  default = "blob-storage"
}

resource "azurerm_resource_group" "blob" {
  name     = "${var.blobprefix}-resources"
  location = "West Europe"
}

resource "azurerm_storage_account" "blob" {
  name                     = "mdbstorageacct"
  resource_group_name      = azurerm_resource_group.blob.name
  location                 = azurerm_resource_group.blob.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Blob Storage Container
resource "azurerm_storage_container" "blob" {
  name                  = "mongobackupcontainer"
  storage_account_name  = azurerm_storage_account.blob.name
  container_access_type = "blob"
}

data "azurerm_storage_account_sas" "blobdata" {
  connection_string = azurerm_storage_account.blob.primary_connection_string

# Start on April 1, 2025 at 00:00 UTC
  start  = "2025-04-01T00:00Z"
# Expire on April 30, 2025 at 23:59 UTC
  expiry = "2025-04-30T23:59Z"

  https_only = false

  # Which services do we want in this SAS? 
  # All four must be defined, set them to false if not needed.
  services {
    blob  = true
    file  = false
    queue = false
    table = false
  }

  # Resource types: each must be a boolean
  resource_types {
    service   = true
    container = true
    object    = true
  }

  # Permissions: each must be a boolean
  permissions {
    read    = true
    write   = true
    delete  = true
    list    = true
    add     = true
    create  = true
    update  = true
    process = true
    tag     = true
    filter  = true
  }
}

###############################################################################
# Outputs: For accessing your blob storage in scripts or other tooling
###############################################################################

# Outputs the name and primary access key of your Storage Account
# so you can use them to authenticate (e.g., Azure CLI, scripts, etc.).

output "blob_sas_token" {
  description = "SAS Token for the backup container"
  value       = data.azurerm_storage_account_sas.blobdata.sas
  sensitive   = true
}

output "blob_sas_url" {
  description = "A pre-signed (SAS) URL to the backup container"
  value       = format(
    "https://%s.blob.core.windows.net/%s?%s",
    azurerm_storage_account.blob.name,
    azurerm_storage_container.blob.name,
    data.azurerm_storage_account_sas.blobdata.sas
  )
  sensitive = true
}

# this is a test