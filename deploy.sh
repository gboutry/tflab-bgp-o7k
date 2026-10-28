#!/usr/bin/env bash
set -Eeuo pipefail

BGP_PEERING_MODE=${BGP_PEERING_MODE:-unnumbered}
case "$BGP_PEERING_MODE" in
    unnumbered|ipv4-numbered) ;;
    *) echo "Invalid BGP_PEERING_MODE: $BGP_PEERING_MODE" >&2; exit 1 ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREFIX=$NAME_PREFIX
REVISION=$REGRESS_STACK_SHA
TMP_DIR="$(mktemp -d /tmp/nbgp-deploy.XXXXXX)"
chmod 0700 "$TMP_DIR"
mkdir -m 0700 "$TMP_DIR/preseeds"
trap 'rm -rf -- "$TMP_DIR"' EXIT
printf '%s\n' "$INVENTORY_JSON" >"$TMP_DIR/inventory.json"
chmod 0600 "$TMP_DIR/inventory.json"

HC1="$PREFIX-hc1"
HC2="$PREFIX-hc2"
HC3="$PREFIX-hc3"
log() { printf '\n==> %s\n' "$*"; }
remote() {
    local node=$1
    shift
    lxc exec --mode=non-interactive "$PREFIX-$node" -- "$@"
}
remote_script() {
    local node=$1
    shift
    lxc exec --mode=non-interactive "$PREFIX-$node" -- bash -s -- "$@"
}
os() {
    lxc exec --mode=non-interactive "$HC1" -- bash -lc \
        'set -a; . /root/auth.rc; set +a; exec openstack "$@"' _ "$@"
}
wait_for() {
    local what=$1
    shift
    local attempt
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 10
    done
    echo "Timed out waiting for $what" >&2
    "$@" >&2 || true
    return 1
}
server_active() {
    [[ "$(os server show "$1" -f value -c status)" == ACTIVE ]]
}
hc_has_fip_route() {
    local routes
    routes=$(remote "$1" ip -4 route show table 42)
    grep -Fq "$2 proto ovn" <<<"$routes"
}
hc_has_return_routes() {
    local routes gateway
    gateway='inet6 fe80::1'
    if [[ "$BGP_PEERING_MODE" == ipv4-numbered ]]; then
        case "$1" in
            hc1|hc2) gateway=172.20.1.1 ;;
            hc3) gateway=172.20.2.1 ;;
        esac
    fi
    routes=$(remote "$1" ip -4 route show table 10)
    grep -Fq '172.20.10.0/24' <<<"$routes" &&
        grep -Fq "default via $gateway dev br-bgp" <<<"$routes"
}
leaf_has_all_fips() {
    local routes
    routes=$(remote "$1" birdc show route)
    grep -Fq '172.20.20.69/32' <<<"$routes" &&
        grep -Fq '172.20.20.26/32' <<<"$routes" &&
        grep -Fq '172.20.20.60/32' <<<"$routes"
}

command -v lxc >/dev/null
lxc info >/dev/null
log "Waiting for cloud-init on all guests"
for node in hc1 hc2 hc3 leaf1 leaf2 spine container1; do
    wait_for "$PREFIX-$node LXD agent" remote "$node" true
    remote "$node" cloud-init status --wait >/dev/null
done

log "Building regress-stack from PR 96 commit $REVISION with local interconnect support"
lxc file push --uid 0 --gid 0 --mode 0644 "$SCRIPT_DIR/patches/local-provider-bridge.patch" "$HC1/run/regress-stack-local-provider.patch"
remote_script hc1 "$REVISION" <<'REMOTE'
set -Eeuo pipefail
revision=$1
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential debhelper dh-python dpkg-dev fakeroot git \
    pybuild-plugin-pyproject python3-all python3-apt python3-click \
    python3-networkx python3-openstackclient python3-pyroute2 python3-pytest
