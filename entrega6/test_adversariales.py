"""Check that the destructive-test harness refuses unrelated stacks and reports failures."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from probar_adversariales import DockerStack, Probe


class HarnessTest(unittest.TestCase):
    def outage_probe(self, directory):
        stack=Mock(spec=DockerStack)
        probe=Probe('http://127.0.0.1:8080',stack,Path(directory),'active',1)
        probe.product=Mock(return_value='product')
        probe.depot=Mock(return_value='depot')
        probe.donate=Mock(return_value=('donation','package'))
        probe.wait_health=Mock()
        return probe,stack

    @patch('probar_adversariales.subprocess.run')
    def test_unrelated_project_cannot_issue_docker_commands(self, command):
        with self.assertRaises(AssertionError):
            DockerStack('another-project')
        command.assert_not_called()

    def test_label_mismatch_prevents_stop(self):
        stack=DockerStack('dds-paquete2-test')
        stack.command=Mock(return_value='another-project')
        with self.assertRaises(AssertionError):
            stack.stop('logistica')
        self.assertEqual(1,stack.command.call_count)
        self.assertEqual('inspect',stack.command.call_args.args[0])

    def test_worker_evidence_matches_complete_package_identity(self):
        stack=DockerStack('dds-paquete2-test')
        stack.container=Mock(return_value='local-worker')
        stack.command=Mock(return_value='matchmaking.finalizado paquete=10 necesidad=n')
        self.assertEqual({'worker-1':[],'worker-2':[]},stack.processed_packages(['1']))
        stack.command.return_value='matchmaking.finalizado paquete=1 necesidad=n'
        self.assertTrue(all(stack.processed_packages(['1']).values()))

    def test_outage_checks_durable_task_after_donor_restart_before_recovering_logistics(self):
        with tempfile.TemporaryDirectory() as directory:
            probe,stack=self.outage_probe(directory)
            assigned=[{'id':'assignment','cantidadAsignada':10}]
            probe.stock=Mock(side_effect=[10,0])
            probe.http=Mock(side_effect=[(201,{'id':'need'}),(200,{'status':'UP'})])
            probe.okay=Mock(return_value={'id':'need','cantidadAsignada':0})
            probe.assignments=Mock(return_value=assigned)
            probe.stock_request=Mock(return_value=(200,assigned))
            stack.stock_task_status.side_effect=['f','f','t']
            stack.running.return_value=False
            result=probe.need_during_outage()
            self.assertFalse(result['task_completed_after_donor_restart_while_logistics_down'])
            self.assertTrue(result['task_completed_after_recovery'])
            calls=[(call[0],call.args) for call in stack.mock_calls]
            self.assertLess(calls.index(('restart',('donadores',))),calls.index(('start',('logistica',))))
            self.assertEqual(3,stack.stock_task_status.call_count)
            stack.start.assert_any_call('donadores')
            stack.start.assert_any_call('logistica')

    def test_outage_failure_still_restores_both_apis_and_gateway(self):
        with tempfile.TemporaryDirectory() as directory:
            probe,stack=self.outage_probe(directory)
            probe.stock=Mock(return_value=10)
            probe.http=Mock(return_value=(201,{'id':'need'}))
            probe.okay=Mock(side_effect=AssertionError('need was not visible'))
            with self.assertRaises(AssertionError):
                probe.need_during_outage()
            stack.start.assert_any_call('donadores')
            stack.start.assert_any_call('logistica')
            stack.restart.assert_called_with('gateway')

    def test_drained_main_queue_does_not_hide_dead_lettered_work(self):
        with tempfile.TemporaryDirectory() as directory:
            stack=Mock(spec=DockerStack)
            stack.worker_consumers.return_value=2
            stack.matchmaking_queues.return_value={
                'logistica.matchmaking':{'ready':0,'unacked':0},
                'logistica.matchmaking.dlq':{'ready':1,'unacked':0}}
            probe=Probe('http://127.0.0.1:8080',stack,Path(directory),'controlled',1)
            with self.assertRaises(AssertionError):
                probe.workers_and_queues_restored()

    def test_failed_assertion_is_recorded_and_causes_nonzero_result(self):
        with tempfile.TemporaryDirectory() as directory:
            probe=Probe('http://127.0.0.1:8080',DockerStack('dds-paquete2-test'),Path(directory),'active',1)
            def bootstrap():
                probe.donor='donor'; probe.entity='entity'
            probe.bootstrap=bootstrap
            probe.active_race=Mock(side_effect=AssertionError('reserved 20 instead of 10'))
            probe.need_during_outage=Mock(return_value={'creation_status':201})
            with patch('builtins.print'):
                self.assertEqual(1,probe.run())
            result=json.loads((Path(directory)/'active.json').read_text(encoding='utf-8'))
            self.assertTrue(result['complete'])
            self.assertEqual(1,result['failed'])
            self.assertEqual('FAIL',result['cases'][1]['status'])
            self.assertIn('reserved 20',result['cases'][1]['error'])

    def test_failed_precondition_is_incomplete_and_never_runs_functional_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            probe=Probe('http://127.0.0.1:8080',DockerStack('dds-paquete2-test'),Path(directory),'active',1)
            probe.bootstrap=Mock(side_effect=RuntimeError('no real PostgreSQL'))
            probe.active_race=Mock()
            probe.need_during_outage=Mock()
            with patch('builtins.print'):
                self.assertEqual(1,probe.run())
            result=json.loads((Path(directory)/'active.json').read_text(encoding='utf-8'))
            self.assertFalse(result['complete'])
            self.assertEqual(1,result['errors'])
            probe.active_race.assert_not_called()
            probe.need_during_outage.assert_not_called()


if __name__=='__main__':
    unittest.main()
