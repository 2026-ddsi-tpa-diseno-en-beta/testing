"""Regression checks for demo expectations and eventual MCP reads; no services required."""
import unittest
from unittest.mock import Mock, patch

from probar_demo import McpResponseError, decode_mcp_result, donor_report_matches, wait_for


class DemoTest(unittest.TestCase):
    def error(self, status=404, method='GET'):
        operation={'name':'ficha_integral_donador','method':method}
        result={'isError':True,'structuredContent':{'status':status,'traceId':'test-trace'}}
        return McpResponseError(operation,result)

    def test_mcp_failure_preserves_upstream_status(self):
        result={'isError':True,'structuredContent':{'status':404,'traceId':'test-trace'}}
        with self.assertRaises(McpResponseError) as caught:
            decode_mcp_result({'name':'ficha_integral_donador','method':'GET'},result)
        self.assertEqual(404,caught.exception.status)
        self.assertIs(result,caught.exception.result)
        self.assertIn('404',str(caught.exception))

    @patch('probar_demo.time.sleep')
    def test_eventual_mcp_read_retries_404_then_returns_the_projection(self, sleep):
        projection={'categoria':'TRANSFORMADOR'}
        action=Mock(side_effect=[self.error(),projection])
        self.assertEqual(projection,wait_for('ficha',action,lambda value:bool(value),1))
        self.assertEqual(2,action.call_count)
        sleep.assert_called_once_with(0.5)

    @patch('probar_demo.time.sleep')
    def test_write_failure_is_not_retried(self, sleep):
        error=self.error(method='POST')
        action=Mock(side_effect=error)
        with self.assertRaises(McpResponseError) as caught:
            wait_for('escritura',action,bool,1)
        self.assertIs(error,caught.exception)
        self.assertEqual(1,action.call_count)
        sleep.assert_not_called()

    @patch('probar_demo.time.sleep')
    def test_non_retryable_or_unstructured_mcp_failures_are_not_hidden(self, sleep):
        for status in (400,409,422,None):
            with self.subTest(status=status):
                error=self.error(status=status)
                with self.assertRaises(McpResponseError) as caught:
                    wait_for('ficha',Mock(side_effect=error),bool,1)
                self.assertEqual(status,caught.exception.status)
        sleep.assert_not_called()

    def test_final_report_accepts_requalification_after_two_stock_deliveries(self):
        # The scenario first proves revocation at 19 successes; delivering the
        # two stock donations raises it to 21 and restores the earned category.
        report={'categoria':'TRANSFORMADOR','cantidadQuejas':2,
                'entidadesBeneficiadas':[{'unidades':30},{'unidades':10}]}
        self.assertTrue(donor_report_matches(report,category='TRANSFORMADOR',complaints=2,delivered_units=40))
        self.assertFalse(donor_report_matches(report,category='COLABORADOR',complaints=2,delivered_units=40))
        report['cantidadQuejas']=1
        self.assertFalse(donor_report_matches(report,category='TRANSFORMADOR',complaints=2,delivered_units=40))


if __name__=='__main__':
    unittest.main()