source_dir=/home/ubuntu/regress-stack-pr96
if [ ! -d "$source_dir/.git" ]; then
    runuser -u ubuntu -- git clone --filter=blob:none --no-checkout \
        https://github.com/canonical/regress-stack.git "$source_dir"
fi
runuser -u ubuntu -- git -C "$source_dir" fetch --depth=1 origin "$revision"
runuser -u ubuntu -- git -C "$source_dir" checkout --force --detach "$revision"
test "$(runuser -u ubuntu -- git -C "$source_dir" rev-parse HEAD)" = "$revision"
runuser -u ubuntu -- git -C "$source_dir" apply --check /run/regress-stack-local-provider.patch
runuser -u ubuntu -- git -C "$source_dir" apply /run/regress-stack-local-provider.patch
runuser -u ubuntu -- bash -c \
    'cd /home/ubuntu/regress-stack-pr96 && dpkg-buildpackage -b -uc -us'
REMOTE

package_path="$(lxc exec --mode=non-interactive "$HC1" -- bash -lc \
    "find /home/ubuntu -maxdepth 1 -type f -name 'python3-regress-stack_*_all.deb' -print -quit")"
test -n "$package_path"
lxc file pull "$HC1$package_path" "$TMP_DIR/python3-regress-stack.deb"

log "Installing the pinned regress-stack package and role packages"
for node in hc1 hc2 hc3; do
    instance="$PREFIX-$node"
    lxc file push "$TMP_DIR/inventory.json" "$instance/root/inventory.json"
    lxc file push "$TMP_DIR/python3-regress-stack.deb" "$instance/tmp/python3-regress-stack.deb"
    remote_script "$node" "$instance" "$NEUTRON_VERSION" <<'REMOTE'
set -Eeuo pipefail
node=$1
neutron_version=$2
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y /tmp/python3-regress-stack.deb
rm -f /tmp/python3-regress-stack.deb
chmod 0600 /root/inventory.json
packages=$(regress-stack packages --inventory /root/inventory.json --node "$node")
test -n "$packages"
policy=/usr/sbin/policy-rc.d
saved=/run/policy-rc.d.nbgp-save
had_policy=0
if [ -e "$policy" ]; then cp -a "$policy" "$saved"; had_policy=1; fi
restore_policy() {
    if [ "$had_policy" = 1 ]; then cp -a "$saved" "$policy"; rm -f "$saved"
    else rm -f "$policy"; fi
}
trap restore_policy EXIT
printf '#!/bin/sh\nexit 101\n' >"$policy"
chmod 0755 "$policy"
# Package names are emitted by regress-stack and word splitting is intentional.
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $packages
restore_policy
trap - EXIT
candidate=$(apt-cache policy neutron-server | awk '/Candidate:/ {print $2}')
if [ "$candidate" != "$neutron_version" ]; then
    echo "Expected neutron-server $neutron_version; archive candidate is $candidate" >&2
    exit 1
fi
REMOTE
done

log "Bootstrapping the three-node hyperconverged deployment"
remote_script hc1 <<'REMOTE'
set -Eeuo pipefail
mkdir -p /root/regress-preseeds
chmod 0700 /root/regress-preseeds
regress-stack setup --inventory /root/inventory.json --node "$(hostname --short)" \
    --export-preseeds /root/regress-preseeds
REMOTE
for node in hc2 hc3; do
    instance="$PREFIX-$node"
    lxc file pull "$HC1/root/regress-preseeds/$instance.json" "$TMP_DIR/preseeds/$instance.json"
    chmod 0600 "$TMP_DIR/preseeds/$instance.json"
    lxc file push "$TMP_DIR/preseeds/$instance.json" "$instance/root/$instance.json"
    remote "$node" chown root:root "/root/$instance.json"
    remote "$node" chmod 0600 "/root/$instance.json"
    remote "$node" regress-stack setup --preseed "/root/$instance.json"
    remote "$node" rm -f "/root/$instance.json"
