import unittest
from unittest.mock import patch

from autoscale import (
    Autoscaler,
    AutoscaleConfig,
    HostCapacity,
    ServiceCapacity,
    calculate_desired_replicas,
    calculate_effective_max,
    parse_percentage,
)


def config(**overrides):
    values = {
        "min_replicas": 1,
        "max_replicas": 4,
        "target_cpu_percent": 70.0,
        "target_memory_percent": 70.0,
        "scale_up_samples": 2,
        "interval_seconds": 15,
        "cooldown_seconds": 60,
        "max_step": 1,
        "enforce_host_capacity": True,
        "host_headroom_percent": 10.0,
        "dry_run": False,
    }
    values.update(overrides)
    return AutoscaleConfig(**values)


class AutoscaleCalculationTests(unittest.TestCase):
    def test_cpu_pressure_scales_one_worker_to_two(self):
        decision = calculate_desired_replicas([300.0], [10.0], 4.0, config(), 4)
        self.assertEqual(decision.desired_replicas, 2)

    def test_aggregate_cpu_demand_is_stable_after_scale_up(self):
        decision = calculate_desired_replicas([150.0, 150.0], [10.0, 10.0], 4.0, config(), 4)
        self.assertEqual(decision.desired_replicas, 2)

    def test_memory_pressure_can_request_scale_up(self):
        decision = calculate_desired_replicas([20.0], [80.0], 4.0, config(), 4)
        self.assertEqual(decision.desired_replicas, 2)

    def test_capacity_limit_caps_requested_replicas(self):
        decision = calculate_desired_replicas([390.0], [90.0], 4.0, config(), 1)
        self.assertGreater(decision.uncapped_replicas, 1)
        self.assertEqual(decision.desired_replicas, 1)

    def test_idle_worker_keeps_minimum(self):
        decision = calculate_desired_replicas([0.0], [1.0], 4.0, config(), 4)
        self.assertEqual(decision.desired_replicas, 1)

    def test_host_capacity_uses_stricter_cpu_limit(self):
        effective = calculate_effective_max(
            config(host_headroom_percent=0.0),
            ServiceCapacity(cpu_cores=4.0, memory_bytes=8 * 1024**3),
            HostCapacity(cpu_cores=8, memory_bytes=32 * 1024**3),
        )
        self.assertEqual(effective, 2)

    def test_host_capacity_never_drops_below_minimum(self):
        effective = calculate_effective_max(
            config(min_replicas=1),
            ServiceCapacity(cpu_cores=4.0, memory_bytes=8 * 1024**3),
            HostCapacity(cpu_cores=2, memory_bytes=4 * 1024**3),
        )
        self.assertEqual(effective, 1)

    def test_parse_percentage_rejects_invalid_value(self):
        with self.assertRaises(ValueError):
            parse_percentage("12.5")

    def test_scale_up_requires_consecutive_samples(self):
        autoscaler = Autoscaler(
            config(scale_up_samples=2, cooldown_seconds=0),
            ServiceCapacity(cpu_cores=4.0, memory_bytes=8 * 1024**3),
            effective_max=4,
        )
        with (
            patch("autoscale.running_worker_ids", return_value=["worker-1"]),
            patch("autoscale.collect_metrics", return_value=([300.0], [10.0])),
            patch("autoscale.scale_to") as scale,
            patch("autoscale.log"),
        ):
            autoscaler.sample()
            scale.assert_not_called()
            autoscaler.sample()
            scale.assert_called_once_with(2, False)

    def test_cooldown_delays_repeated_scale_up(self):
        autoscaler = Autoscaler(
            config(scale_up_samples=1, cooldown_seconds=60),
            ServiceCapacity(cpu_cores=4.0, memory_bytes=8 * 1024**3),
            effective_max=4,
        )
        autoscaler.last_scale_at = 100.0
        with (
            patch("autoscale.running_worker_ids", return_value=["worker-1"]),
            patch("autoscale.collect_metrics", return_value=([300.0], [10.0])),
            patch("autoscale.scale_to") as scale,
            patch("autoscale.log"),
            patch("autoscale.time.monotonic", side_effect=[130.0, 161.0, 161.0]),
        ):
            autoscaler.sample()
            scale.assert_not_called()
            autoscaler.sample()
            scale.assert_called_once_with(2, False)


if __name__ == "__main__":
    unittest.main()
