#!/usr/bin/env python3
"""
Main test runner script for GitHub Actions
"""

import os
import sys
import json
import yaml
import argparse
import asyncio
import concurrent.futures
from pathlib import Path
from datetime import datetime
import logging
from typing import Dict, List, Any, Optional
import importlib.util

# Import test case modules
sys.path.append(str(Path(__file__).parent))

class TestRunner:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.logger = self.setup_logging()
        self.results = {}
        
    def setup_logging(self):
        """Setup logging for test runner"""
        log_file = f"logs/test_runner_{os.getenv('TEST_TIMESTAMP', 'unknown')}.log"
        
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.StreamHandler(sys.stdout),
                logging.FileHandler(log_file)
            ]
        )
        return logging.getLogger(__name__)
    
    def load_test_case_module(self, test_case: str):
        """Dynamically load test case module"""
        module_path = Path(f"test_cases/{test_case}.py")
        if not module_path.exists():
            raise FileNotFoundError(f"Test case module not found: {module_path}")
        
        spec = importlib.util.spec_from_file_location(test_case, module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    
    async def run_single_test(self, test_case: str, **kwargs) -> Dict[str, Any]:
        """Run a single test case"""
        self.logger.info(f"🚀 Starting {test_case}...")
        
        start_time = datetime.now()
        
        try:
            # Load test case module
            test_module = self.load_test_case_module(test_case)
            
            # Get test case configuration
            test_config = self.config['test_cases'].get(test_case, {})
            
            # Prepare test parameters
            test_params = {
                'sut_host': kwargs.get('sut_host'),
                'environment': kwargs.get('environment'),
                'additional_params': kwargs.get('additional_params', {}),
                'config': test_config,
                'logger': self.logger
            }
            
            # Run the test
            if hasattr(test_module, 'run_async'):
                result = await test_module.run_async(**test_params)
            else:
                # Run synchronous test in executor
                loop = asyncio.get_event_loop()
                with concurrent.futures.ThreadPoolExecutor() as executor:
                    result = await loop.run_in_executor(
                        executor, test_module.run, **test_params
                    )
            
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            
            # Prepare result
            test_result = {
                'test_case': test_case,
                'status': result.get('status', 'UNKNOWN'),
                'message': result.get('message', ''),
                'details': result.get('details', {}),
                'start_time': start_time.isoformat(),
                'end_time': end_time.isoformat(),
                'duration': duration,
                'logs': result.get('logs', [])
            }
            
            self.logger.info(f"✅ {test_case} completed: {test_result['status']}")
            return test_result
            
        except Exception as e:
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()
            
            error_result = {
                'test_case': test_case,
                'status': 'ERROR',
                'message': str(e),
                'details': {'error_type': type(e).__name__},
                'start_time': start_time.isoformat(),
                'end_time': end_time.isoformat(),
                'duration': duration,
                'logs': []
            }
            
            self.logger.error(f"❌ {test_case} failed: {e}")
            return error_result
    
    async def run_tests(self, test_case: str, **kwargs) -> Dict[str, Any]:
        """Run specified test case(s)"""
        self.logger.info(f"Starting test execution for: {test_case}")
        
        if test_case == 'all_tests':
            # Run all test cases
            test_cases = [f'test_case_{i}' for i in range(1, 7)]
            
            # Check if parallel execution is enabled
            env_config = self.config['environments'].get(kwargs.get('environment', 'staging'), {})
            parallel = env_config.get('parallel_execution', True)
            
            if parallel:
                # Run tests in parallel
                tasks = [self.run_single_test(tc, **kwargs) for tc in test_cases]
                results = await asyncio.gather(*tasks, return_exceptions=True)
            else:
                # Run tests sequentially
                results = []
                for tc in test_cases:
                    result = await self.run_single_test(tc, **kwargs)
                    results.append(result)
            
            # Process results
            for i, result in enumerate(results):
                if isinstance(result, Exception):
                    self.results[test_cases[i]] = {
                        'test_case': test_cases[i],
                        'status': 'ERROR',
                        'message': str(result),
                        'details': {},
                        'duration': 0
                    }
                else:
                    self.results[result['test_case']] = result
        else:
            # Run single test case
            result = await self.run_single_test(test_case, **kwargs)
            self.results[test_case] = result
        
        return self.results
    
    def save_results(self):
        """Save test results to files"""
        timestamp = os.getenv('TEST_TIMESTAMP', datetime.now().strftime('%Y%m%d_%H%M%S'))
        
        # Save JSON results
        json_file = f"test_results/results_{timestamp}.json"
        with open(json_file, 'w') as f:
            json.dump(self.results, f, indent=2)
        
        # Save summary
        summary_file = f"test_results/summary_{timestamp}.txt"
        with open(summary_file, 'w') as f:
            f.write("Test Execution Summary\n")
            f.write("=" * 50 + "\n")
            
            total_tests = len(self.results)
            passed_tests = sum(1 for r in self.results.values() if r['status'] == 'PASSED')
            failed_tests = sum(1 for r in self.results.values() if r['status'] == 'FAILED')
            error_tests = sum(1 for r in self.results.values() if r['status'] == 'ERROR')
            
            f.write(f"Total Tests: {total_tests}\n")
            f.write(f"Passed: {passed_tests}\n")
            f.write(f"Failed: {failed_tests}\n")
            f.write(f"Errors: {error_tests}\n\n")
            
            for test_case, result in self.results.items():
                status_icon = "✅" if result['status'] == 'PASSED' else "❌"
                f.write(f"{status_icon} {test_case}: {result['status']} ({result.get('duration', 0):.2f}s)\n")
                if result.get('message'):
                    f.write(f"   Message: {result['message']}\n")
        
        self.logger.info(f"Results saved to {json_file} and {summary_file}")

async def main():
    parser = argparse.ArgumentParser(description='Run test cases')
    parser.add_argument('--test-case', required=True, help='Test case to run')
    parser.add_argument('--environment', required=True, help='Target environment')
    parser.add_argument('--sut-host', help='SUT host')
    parser.add_argument('--additional-params', default='{}', help='Additional parameters as JSON')
    parser.add_argument('--actor', required=True, help='GitHub actor')
    
    args = parser.parse_args()
    
    # Load configuration
    with open('config/config.yaml', 'r') as f:
        config = yaml.safe_load(f)
    
    # Parse additional parameters
    additional_params = json.loads(args.additional_params)
    
    # Create test runner
    runner = TestRunner(config)
    
    # Run tests
    await runner.run_tests(
        test_case=args.test_case,
        sut_host=args.sut_host,
        environment=args.environment,
        additional_params=additional_params,
        actor=args.actor
    )
    
    # Save results
    runner.save_results()
    
    # Exit with appropriate code
    failed_tests = sum(1 for r in runner.results.values() 
                      if r['status'] in ['FAILED', 'ERROR'])
    
    if failed_tests > 0:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == '__main__':
    asyncio.run(main())
