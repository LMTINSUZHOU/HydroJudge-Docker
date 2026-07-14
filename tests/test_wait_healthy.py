import unittest

from wait_healthy import WorkerState, evaluate_worker_states


class WaitHealthyTests(unittest.TestCase):
    def test_all_expected_workers_are_healthy(self):
        states = [
            WorkerState("worker-1", "running", "healthy"),
            WorkerState("worker-2", "running", "healthy"),
        ]
        self.assertEqual(
            evaluate_worker_states(states, 2),
            (True, False, "健康副本 2/2"),
        )

    def test_missing_worker_is_still_pending(self):
        ready, terminal, summary = evaluate_worker_states(
            [WorkerState("worker-1", "running", "healthy")], 2
        )
        self.assertFalse(ready)
        self.assertFalse(terminal)
        self.assertIn("1/2", summary)

    def test_unhealthy_worker_fails_immediately(self):
        ready, terminal, summary = evaluate_worker_states(
            [WorkerState("worker-1", "running", "unhealthy")], 1
        )
        self.assertFalse(ready)
        self.assertTrue(terminal)
        self.assertIn("健康检查失败", summary)

    def test_exited_worker_fails_immediately(self):
        ready, terminal, summary = evaluate_worker_states(
            [WorkerState("worker-1", "exited", "unhealthy", "exit 1")], 1
        )
        self.assertFalse(ready)
        self.assertTrue(terminal)
        self.assertIn("提前退出", summary)

    def test_zero_replicas_is_ready_when_no_containers_exist(self):
        self.assertEqual(
            evaluate_worker_states([], 0),
            (True, False, "容器数量 0/0"),
        )


if __name__ == "__main__":
    unittest.main()
