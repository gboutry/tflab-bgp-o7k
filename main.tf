locals {
  numbered = var.bgp_peering_mode == "ipv4-numbered"
  # HC1/HC2 share Leaf1's L2; HC3 has a separate subnet behind Leaf2.
  hc_peers = {
    hc1 = { address = "172.20.1.11", leaf = "172.20.1.1", link_local = "fe80::101" }
    hc2 = { address = "172.20.1.12", leaf = "172.20.1.1", link_local = "fe80::102" }
    hc3 = { address = "172.20.2.13", leaf = "172.20.2.1", link_local = "fe80::103" }
  }
  inventory_json = jsonencode(jsondecode(replace(
    file("${path.module}/inventory.json"), "nbgp", var.name_prefix
  )))

  networks = {
    mgmt = {
      name       = "${var.name_prefix}-mgmt", ipv4 = "10.246.20.1/24", nat = "true"
      dhcp_range = "10.246.20.100-10.246.20.200"
    }
    client      = { name = "${var.name_prefix}-client", ipv4 = "none", nat = "false" }
    leaf1_hosts = { name = "${var.name_prefix}-l1-hosts", ipv4 = "none", nat = "false" }
    leaf2_hosts = { name = "${var.name_prefix}-l2-hosts", ipv4 = "none", nat = "false" }
    spine_leaf1 = { name = "${var.name_prefix}-l1-spine", ipv4 = "none", nat = "false" }
    spine_leaf2 = { name = "${var.name_prefix}-l2-spine", ipv4 = "none", nat = "false" }
  }

  nodes = {
    hc1 = {
      type = "virtual-machine", role = "hc", mgmt = 11, cpu = "4", memory = "10GB", disk = "60GiB"
      interfaces = {
        bgp = { network = "leaf1_hosts", ifname = "enp5s0", addresses = [], routes = [] }
      }
      asn = 65101
    }
    hc2 = {
      type = "virtual-machine", role = "hc", mgmt = 12, cpu = "4", memory = "10GB", disk = "60GiB"
      interfaces = {
        bgp = { network = "leaf1_hosts", ifname = "enp5s0", addresses = [], routes = [] }
      }
      asn = 65102
    }
    hc3 = {
      type = "virtual-machine", role = "hc", mgmt = 13, cpu = "4", memory = "10GB", disk = "60GiB"
      interfaces = {
        bgp = { network = "leaf2_hosts", ifname = "enp5s0", addresses = [], routes = [] }
      }
      asn = 65103
    }
    leaf1 = {
      type = "container", role = "leaf1", mgmt = 21, cpu = "1", memory = "512MiB", disk = "8GiB"
      interfaces = {
        hosts0  = { network = "leaf1_hosts", ifname = "eth1", addresses = [local.numbered ? "172.20.1.1/24" : "fe80::1/64"], routes = [] }
        spine0  = { network = "spine_leaf1", ifname = "eth2", addresses = ["172.20.0.1/30"], routes = [] }
        client0 = { network = "client", ifname = "eth3", addresses = ["172.20.10.1/24"], routes = [] }
      }
      asn = 65001
    }
    leaf2 = {
      type = "container", role = "leaf2", mgmt = 22, cpu = "1", memory = "512MiB", disk = "8GiB"
      interfaces = {
        hosts0 = { network = "leaf2_hosts", ifname = "eth1", addresses = [local.numbered ? "172.20.2.1/24" : "fe80::1/64"], routes = [] }
        spine0 = { network = "spine_leaf2", ifname = "eth2", addresses = ["172.20.0.5/30"], routes = [] }
      }
      asn = 65002
    }
    spine = {
      type = "container", role = "spine", mgmt = 23, cpu = "1", memory = "512MiB", disk = "8GiB"
      interfaces = {
        leaf1 = { network = "spine_leaf1", ifname = "eth1", addresses = ["172.20.0.2/30"], routes = [] }
        leaf2 = { network = "spine_leaf2", ifname = "eth2", addresses = ["172.20.0.6/30"], routes = [] }
      }
      asn = 65000
    }
    container1 = {
      type = "container", role = "client", mgmt = 24, cpu = "1", memory = "256MiB", disk = "8GiB"
      interfaces = {
        test0 = { network = "client", ifname = "eth1", addresses = ["172.20.10.2/24"], routes = [
          { to = "172.20.20.0/24", via = "172.20.10.1" }
        ] }
      }
      asn = 0
    }
  }

  bird_configs = {
    hc1 = templatefile("${path.module}/bird/hyperconverged.conf.tftpl", {
      router_id     = "10.246.20.11"
      local_asn     = 65101
      local_address = local.numbered ? local.hc_peers.hc1.address : local.hc_peers.hc1.link_local
      leaf_address  = local.numbered ? local.hc_peers.hc1.leaf : "fe80::1"
      numbered      = local.numbered
      bridge        = "br-bgp"
      leaf_asn      = 65001
      client_prefix = "172.20.10.0/24"
    })
    hc2 = templatefile("${path.module}/bird/hyperconverged.conf.tftpl", {
      router_id     = "10.246.20.12"
      local_asn     = 65102
      local_address = local.numbered ? local.hc_peers.hc2.address : local.hc_peers.hc2.link_local
      leaf_address  = local.numbered ? local.hc_peers.hc2.leaf : "fe80::1"
      numbered      = local.numbered
      bridge        = "br-bgp"
      leaf_asn      = 65001
      client_prefix = "172.20.10.0/24"
    })
    hc3 = templatefile("${path.module}/bird/hyperconverged.conf.tftpl", {
      router_id     = "10.246.20.13"
      local_asn     = 65103
      local_address = local.numbered ? local.hc_peers.hc3.address : local.hc_peers.hc3.link_local
      leaf_address  = local.numbered ? local.hc_peers.hc3.leaf : "fe80::1"
      numbered      = local.numbered
      bridge        = "br-bgp"
      leaf_asn      = 65002
      client_prefix = "172.20.10.0/24"
    })
    leaf1 = templatefile("${path.module}/bird/leaf1.conf.tftpl", { numbered = local.numbered })
    leaf2 = templatefile("${path.module}/bird/leaf2.conf.tftpl", { numbered = local.numbered })
    spine = templatefile("${path.module}/bird/spine.conf.tftpl", {})
  }
}