done
log "Waiting for regress-stack readiness"
wait_for "regress-stack ready" remote hc1 regress-stack ready
remote hc1 regress-stack ready

log "Configuring Neutron BGP and persistent peer bridges"
for item in "hc1 fe80::101 172.20.1.11" "hc2 fe80::102 172.20.1.12" "hc3 fe80::103 172.20.2.13"; do
    read -r node link_local ipv4 <<<"$item"
    address_command="/usr/sbin/ip -6 addr replace $link_local/64 dev br-bgp"
    if [[ "$BGP_PEERING_MODE" == ipv4-numbered ]]; then
        address_command="/usr/sbin/ip -4 addr replace $ipv4/24 dev br-bgp"
    fi
    remote_script "$node" "$address_command" <<'REMOTE'
set -Eeuo pipefail
address_command=$1
conf=/etc/neutron/neutron.conf
plugins=$(crudini --get "$conf" DEFAULT service_plugins 2>/dev/null || true)
case ",$plugins," in
    *,ovn-bgp,*) ;;
    *) if [ -n "$plugins" ]; then plugins="$plugins,ovn-bgp"; else plugins=ovn-bgp; fi
       crudini --set "$conf" DEFAULT service_plugins "$plugins" ;;
esac
crudini --set "$conf" bgp main_router_vrf_id 42
crudini --set "$conf" bgp chassis_router_vrf_id 10
cat >/etc/neutron/plugins/ml2/ovn_agent.ini <<'AGENT'
[agent]
extensions = ovn-bgp

[ovs]
ovsdb_connection = unix:/var/run/openvswitch/db.sock
AGENT
chown root:neutron /etc/neutron/plugins/ml2/ovn_agent.ini
chmod 0640 /etc/neutron/plugins/ml2/ovn_agent.ini
cat >/etc/systemd/system/nbgp-bgp-bridge.service <<UNIT
[Unit]
Description=Prepare local OVN BGP peer bridge
After=network-online.target openvswitch-switch.service
Wants=network-online.target
Requires=openvswitch-switch.service
Before=neutron-ovn-agent.service bird.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ovs-vsctl --may-exist add-br br-bgp
ExecStart=/usr/bin/ovs-vsctl --may-exist add-port br-bgp enp5s0
ExecStart=/usr/sbin/ip link set enp5s0 up
ExecStart=/usr/sbin/ip link set br-bgp up
ExecStart=$address_command
ExecStart=/usr/bin/ovs-vsctl set Open_vSwitch . external-ids:neutron-bgp-peer-bridges=br-bgp
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/neutron-ovn-agent.service <<'UNIT'
[Unit]
Description=Neutron OVN Agent with BGP extension
After=network-online.target openvswitch-switch.service ovn-controller.service nbgp-bgp-bridge.service
Wants=network-online.target ovn-controller.service
Requires=openvswitch-switch.service nbgp-bgp-bridge.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/neutron-ovn-agent --config-file=/etc/neutron/neutron.conf --config-file=/etc/neutron/plugins/ml2/ml2_conf.ini --config-file=/etc/neutron/plugins/ml2/ovn_agent.ini
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/bird.service.d
cat >/etc/systemd/system/bird.service.d/nbgp-bgp-bridge.conf <<'UNIT'
[Unit]
Requires=nbgp-bgp-bridge.service
After=nbgp-bgp-bridge.service
UNIT
systemctl daemon-reload
systemctl enable --now nbgp-bgp-bridge.service
REMOTE
done

remote hc1 neutron-db-manage --config-file /etc/neutron/neutron.conf \
    --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head
for node in hc1 hc2 hc3; do
    remote "$node" systemctl restart apache2 neutron-rpc-server neutron-periodic-workers
    remote "$node" systemctl enable --now neutron-ovn-agent bird
