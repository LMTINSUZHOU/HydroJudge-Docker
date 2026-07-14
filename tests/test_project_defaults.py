import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_env_example():
    values = {}
    for raw_line in (ROOT / ".env.example").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip("'\"")
    return values


class ProjectDefaultTests(unittest.TestCase):
    def test_example_uses_twelve_gibibyte_container_limit(self):
        values = read_env_example()
        self.assertEqual(values["CONTAINER_MEMORY_LIMIT"], "12g")
        self.assertEqual(values["CONTAINER_MEMORY_SWAP_LIMIT"], "12g")

    def test_compose_fallbacks_match_example_memory_limits(self):
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        values = read_env_example()
        memory_default = re.search(r"CONTAINER_MEMORY_LIMIT:-([^}]+)", compose)
        swap_default = re.search(r"CONTAINER_MEMORY_SWAP_LIMIT:-([^}]+)", compose)
        self.assertIsNotNone(memory_default)
        self.assertIsNotNone(swap_default)
        self.assertEqual(memory_default.group(1), values["CONTAINER_MEMORY_LIMIT"])
        self.assertEqual(swap_default.group(1), values["CONTAINER_MEMORY_SWAP_LIMIT"])


if __name__ == "__main__":
    unittest.main()
