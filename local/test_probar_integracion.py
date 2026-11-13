"""Regressions for the legacy MCP/REST suite's asynchronous stock reads."""
import unittest
from unittest.mock import call, patch

import probar_integracion as suite


def reservation(quantity, origin='SOLICITUD_ENTIDAD'):
    return {'necesidadID':'need','cantidadAsignada':quantity,'origen':origin}


class InitialStockReadTest(unittest.TestCase):
    @patch('probar_integracion.time.monotonic', return_value=0)
    @patch('probar_integracion.time.sleep')
    def test_delayed_empty_and_partial_reads_converge_without_repeating_writes(self, sleep, clock):
        complete=[reservation(4),reservation(6)]
        with patch.object(suite,'request',side_effect=[[],[reservation(4)],complete]) as request:
            self.assertEqual(complete,suite.wait_for_stock_assignments('need',[4,6]))
        self.assertEqual([call('logistica','GET','/asignaciones')]*3,request.call_args_list)
        self.assertEqual(2,sleep.call_count)

    @patch('probar_integracion.time.monotonic', return_value=0)
    @patch('probar_integracion.time.sleep')
    def test_empty_read_fails_at_the_deadline(self, sleep, clock):
        with patch.object(suite,'request',return_value=[]) as request:
            with self.assertRaisesRegex(AssertionError,'need: timeout'):
                suite.wait_for_stock_assignments('need',[4,6],timeout=0)
        self.assertEqual(1,request.call_count)
        sleep.assert_not_called()

    @patch('probar_integracion.time.sleep')
    def test_permanent_request_error_is_propagated_without_retry(self, sleep):
        error=AssertionError('HTTP 400 permanent request error')
        with patch.object(suite,'request',side_effect=error) as request:
            with self.assertRaises(AssertionError) as caught:
                suite.wait_for_stock_assignments('need',[4,6])
        self.assertIs(error,caught.exception)
        self.assertEqual(1,request.call_count)
        sleep.assert_not_called()

    @patch('probar_integracion.time.sleep')
    def test_invalid_complete_quantities_are_not_hidden_by_a_later_good_read(self, sleep):
        with patch.object(suite,'request',side_effect=[
                [reservation(3),reservation(7)],[reservation(4),reservation(6)]]) as request:
            with self.assertRaises(AssertionError):
                suite.wait_for_stock_assignments('need',[4,6])
        self.assertEqual(1,request.call_count)
        sleep.assert_not_called()


if __name__=='__main__':
    unittest.main()