resource "lxd_network" "lab" {
  for_each = local.networks

  name = each.value.name
  type = "bridge"
  config = merge(
    {
      "ipv4.address" = each.value.ipv4
      "ipv4.nat"     = each.value.nat
      "ipv6.address" = "none"
      "dns.domain"   = "${var.name_prefix}.test"
    },
    each.key == "mgmt" ? { "ipv4.dhcp.ranges" = each.value.dhcp_range } : {}
  )
}

# Cloud-init runs only at first boot. Recreate guests when the peering mode
# or inventory changes rather than leaving stale guest configuration.
resource "terraform_data" "peering_mode" {
  triggers_replace = [var.bgp_peering_mode, filesha256("${path.module}/inventory.json")]
}

resource "lxd_instance" "node" {
  for_each = local.nodes

  name     = "${var.name_prefix}-${each.key}"
  type     = each.value.type
  image    = var.image_alias
  profiles = []

  lifecycle {
    replace_triggered_by = [terraform_data.peering_mode]
  }

  config = merge({
    "limits.cpu"    = each.value.cpu
    "limits.memory" = each.value.memory
    "cloud-init.user-data" = "#cloud-config\n${yamlencode({
      for key, value in local.user_data[each.key] : key => value
      if contains(["runcmd", "write_files", "users"], key) ? length(value) > 0 : true
    })}"
    "cloud-init.network-config" = yamlencode(local.network_config[each.key])
  })

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = var.storage_pool
      size = each.value.disk
    }
  }

  dynamic "device" {
    for_each = merge(
      {
        mgmt = {
          type = "nic"
          properties = {
            network        = lxd_network.lab["mgmt"].name
            name           = each.value.type == "container" ? "eth0" : "eth0"
            "ipv4.address" = "10.246.20.${each.value.mgmt}"
          }
        }
      },
      { for iface, nic in each.value.interfaces : iface => {
        type = "nic"
        properties = {
          network = lxd_network.lab[nic.network].name
          name    = nic.ifname
        }
      } },
      {}
    )

    content {
      name       = device.key
      type       = device.value.type
      properties = device.value.properties
    }
  }
}

