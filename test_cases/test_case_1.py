#!/usr/bin/env python3
"""
Test Case 1: Basic Connectivity Test
"""

import asyncio
import aiohttp
import socket
import time
from typing import Dict, Any, List
import logging

async def check_http_connectivity(host: str, timeout: int = 30) -> Dict[str, Any]:
    """Check HTTP connectivity to host"""
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.get(f"http://{host}") as response:
                return {
                    'success': True,
                    'status_code': response.status,
                    'response_time': time.time()
                }
    except Exception as e:
        return {
            'success': False,
            'error': str(e),
            'response_time': None
        }

async def check_https_connectivity(host: str, timeout: int = 30) -> Dict[str, Any]:
    """Check HTTPS connectivity to host"""
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.get(f"https://{host}") as response:
                return {
                    'success': True,
                    'status_code': response.status,
                    'response_time': time.time()
                }
    except Exception as e:
        return {
            'success': False,
            'error': str(e),
            'response_time': None
        }

def check_dns_resolution(host: str) -> Dict[str, Any]:
    """Check DNS resolution for host"""
    try:
        ip_address = socket.gethostbyname(host)
        return {
            'success': True,
            'ip_address': ip_address
        }
    except Exception as e:
        return {
            'success': False,
            'error': str(e),
            'ip_address': None
        }

async def run_async(sut_host: str, environment: str, additional_params: Dict[str, Any], 
                   config: Dict[str, Any], logger: logging.Logger) -> Dict[str, Any]:
    """
    Async version of test case 1
    """
    logger.info(f"Starting Test Case 1: Basic Connectivity Test")
    logger.info(f"Target: {sut_host}, Environment: {environment}")
    
    test_results = {
        'steps': [],
        'overall_status': 'UNKNOWN',
        'details': {}
    }
    
    logs = []
    
    try:
        # Step 1: DNS Resolution
        logger.info("Step 1: Testing DNS resolution...")
        dns_result = check_dns_resolution(sut_host)
        
        step_1 = {
            'step': 'DNS Resolution',
            'status': 'PASSED' if dns_result['success'] else 'FAILED',
            'details': dns_result
        }
        test_results['steps'].append(step_1)
        logs.append(f"DNS Resolution: {'PASSED' if dns_result['success'] else 'FAILED'}")
        
        if dns_result['success']:
            logger.info(f"✅ DNS Resolution: PASSED - IP: {dns_result['ip_address']}")
        else:
            logger.error(f"❌ DNS Resolution: FAILED - {dns_result['error']}")
        
        # Step 2: HTTP Connectivity
        logger.info("Step 2: Testing HTTP connectivity...")
        http_result = await check_http_connectivity(sut_host, config.get('timeout', 30))
        
        step_2 = {
            'step': 'HTTP Connectivity',
            'status': 'PASSED' if http_result['success'] else 'FAILED',
            'details': http_result
        }
        test_results['steps'].append(step_2)
        logs.append(f"HTTP Connectivity: {'PASSED' if http_result['success'] else 'FAILED'}")
        
        if http_result['success']:
            logger.info(f"✅ HTTP Connectivity: PASSED - Status: {http_result['status_code']}")
        else:
            logger.error(f"❌ HTTP Connectivity: FAILED - {http_result['error']}")
        
        # Step 3: HTTPS Connectivity
        logger.info("Step 3: Testing HTTPS connectivity...")
        https_result = await check_https_connectivity(sut_host, config.get('timeout', 30))
        
        step_3 = {
            'step': 'HTTPS Connectivity',
            'status': 'PASSED' if https_result['success'] else 'FAILED',
            'details': https_result
        }
        test_results['steps'].append(step_3)
        logs.append(f"HTTPS Connectivity: {'PASSED' if https_result['success'] else 'FAILED'}")
        
        if https_result['success']:
            logger.info(f"✅ HTTPS Connectivity: PASSED - Status: {https_result['status_code']}")
        else:
            logger.error(f"❌ HTTPS Connectivity: FAILED - {https_result['error']}")
        
        # Determine overall status
        all_passed = all(step['status'] == 'PASSED' for step in test_results['steps'])
        test_results['overall_status'] = 'PASSED' if all_passed else 'FAILED'
        
        # Additional details
        test_results['details'] = {
            'sut_host': sut_host,
            'environment': environment,
            'total_steps': len(test_results['steps']),
            'passed_steps': sum(1 for step in test_results['steps'] if step['status'] == 'PASSED'),
            'failed_steps': sum(1 for step in test_results['steps'] if step['status'] == 'FAILED')
        }
        
        message = f"Test Case 1 completed: {test_results['overall_status']}"
        logger.info(f"🎉 {message}")
        
        return {
            'status': test_results['overall_status'],
            'message': message,
            'details': test_results,
            'logs': logs
        }
        
    except Exception as e:
        error_msg = f"Test Case 1 failed with exception: {str(e)}"
        logger.error(f"💥 {error_msg}")
        
        return {
            'status': 'ERROR',
            'message': error_msg,
            'details': test_results,
            'logs': logs + [f"Exception: {str(e)}"]
        }

def run(sut_host: str, environment: str, additional_params: Dict[str, Any], 
        config: Dict[str, Any], logger: logging.Logger) -> Dict[str, Any]:
    """
    Synchronous version of test case 1 (wrapper for async version)
    """
    return asyncio.run(run_async(sut_host, environment, additional_params, config, logger))
