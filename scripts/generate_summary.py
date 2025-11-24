#!/usr/bin/env python3
"""
Generate test summary and reports
"""

import os
import json
import argparse
from pathlib import Path
from datetime import datetime
import logging
from jinja2 import Template

def setup_logging():
    """Setup logging"""
    logging.basicConfig(level=logging.INFO)
    return logging.getLogger(__name__)

def load_test_results():
    """Load test results from JSON files"""
    timestamp = os.getenv('TEST_TIMESTAMP', 'unknown')
    results_file = f"test_results/results_{timestamp}.json"
    
    if not Path(results_file).exists():
        return {}
    
    with open(results_file, 'r') as f:
        return json.load(f)

def generate_html_report(results: dict, metadata: dict):
    """Generate HTML report"""
    html_template = """
<!DOCTYPE html>
<html>
<head>
    <title>Test Execution Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .summary { margin: 20px 0; }
        .test-case { margin: 10px 0; padding: 15px; border: 1px solid #ddd; border-radius: 5px; }
        .passed { background-color: #d4edda; border-color: #c3e6cb; }
        .failed { background-color: #f8d7da; border-color: #f5c6cb; }
        .error { background-color: #fff3cd; border-color: #ffeaa7; }
        .details { margin-top: 10px; font-size: 0.9em; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Test Execution Report</h1>
        <p><strong>Test Case:</strong> {{ metadata.test_case }}</p>
        <p><strong>Environment:</strong> {{ metadata.environment }}</p>
        <p><strong>SUT Host:</strong> {{ metadata.sut_host }}</p>
        <p><strong>Executed by:</strong> {{ metadata.actor }}</p>
        <p><strong>Timestamp:</strong> {{ metadata.timestamp }}</p>
    </div>
    
    <div class="summary">
        <h2>Summary</h2>
        <table>
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Total Tests</td><td>{{ summary.total }}</td></tr>
            <tr><td>Passed</td><td style="color: green;">{{ summary.passed }}</td></tr>
            <tr><td>Failed</td><td style="color: red;">{{ summary.failed }}</td></tr>
            <tr><td>Errors</td><td style="color: orange;">{{ summary.errors }}</td></tr>
            <tr><td>Success Rate</td><td>{{ "%.1f"|format(summary.success_rate) }}%</td></tr>
        </table>
    </div>
    
    <div class="results">
        <h2>Test Results</h2>
        {% for test_name, result in results.items() %}
        <div class="test-case {{ result.status.lower() }}">
            <h3>{{ test_name }}</h3>
            <p><strong>Status:</strong> {{ result.status }}</p>
            <p><strong>Duration:</strong> {{ "%.2f"|format(result.duration) }}s</p>
            {% if result.message %}
            <p><strong>Message:</strong> {{ result.message }}</p>
            {% endif %}
            
            {% if result.details.steps %}
            <div class="details">
                <h4>Test Steps:</h4>
                <ul>
                {% for step in result.details.steps %}
                <li>{{ step.step }}: <strong>{{ step.status }}</strong></li>
                {% endfor %}
                </ul>
            </div>
            {% endif %}
        </div>
        {% endfor %}
    </div>
</body>
</html>
    """
    
    # Calculate summary statistics
    total_tests = len(results)
    passed_tests = sum(1 for r in results.values() if r['status'] == 'PASSED')
    failed_tests = sum(1 for r in results.values() if r['status'] == 'FAILED')
    error_tests = sum(1 for r in results.values() if r['status'] == 'ERROR')
    success_rate = (passed_tests / total_tests * 100) if total_tests > 0 else 0
    
    summary = {
        'total': total_tests,
        'passed': passed_tests,
        'failed': failed_tests,
        'errors': error_tests,
        'success_rate': success_rate
    }
    
    template = Template(html_template)
    html_content = template.render(
        results=results,
        metadata=metadata,
        summary=summary
    )
    
    # Save HTML report
    timestamp = os.getenv('TEST_TIMESTAMP', 'unknown')
    html_file = f"reports/test_report_{timestamp}.html"
    Path('reports').mkdir(exist_ok=True)
    
    with open(html_file, 'w') as f:
        f.write(html_content)
    
    return html_file

def generate_markdown_summary(results: dict, metadata: dict):
    """Generate markdown summary for GitHub"""
    timestamp = os.getenv('TEST_TIMESTAMP', 'unknown')
    
    # Calculate summary
    total_tests = len(results)
    passed_tests = sum(1 for r in results.values() if r['status'] == 'PASSED')
    failed_tests = sum(1 for r in results.values() if r['status'] == 'FAILED')
    error_tests = sum(1 for r in results.values() if r['status'] == 'ERROR')
    success_rate = (passed_tests / total_tests * 100) if total_tests > 0 else 0
    
    markdown_content = f"""# Test Execution Summary

## Execution Details
- **Test Case:** {metadata['test_case']}
- **Environment:** {metadata['environment']}
- **SUT Host:** {metadata['sut_host']}
- **Timestamp:** {metadata['timestamp']}
- **Triggered by:** {metadata['actor']}

## Summary Statistics
- **Total Tests:** {total_tests}
- **Passed:** ✅ {passed_tests}
- **Failed:** ❌ {failed_tests}
- **Errors:** ⚠️ {error_tests}
- **Success Rate:** {success_rate:.1f}%

## Test Results
"""
    
    for test_name, result in results.items():
        status_icon = "✅" if result['status'] == 'PASSED' else "❌" if result['status'] == 'FAILED' else "⚠️"
        markdown_content += f"- {status_icon} **{test_name}**: {result['status']} ({result.get('duration', 0):.2f}s)\n"
        
        if result.get('message'):
            markdown_content += f"  - Message: {result['message']}\n"
    
    markdown_content += f"\n---\n*Report generated at {datetime.now().isoformat()}*"
    
    # Save markdown summary
    summary_file = f"test_results/summary.md"
    with open(summary_file, 'w') as f:
        f.write(markdown_content)
    
    return summary_file

def main():
    parser = argparse.ArgumentParser(description='Generate test summary and reports')
    parser.add_argument('--test-case', required=True, help='Test case that was run')
    parser.add_argument('--environment', required=True, help='Target environment')
    parser.add_argument('--actor', required=True, help='GitHub actor')
    
    args = parser.parse_args()
    logger = setup_logging()
    
    try:
        # Load test results
        results = load_test_results()
        
        if not results:
            logger.warning("No test results found")
            return
        
        # Load metadata
        with open('test_results/run_metadata.json', 'r') as f:
            metadata = json.load(f)
        
        # Generate HTML report
        html_file = generate_html_report(results, metadata)
        logger.info(f"HTML report generated: {html_file}")
        
        # Generate markdown summary
        md_file = generate_markdown_summary(results, metadata)
        logger.info(f"Markdown summary generated: {md_file}")
        
        logger.info("Summary generation completed successfully")
        
    except Exception as e:
        logger.error(f"Summary generation failed: {e}")
        raise

if __name__ == '__main__':
    main()
