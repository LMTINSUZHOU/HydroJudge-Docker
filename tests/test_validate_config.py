import copy
import unittest

from validate_config import ConfigError, validate_compose_config


def valid_config():
    return {
        "services": {
            "hydrojudge": {
                "build": {
                    "args": {
                        "GOJUDGE_VERSION": "v1.12.1",
                        "HYDROJUDGE_VERSION": "4.0.5",
                        "UBUNTU_MIRROR": "http://mirrors.example.net/ubuntu",
                        "NPM_REGISTRY": "https://registry.example.net",
                    }
                },
                "cpus": 4,
                "mem_limit": "12884901888",
                "memswap_limit": "12884901888",
                "environment": {
                    "HYDRO_SERVER_URL": "https://oj.example.net/",
                    "HYDRO_JUDGE_UNAME": "judge",
                    "HYDRO_JUDGE_PASSWORD": "safe-password",
                    "HYDRO_HOST_TYPE": "hydro",
                    "HYDRO_MEMORY_MAX": "2048m",
                    "HYDRO_STDIO_SIZE": "256m",
                    "HYDRO_STRICT_MEMORY": "false",
                    "HYDRO_TESTCASES_MAX": "450",
                    "HYDRO_TOTAL_TIME_LIMIT": "3000",
                    "HYDRO_PROCESS_LIMIT": "32",
                    "HYDRO_PARALLELISM": "3",
                    "HYDRO_CONCURRENCY": "3",
                    "HYDRO_DETAIL": "full",
                    "HYDRO_RERUN": "1",
                    "HYDRO_PERFORMANCE": "true",
                    "HYDRO_SANDBOX_HOST": "http://127.0.0.1:5050",
                    "GOJUDGE_HTTP_ADDR": "127.0.0.1:5050",
                    "GOJUDGE_PARALLELISM": "3",
                    "GOJUDGE_OUTPUT_LIMIT": "256m",
                    "GOJUDGE_COPY_OUT_LIMIT": "256m",
                    "GOJUDGE_FILE_TIMEOUT": "30m",
                },
            }
        }
    }


class ValidateConfigTests(unittest.TestCase):
    def test_valid_configuration_has_no_warnings(self):
        self.assertEqual(validate_compose_config(valid_config()), [])

    def test_rejects_placeholder_password(self):
        document = valid_config()
        document["services"]["hydrojudge"]["environment"]["HYDRO_JUDGE_PASSWORD"] = (
            "change_me"
        )
        with self.assertRaisesRegex(ConfigError, "示例密码"):
            validate_compose_config(document)

    def test_rejects_server_url_without_scheme(self):
        document = valid_config()
        document["services"]["hydrojudge"]["environment"]["HYDRO_SERVER_URL"] = (
            "oj.example.net"
        )
        with self.assertRaisesRegex(ConfigError, "完整的 http"):
            validate_compose_config(document)

    def test_rejects_invalid_go_duration(self):
        document = valid_config()
        document["services"]["hydrojudge"]["environment"]["GOJUDGE_FILE_TIMEOUT"] = "soon"
        with self.assertRaisesRegex(ConfigError, "正数时长"):
            validate_compose_config(document)

    def test_rejects_swap_limit_below_memory_limit(self):
        document = valid_config()
        document["services"]["hydrojudge"]["memswap_limit"] = "4294967296"
        with self.assertRaisesRegex(ConfigError, "不能小于"):
            validate_compose_config(document)

    def test_warns_when_maximum_parallel_memory_exceeds_container(self):
        document = copy.deepcopy(valid_config())
        document["services"]["hydrojudge"]["environment"]["HYDRO_CONCURRENCY"] = "7"
        warnings = validate_compose_config(document)
        self.assertTrue(any("OOM" in warning for warning in warnings))


if __name__ == "__main__":
    unittest.main()