resource "terraform_data" "deploy" {
  triggers_replace = [
    var.name_prefix,
    var.bgp_peering_mode,
    var.neutron_package_version,
    var.regress_stack_commit,
    filesha256("${path.module}/deploy.sh"),
    filesha256("${path.module}/main.tf"),
    filesha256("${path.module}/inventory.json"),
    filesha256("${path.module}/patches/local-provider-bridge.patch"),
    sha256(join("", [
      for template in sort(fileset(path.module, "bird/*.tftpl")) :
      filesha256("${path.module}/${template}")
    ])),
    sha256(jsonencode({ for name, instance in lxd_instance.node : name => instance.mac_address })),
  ]

  depends_on = [lxd_instance.node]

  provisioner "local-exec" {
    command = "bash \"${path.module}/deploy.sh\""

    environment = {
      BGP_PEERING_MODE  = var.bgp_peering_mode
      NAME_PREFIX       = var.name_prefix
      REGRESS_STACK_SHA = var.regress_stack_commit
      NEUTRON_VERSION   = var.neutron_package_version
      INVENTORY_JSON    = local.inventory_json
    }
  }
}

locals {
  network_config = {
    for node, spec in local.nodes : node => {
      version = 2
      ethernets = merge(
        { (spec.type == "container" ? "eth0" : "enp6s0") = { dhcp4 = true, dhcp6 = false } },
        { for iface, nic in spec.interfaces : nic.ifname => merge(
          { dhcp4 = false, dhcp6 = false, "link-local" = [], optional = true },
          length(nic.addresses) > 0 ? { addresses = nic.addresses } : {},
          length(nic.routes) > 0 ? { routes = nic.routes } : {}
        ) }
      )
    }
  }

  user_data = {
    for node, spec in local.nodes : node => {
      hostname         = "${var.name_prefix}-${node}"
      manage_etc_hosts = true
      package_update   = true
      users = var.ssh_public_key == "" ? [] : [{
        name                = "ubuntu"
        groups              = ["sudo"]
        shell               = "/bin/bash"
        sudo                = "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys = [var.ssh_public_key]
      }]
      packages = spec.role == "client" ? ["iputils-ping", "curl"] : ["bird2", "tcpdump", "iproute2"]
      write_files = concat(
        contains(["hc", "leaf1", "leaf2", "spine"], spec.role) ? [
          { path = "/etc/bird/bird.conf", permissions = "0644", content = local.bird_configs[node] },
          { path = "/etc/sysctl.d/90-${var.name_prefix}-routing.conf", permissions = "0644", content = "net.ipv4.ip_forward=1\nnet.ipv4.conf.all.rp_filter=0\nnet.ipv4.conf.default.rp_filter=0\n" }
        ] : [],
        spec.role == "hc" ? [
          { path = "/etc/apt/sources.list.d/resolute-proposed.sources", permissions = "0644", content = "Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: resolute-proposed\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n" },
          { path = "/etc/apt/preferences.d/90-${var.name_prefix}-neutron", permissions = "0644", content = "Package: neutron neutron-* python3-neutron*\nPin: version ${var.neutron_package_version}\nPin-Priority: 1001\n" },
        ] : []
      )
      runcmd = concat(
        contains(["leaf1", "leaf2", "spine"], spec.role) ? [
          ["sysctl", "--system"],
          ["bird", "-p", "-c", "/etc/bird/bird.conf"],
          ["systemctl", "enable", "--now", "bird"]
        ] : [],
        spec.role == "hc" ? [
          ["sysctl", "--system"],
          ["systemctl", "disable", "--now", "bird"]
        ] : []
      )
    }
  }
}

output "management" {
  value = { for node, spec in local.nodes : "${var.name_prefix}-${node}" => "10.246.20.${spec.mgmt}" }
}

output "leaf_placement" {
  value = {
    leaf1 = ["${var.name_prefix}-hc1", "${var.name_prefix}-hc2"]
    leaf2 = ["${var.name_prefix}-hc3"]
  }
}
