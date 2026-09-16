#!/usr/bin/env python3

import unittest

from resolve_musa_apt_packages import package_index, resolve


def package(name, version, depends=""):
    return {
        "Package": name,
        "Version": version,
        "Depends": depends,
        "Filename": f"pool/{name}_{version}.deb",
        "SHA256": "0" * 64,
        "Size": "1",
    }


class ResolveMusaAptPackagesTest(unittest.TestCase):

    def test_prefers_requested_sdk_series_regardless_of_index_order(self):
        stanzas = [
            package("libmthreads-compute", "5.2.0"),
            package("libmthreads-compute", "5.1.0"),
            package(
                "mccl-s4000",
                "2.4.0",
                "musa-musart-5-2 (>= 5.2.0), "
                "musa-toolkit-5-2-config-common (= 5.2.0)",
            ),
            package(
                "mccl-s4000",
                "2.3.0",
                "musa-musart-5-1 (>= 5.1.0), "
                "musa-toolkit-5-1-config-common (= 5.1.0)",
            ),
            package("musa-musart-5-1", "5.1.0"),
            package("musa-toolkit-5-1-config-common", "5.1.0"),
        ]

        resolved = resolve(
            ["libmthreads-compute", "mccl-s4000"],
            package_index(stanzas),
            preferred_version="5.1.0",
        )

        self.assertIn(("libmthreads-compute", "5.1.0"), self.versions(resolved))
        self.assertIn(("mccl-s4000", "2.3.0"), self.versions(resolved))
        self.assertNotIn(("libmthreads-compute", "5.2.0"), self.versions(resolved))
        self.assertNotIn(("mccl-s4000", "2.4.0"), self.versions(resolved))

    def test_honors_debian_version_constraint(self):
        stanzas = [package("dependency", "2.0.0"), package("dependency", "1.0.0")]

        resolved = resolve(
            ["dependency (<= 1.0.0)"], package_index(stanzas)
        )

        self.assertEqual(self.versions(resolved), {("dependency", "1.0.0")})

    @staticmethod
    def versions(resolved):
        return {(entry["Package"], entry["Version"]) for entry in resolved}


if __name__ == "__main__":
    unittest.main()