done
for node in hc1 hc2 hc3; do
    wait_for "$PREFIX-$node BGP agent" remote "$node" systemctl is-active neutron-ovn-agent
    wait_for "$PREFIX-$node BIRD" remote "$node" bash -lc 'birdc show protocols | grep -E "leaf.*BGP.*up"'
    mapping=$(remote "$node" ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings | tr -d '"')
    case ",$mapping," in
        *,physnet1:br-interconnect,*) ;;
        *) echo "$PREFIX-$node is missing physnet1:br-interconnect mapping: $mapping" >&2; exit 1 ;;
    esac
    case ",$mapping," in
        *,br-bgp:br-bgp,*) ;;
        *) echo "$PREFIX-$node is missing br-bgp:br-bgp mapping: $mapping" >&2; exit 1 ;;
    esac
    dynamic_mapping=$(remote "$node" ovs-vsctl get Open_vSwitch . external-ids:dynamic-routing-port-mapping | tr -d '"')
    case ",$dynamic_mapping," in
        *,br-bgp:br-bgp,*) ;;
        *) echo "$PREFIX-$node is missing dynamic-routing-port-mapping: $dynamic_mapping" >&2; exit 1 ;;
    esac
done

log "Creating provider and overlay networks and guest workloads"
if ! os network show external-network >/dev/null 2>&1; then
    os network create --external --share --provider-network-type flat \
        --provider-physical-network physnet1 external-network >/dev/null
fi
network_type=$(os network show external-network -f value -c provider:network_type)
physnet=$(os network show external-network -f value -c provider:physical_network)
if [[ "$network_type" != flat || "$physnet" != physnet1 ]]; then
    echo "external-network has unexpected provider mapping ($network_type/$physnet)" >&2
    exit 1
fi
if ! os subnet show external-subnet >/dev/null 2>&1; then
    os subnet create --network external-network --subnet-range 172.20.20.0/24 \
        --gateway 172.20.20.1 --allocation-pool start=172.20.20.20,end=172.20.20.80 \
        --dhcp external-subnet >/dev/null
else
    os subnet set --dhcp external-subnet
fi
if ! os network show bgp-overlay >/dev/null 2>&1; then os network create bgp-overlay >/dev/null; fi
if ! os subnet show bgp-overlay-subnet >/dev/null 2>&1; then
    os subnet create --network bgp-overlay --subnet-range 10.244.0.0/24 \
        bgp-overlay-subnet >/dev/null
fi
if ! os router show bgp-test-router >/dev/null 2>&1; then os router create bgp-test-router >/dev/null; fi
os router set --external-gateway external-network bgp-test-router
router_id=$(os router show bgp-test-router -f value -c id)
subnet_id=$(os subnet show bgp-overlay-subnet -f value -c id)
if ! os port list --router "$router_id" --fixed-ip "subnet=$subnet_id" -f value -c ID | grep -q .; then
    os router add subnet bgp-test-router bgp-overlay-subnet
fi

if ! os image show cirros-0.6.3 >/dev/null 2>&1; then
    image="$TMP_DIR/cirros-0.6.3-x86_64-disk.img"
    wget -qO "$image" https://download.cirros-cloud.net/0.6.3/cirros-0.6.3-x86_64-disk.img
    printf '%s  %s\n' \
        7d6355852aeb6dbcd191bcda7cd74f1536cfe5cbf8a10495a7283a8396e4b75b "$image" \
        | sha256sum --check --status
    lxc file push "$image" "$HC1/tmp/cirros-0.6.3-x86_64-disk.img"
    os image create cirros-0.6.3 --disk-format qcow2 \
        --container-format bare --file /tmp/cirros-0.6.3-x86_64-disk.img --public >/dev/null
    remote hc1 rm -f /tmp/cirros-0.6.3-x86_64-disk.img
fi
if ! os flavor show bgp-test >/dev/null 2>&1; then os flavor create bgp-test --vcpus 1 --ram 512 --disk 1 >/dev/null; fi
if ! os security group show bgp-test-sg >/dev/null 2>&1; then
    os security group create bgp-test-sg >/dev/null
