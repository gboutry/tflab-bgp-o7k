"""Exercise the deployer's route acceptance check without a live LXD host."""

import os
from pathlib import Path
import subprocess
import unittest


DEPLOY = Path(__file__).resolve().parents[1] / "deploy.sh"
SCRIPT = DEPLOY.read_text()
RETURN_CHECK = SCRIPT.split("hc_has_return_routes() {\n", 1)[1].split("\n}\n", 1)[0]


class ReturnRoutesTest(unittest.TestCase):
    def accepts(self, mode, node, routes):
        result = subprocess.run(
            [
                "bash",
                "-c",
                'remote() { printf "%s\\n" "$ROUTES"; }\n'
                "hc_has_return_routes() {\n" + RETURN_CHECK + "\n}\n"
                'hc_has_return_routes "$NODE"',
            ],
            env={**os.environ, "BGP_PEERING_MODE": mode, "NODE": node, "ROUTES": routes},
            capture_output=True,
            text=True,
        )
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.returncode == 0

    def test_numbered_requires_the_correct_tor(self):
        for node, gateway in (("hc1", "172.20.1.1"), ("hc2", "172.20.1.1"), ("hc3", "172.20.2.1")):
            with self.subTest(node=node):
                routes = f"default via {gateway} dev br-bgp proto bird\n172.20.10.0/24 via {gateway} dev br-bgp"
                self.assertTrue(self.accepts("ipv4-numbered", node, routes))
                self.assertFalse(self.accepts("unnumbered", node, routes))
                other = "172.20.2.1" if gateway == "172.20.1.1" else "172.20.1.1"
                self.assertFalse(self.accepts("ipv4-numbered", node, routes.replace(gateway, other)))

    def test_unnumbered_requires_link_local_gateway(self):
        routes = "default via inet6 fe80::1 dev br-bgp proto bird\n172.20.10.0/24 via inet6 fe80::1 dev br-bgp"
        for node in ("hc1", "hc2", "hc3"):
            with self.subTest(node=node):
                self.assertTrue(self.accepts("unnumbered", node, routes))
                self.assertFalse(self.accepts("ipv4-numbered", node, routes))

    def test_client_route_is_required(self):
        for mode, gateway in (("unnumbered", "inet6 fe80::1"), ("ipv4-numbered", "172.20.1.1")):
            with self.subTest(mode=mode):
                self.assertFalse(self.accepts(mode, "hc1", f"default via {gateway} dev br-bgp"))

    def test_invalid_mode_fails_before_lxd_access(self):
        result = subprocess.run(
            ["bash", str(DEPLOY)],
            env={**os.environ, "BGP_PEERING_MODE": "numberd"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "Invalid BGP_PEERING_MODE: numberd")


if __name__ == "__main__":
    unittest.main()
