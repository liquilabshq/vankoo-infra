# Mock-only plans: do not contact Azure or create resources.
mock_provider "azurerm" {}
mock_provider "random" {}
mock_provider "tls" {}

override_data {
  target = data.terraform_remote_state.core
  values = {
    outputs = {
      suffix                     = "test01"
      environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test"
      environment_default_domain = "test.centralus.azurecontainerapps.io"
    }
  }
}
override_data {
  target = data.terraform_remote_state.base
  values = {
    outputs = {
      acr_login_server   = "fixture.azurecr.io"
      acr_admin_username = "fixture"
      acr_admin_password = "mock-only-not-a-credential"
    }
  }
}
variables {
  tfstate_storage_account   = "fixturestate"
  investment_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC6nJt0wveGvnC4aj0QhMQ4oXl8oFoDiqY0S0EnqJBPT fixture"
  # Do not let ignored local deployment files affect mock-only tests.
  database_client_cidrs = []
  image                 = ""
  external_ingress      = false
  api_client_cidrs      = []
}
run "bootstrap_is_internal_and_database_is_closed" {
  command = plan
  assert {
    condition     = azurerm_linux_virtual_machine.database.size == "Standard_D2s_v4"
    error_message = "The default size must match the deployed VM, not an unavailable B2 SKU."
  }
  assert {
    condition     = azurerm_container_app.investment.ingress[0].external_enabled == false
    error_message = "Bootstrap must never expose the sample app publicly."
  }
  assert {
    condition     = length(azurerm_network_security_rule.oracle_tls) == 0
    error_message = "No Oracle allow rule before discovering the app's egress IPs."
  }
  assert {
    condition     = azurerm_container_app.investment.template[0].container[0].image == "mcr.microsoft.com/k8se/quickstart:latest"
    error_message = "Bootstrap must not start Investment before Oracle access is configured."
  }
}
run "deployment_requires_an_image_and_egress_ips" {
  command = plan
  variables { bootstrap = false }
  expect_failures = [azurerm_container_app.investment]
}
run "external_demo_requires_a_client_allowlist" {
  command = plan
  variables { external_ingress = true }
  expect_failures = [azurerm_container_app.investment]
}
run "final_deployment_keeps_a_single_replica_and_tls_only" {
  command = plan
  variables {
    bootstrap             = false
    image                 = "fixture.azurecr.io/investment-service:test"
    database_client_cidrs = ["192.0.2.10/32"]
  }
  assert {
    condition     = azurerm_container_app.investment.template[0].max_replicas == 1
    error_message = "The academic deployment must not scale beyond one replica."
  }
  assert {
    condition     = azurerm_network_security_rule.oracle_tls[0].destination_port_range == "2484"
    error_message = "Oracle clients must use TLS, not public plaintext 1521."
  }
}