fi
security_group_id=$(os security group show bgp-test-sg -f value -c id)
security_group_rules=$(os security group rule list "$security_group_id" -f value \
    -c "IP Protocol" -c Ethertype -c "IP Range" -c Direction)
if ! awk '$1 == "icmp" && $2 == "IPv4" && $3 == "0.0.0.0/0" && $4 == "ingress"' \
    <<<"$security_group_rules" | grep -q .; then
    os security group rule create --ingress --ethertype IPv4 --protocol icmp \
        --remote-ip 0.0.0.0/0 "$security_group_id" >/dev/null
fi

overlay_id=$(os network show bgp-overlay -f value -c id)
create_server() {
    local name=$1 host=$2 fixed_ip=$3
    if ! os server show "$name" >/dev/null 2>&1; then
        os server create --flavor bgp-test --image cirros-0.6.3 \
            --nic "net-id=$overlay_id,v4-fixed-ip=$fixed_ip" \
            --security-group bgp-test-sg --availability-zone "nova:$host" "$name" >/dev/null
    fi
    wait_for "$name active" server_active "$name"
    actual_host=$(os server show "$name" -f value -c OS-EXT-SRV-ATTR:host)
    if [[ "$actual_host" != "$host" ]]; then
        echo "$name landed on $actual_host, expected $host" >&2
        return 1
    fi
}
create_server bgp-test-hc1 "$HC1" 10.244.0.67
create_server bgp-test-hc2 "$HC2" 10.244.0.178
create_server bgp-test-vm "$HC3" 10.244.0.110
for pair in "bgp-test-hc1 172.20.20.69 10.244.0.67" \
    "bgp-test-hc2 172.20.20.26 10.244.0.178" \
    "bgp-test-vm 172.20.20.60 10.244.0.110"; do
    read -r server address fixed_ip <<<"$pair"
if ! os floating ip show "$address" >/dev/null 2>&1; then
        os floating ip create --floating-ip-address "$address" external-network >/dev/null
    fi
    port=$(os floating ip show "$address" -f value -c port_id)
    if [[ -z "$port" || "$port" == None ]]; then os server add floating ip "$server" "$address"; fi
    server_ports=$(os port list --server "$server" -f value -c ID)
    port=$(os floating ip show "$address" -f value -c port_id)
    if ! grep -Fxq "$port" <<<"$server_ports"; then
        echo "Floating IP $address is attached to port $port, not server $server" >&2
        exit 1
    fi
    actual_fixed_ip=$(os floating ip show "$address" -f value -c fixed_ip_address)
    if [[ "$actual_fixed_ip" != "$fixed_ip" ]]; then
        echo "Floating IP $address maps to $actual_fixed_ip, expected $fixed_ip" >&2
        exit 1
    fi
done

log "Refreshing provider subnet topology and checking route propagation"
os subnet set --dhcp external-subnet
for node in hc1 hc2 hc3; do remote "$node" systemctl restart neutron-periodic-workers; done
for pair in "hc1 172.20.20.69" "hc2 172.20.20.26" "hc3 172.20.20.60"; do
    read -r node address <<<"$pair"
    wait_for "$PREFIX-$node table 42 route for $address" hc_has_fip_route "$node" "$address"
done
for node in hc1 hc2 hc3; do
    wait_for "$PREFIX-$node table 10 return routes" hc_has_return_routes "$node"
done
for node in leaf1 leaf2 spine; do
    wait_for "$PREFIX-$node FIP routes" leaf_has_all_fips "$node"
done

log "Testing the three FIPs from the separate client L2"
for address in 172.20.20.69 172.20.20.26 172.20.20.60; do
    remote container1 ping -c 3 -W 2 "$address"
done
log "Deployment complete: all three FIPs answered from container1"
