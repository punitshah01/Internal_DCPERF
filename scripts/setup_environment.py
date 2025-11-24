#!/usr/bin/env python3
"""
Environment setup script for GitHub Actions test runner
"""

import os
import sys
import json
import yaml
import argparse
from pathlib import Path
from datetime import datetime
import logging

def setup_logging():
    """Setup logging configuration"""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.StreamHandler(sys.stdout),
            logging.FileHandler('setup.log')
        ]
    )
    return logging.getLogger(__name__)

def load_config():
    """Load configuration from YAML file"""
    config_path = Path('config/config.yaml')
    if not config_path.exists():
        raise FileNotFoundError(f"Configuration file not found: {config_path}")
    
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)

def setup_directories():
    """Create necessary directories"""
    directories = [
        'test_results',
        'reports',
        'logs',
        'temp'
    ]
    
    for directory in directories:
        Path(directory).mkdir(exist_ok=True)
        
def determine_sut_host(environment, custom_host, config):
    """Determine the SUT host to use"""
    if custom_host:
        return custom_host
    
    sut_hosts = config.get('sut_hosts', {})
    return sut_hosts.get(environment, f"default-{environment}.example.com")

def validate_inputs(test_case, environment, additional_params):
    """Validate input parameters"""
    valid_test_cases = [
        'test_case_1', 'test_case_2', 'test_case_3',
        'test_case_4', 'test_case_5', 'test_case_6', 'all_tests'
    ]
    
    valid_environments = ['staging', 'production', 'development']
    
    if test_case not in valid_test_cases:
        raise ValueError(f"Invalid test case: {test_case}")
    
    if environment not in valid_environments:
        raise ValueError(f"Invalid environment: {environment}")
    
    # Validate additional_params is valid JSON
    try:
        json.loads(additional_params)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON in additional_params: {e}")

def setup_environment_variables(test_case, environment, sut_host, additional_params, actor):
    """Setup environment variables for the test run"""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    
    env_vars = {
        'TEST_CASE': test_case,
        'ENVIRONMENT': environment,
        'SUT_HOST': sut_host,
        'ADDITIONAL_PARAMS': additional_params,
        'TEST_TIMESTAMP': timestamp,
        'GITHUB_ACTOR': actor,
        'TEST_RUN_ID': f"{test_case}_{environment}_{timestamp}",
        'PYTHONPATH': str(Path.cwd())
    }
    
    # Write to GitHub Actions environment file
    github_env = os.getenv('GITHUB_ENV')
    if github_env:
        with open(github_env, 'a') as f:
            for key, value in env_vars.items():
                f.write(f"{key}={value}\n")
    
    # Also set in current process
    for key, value in env_vars.items():
        os.environ[key] = value
    
    return env_vars

def main():
    parser = argparse.ArgumentParser(description='Setup test environment')
    parser.add_argument('--test-case', required=True, help='Test case to run')
    parser.add_argument('--environment', required=True, help='Target environment')
    parser.add_argument('--sut-host', default='', help='SUT host override')
    parser.add_argument('--additional-params', default='{}', help='Additional parameters as JSON')
    parser.add_argument('--actor', required=True, help='GitHub actor')
    
    args = parser.parse_args()
    
    logger = setup_logging()
    logger.info("Starting environment setup...")
    
    try:
        # Load configuration
        config = load_config()
        logger.info("Configuration loaded successfully")
        
        # Validate inputs
        validate_inputs(args.test_case, args.environment, args.additional_params)
        logger.info("Input validation passed")
        
        # Setup directories
        setup_directories()
        logger.info("Directories created")
        
        # Determine SUT host
        sut_host = determine_sut_host(args.environment, args.sut_host, config)
        logger.info(f"SUT host determined: {sut_host}")
        
        # Setup environment variables
        env_vars = setup_environment_variables(
            args.test_case, args.environment, sut_host, 
            args.additional_params, args.actor
        )
        
        logger.info("Environment variables set:")
        for key, value in env_vars.items():
            if 'TOKEN' not in key and 'PASSWORD' not in key:
                logger.info(f"  {key}={value}")
        
        # Create run metadata
        metadata = {
            'test_case': args.test_case,
            'environment': args.environment,
            'sut_host': sut_host,
            'additional_params': json.loads(args.additional_params),
            'actor': args.actor,
            'timestamp': env_vars['TEST_TIMESTAMP'],
            'run_id': env_vars['TEST_RUN_ID'],
            'config': config
        }
        
        with open('test_results/run_metadata.json', 'w') as f:
            json.dump(metadata, f, indent=2)
        
        logger.info("Environment setup completed successfully")
        
    except Exception as e:
        logger.error(f"Environment setup failed: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
