# Provider mocks keep these configuration tests independent of the LXD host.
# Requires Terraform >= 1.7. No instances or provisioners are run.
mock_provider "lxd" {}

run "default_unnumbered" {
  command = plan

  assert {
    condition = alltrue([
      for node, peer in local.hc_peers :
      strcontains(local.bird_configs[node], "local ${peer.link_local} as") &&
      strcontains(local.bird_configs[node], "neighbor fe80::1 as") &&
      strcontains(local.bird_configs[node], "extended next hop on;")
    ])
    error_message = "The default must retain IPv6 link-local peering on every HC."
  }

  assert {
    condition = alltrue([
      for leaf in ["leaf1", "leaf2"] :
      local.nodes[leaf].interfaces.hosts0.addresses == ["fe80::1/64"] &&
      strcontains(local.bird_configs[leaf], "local fe80::1 as") &&
      strcontains(local.bird_configs[leaf], "extended next hop on;")
    ])
    error_message = "The default must retain link-local ToR addressing and BIRD sessions."
  }
}

run "ipv4_numbered" {
  command = plan
  variables {
    bgp_peering_mode = "ipv4-numbered"
  }

  assert {
    condition = alltrue([
      for node, peer in local.hc_peers :
      strcontains(local.bird_configs[node], "local ${peer.address} as") &&
      strcontains(local.bird_configs[node], "neighbor ${peer.leaf} as") &&
      !strcontains(local.bird_configs[node], "extended next hop on;") &&
      !strcontains(local.bird_configs[node], "fe80::")
    ])
    error_message = "Every HC must use IPv4 transport and IPv4 next hops."
  }

  assert {
    condition = alltrue([
      for node, peer in local.hc_peers :
      strcontains(local.bird_configs[node == "hc3" ? "leaf2" : "leaf1"], "neighbor ${peer.address} as") &&
      strcontains(local.bird_configs[node == "hc3" ? "leaf2" : "leaf1"], "local ${peer.leaf} as")
    ])
    error_message = "Every ToR session must match its HC's IPv4 addressing."
  }

  assert {
    condition = (
      local.nodes.leaf1.interfaces.hosts0.addresses == ["172.20.1.1/24"] &&
      local.nodes.leaf2.interfaces.hosts0.addresses == ["172.20.2.1/24"] &&
      alltrue([for leaf in ["leaf1", "leaf2"] : !strcontains(local.bird_configs[leaf], "fe80::")])
    )
    error_message = "ToR interfaces must use separate numbered host subnets."
  }

  assert {
    condition     = terraform_data.peering_mode.triggers_replace == ["ipv4-numbered"]
    error_message = "Mode changes must trigger guest replacement."
  }
}

run "reject_invalid_mode" {
  command = plan
  variables {
    bgp_peering_mode = "numberd"
  }
  expect_failures = [var.bgp_peering_mode]
}
