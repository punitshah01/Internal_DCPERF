#!/usr/bin/env python3
"""
SUT (System Under Test) Management Script with Credential Support
"""

import os
import sys
import yaml
import json
import argparse
import requests
import subprocess
import paramiko
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional
from tabulate import tabulate

class SUTManager:
    def __init__(self, config_file: str = "config/suts.yaml"):
        self.config_file = Path(config_file)
        self.config_file.parent.mkdir(exist_ok=True)
        self.suts = self.load_suts()
    
    def load_suts(self) -> Dict[str, Any]:
        """Load SUT configuration from YAML file"""
        if self.config_file.exists():
            with open(self.config_file, 'r') as f:
                data = yaml.safe_load(f) or {}
                return data.get('suts', {})
        return {}
    
    def save_suts(self):
        """Save SUT configuration to YAML file"""
        config_data = {
            'suts': self.suts,
            'last_updated': datetime.now().isoformat(),
            'version': '1.0'
        }
        
        with open(self.config_file, 'w') as f:
            yaml.dump(config_data, f, default_flow_style=False, indent=2)
        
        print(f"✅ SUT configuration saved to {self.config_file}")
    
    def add_sut(self, name: str, host: str, port: str = "22", username: str = "", 
                auth_method: str = "password", description: str = "", 
                cpu_family: str = "Generic", os_type: str = "Linux", 
                labels: str = "self-hosted,linux", sudo_required: bool = False) -> bool:
        """Add a new SUT with credentials"""
        if name in self.suts:
            print(f"❌ SUT '{name}' already exists. Use update_sut to modify it.")
            return False
        
        # Validate inputs
        if not name or not host:
            print("❌ SUT name and host are required")
            return False
        
        if not username:
            print("❌ Username is required for SUT access")
            return False
        
        # Test basic connectivity
        if not self.test_sut_connectivity(host):
            print(f"⚠️  Warning: Could not ping {host}")
        
        # Generate secret name for password
        secret_name = f"SUT_PASSWORD_{name.upper().replace('-', '_')}"
        
        # Add SUT configuration
        sut_config = {
            'name': name,
            'host': host,
            'port': int(port),
            'username': username,
            'auth_method': auth_method,
            'password_secret': secret_name,  # Reference to GitHub secret
            'description': description,
            'cpu_family': cpu_family,
            'os_type': os_type,
            'labels': [label.strip() for label in labels.split(',')],
            'sudo_required': sudo_required,
            'status': 'active',
            'created_at': datetime.now().isoformat(),
            'updated_at': datetime.now().isoformat(),
            'created_by': os.getenv('GITHUB_ACTOR', 'unknown'),
            'ssh_key_path': f".ssh-keys/{name}_id_rsa",  # Path for SSH key if used
        }
        
        self.suts[name] = sut_config
        self.save_suts()
        
        print(f"✅ SUT '{name}' added successfully")
        print(f"   Host: {host}:{port}")
        print(f"   Username: {username}")
        print(f"   Auth Method: {auth_method}")
        print(f"   CPU Family: {cpu_family}")
        print(f"   OS Type: {os_type}")
        print(f"   Sudo Required: {sudo_required}")
        print(f"   Password Secret: {secret_name}")
        print(f"   Labels: {labels}")
        
        return True
    
    def test_ssh_connection(self, name: str) -> bool:
        """Test SSH connection to a SUT"""
        if name not in self.suts:
            print(f"❌ SUT '{name}' not found")
            return False
        
        sut = self.suts[name]
        if sut.get('status') == 'deleted':
            print(f"❌ Cannot test deleted SUT '{name}'")
            return False
        
        host = sut['host']
        port = sut.get('port', 22)
        username = sut['username']
        auth_method = sut.get('auth_method', 'password')
        
        print(f"🔌 Testing SSH connection to {username}@{host}:{port}...")
        
        try:
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            
            # Try different authentication methods
            if auth_method in ['password', 'both']:
                # Try to get password from environment (GitHub secret)
                secret_name = sut.get('password_secret', '')
                password = os.getenv(secret_name.replace('SUT_PASSWORD_', 'SUT_PASSWORD_'))
                
                if password:
                    print(f"🔐 Attempting password authentication...")
                    ssh.connect(host, port=port, username=username, password=password, timeout=10)
                    print(f"✅ SSH password authentication successful!")
                else:
                    print(f"⚠️  Password not available in environment (secret: {secret_name})")
            
            elif auth_method in ['ssh_key', 'both']:
                # Try SSH key authentication
                key_path = sut.get('ssh_key_path', f".ssh-keys/{name}_id_rsa")
                if os.path.exists(key_path):
                    print(f"🔑 Attempting SSH key authentication...")
                    ssh.connect(host, port=port, username=username, key_filename=key_path, timeout=10)
                    print(f"✅ SSH key authentication successful!")
                else:
                    print(f"⚠️  SSH key not found: {key_path}")
            
            # Test basic command execution
            stdin, stdout, stderr = ssh.exec_command('whoami && hostname && date')
            output = stdout.read().decode().strip()
            error = stderr.read().decode().strip()
            
            if output:
                print(f"📋 Remote system info:")
                for line in output.split('\n'):
                    print(f"   {line}")
            
            if error:
                print(f"⚠️  Command stderr: {error}")
            
            # Test sudo if required
            if sut.get('sudo_required', False):
                print(f"🔧 Testing sudo access...")
                stdin, stdout, stderr = ssh.exec_command('sudo -n whoami')
                sudo_output = stdout.read().decode().strip()
                sudo_error = stderr.read().decode().strip()
                
                if sudo_output == 'root':
                    print(f"✅ Sudo access confirmed")
                else:
                    print(f"⚠️  Sudo may require password: {sudo_error}")
            
            ssh.close()
            return True
            
        except paramiko.AuthenticationException:
            print(f"❌ SSH authentication failed")
            return False
        except paramiko.SSHException as e:
            print(f"❌ SSH connection error: {e}")
            return False
        except Exception as e:
            print(f"❌ Connection error: {e}")
            return False
    
    def delete_sut(self, name: str) -> bool:
        """Delete a SUT"""
        if name not in self.suts:
            print(f"❌ SUT '{name}' not found")
            return False
        
        # Archive the SUT instead of deleting
        self.suts[name]['status'] = 'deleted'
        self.suts[name]['deleted_at'] = datetime.now().isoformat()
        self.suts[name]['deleted_by'] = os.getenv('GITHUB_ACTOR', 'unknown')
        
        self.save_suts()
        
        print(f"✅ SUT '{name}' marked as deleted")
        print("   Note: SUT configuration is archived, not permanently deleted")
        print(f"   Remember to remove the associated secret: {self.suts[name].get('password_secret', 'N/A')}")
        
        return True
    
    def update_sut(self, name: str, **kwargs) -> bool:
        """Update an existing SUT"""
        if name not in self.suts:
            print(f"❌ SUT '{name}' not found")
            return False
        
        if self.suts[name].get('status') == 'deleted':
            print(f"❌ Cannot update deleted SUT '{name}'")
            return False
        
        # Update fields
        updatable_fields = ['host', 'port', 'username', 'auth_method', 'description', 
                           'cpu_family', 'os_type', 'labels', 'sudo_required']
        updated_fields = []
        
        for field, value in kwargs.items():
            if field in updatable_fields and value:
                if field == 'labels':
                    value = [label.strip() for label in value.split(',')]
                elif field == 'port':
                    value = int(value)
                elif field == 'sudo_required':
                    value = str(value).lower() in ['true', '1', 'yes']
                
                old_value = self.suts[name].get(field, 'N/A')
                self.suts[name][field] = value
                updated_fields.append(f"{field}: {old_value} → {value}")
        
        if updated_fields:
            self.suts[name]['updated_at'] = datetime.now().isoformat()
            self.suts[name]['updated_by'] = os.getenv('GITHUB_ACTOR', 'unknown')
            self.save_suts()
            
            print(f"✅ SUT '{name}' updated successfully")
            for field in updated_fields:
                print(f"   {field}")
        else:
            print(f"ℹ️  No changes made to SUT '{name}'")
        
        return True
    
    def list_suts(self, include_deleted: bool = False) -> List[Dict[str, Any]]:
        """List all SUTs with credential info"""
        active_suts = []
        deleted_suts = []
        
        for name, config in self.suts.items():
            if config.get('status') == 'deleted':
                deleted_suts.append(config)
            else:
                active_suts.append(config)
        
        # Display active SUTs
        if active_suts:
            print("\n🖥️  Active SUTs:")
            print("=" * 100)
            
            table_data = []
            for sut in active_suts:
                table_data.append([
                    sut['name'],
                    f"{sut['host']}:{sut.get('port', 22)}",
                    sut.get('username', 'N/A'),
                    sut.get('auth_method', 'password'),
                    sut['cpu_family'],
                    sut['os_type'],
                    '✓' if sut.get('sudo_required', False) else '✗',
                    sut.get('description', '')[:20] + ('...' if len(sut.get('description', '')) > 20 else '')
                ])
            
            headers = ['Name', 'Host:Port', 'Username', 'Auth', 'CPU Family', 'OS', 'Sudo', 'Description']
            print(tabulate(table_data, headers=headers, tablefmt='grid'))
        else:
            print("\n📭 No active SUTs found")
        
        # Display deleted SUTs if requested
        if include_deleted and deleted_suts:
            print(f"\n🗑️  Deleted SUTs ({len(deleted_suts)}):")
            print("=" * 50)
            for sut in deleted_suts:
                print(f"   {sut['name']} (deleted on {sut.get('deleted_at', 'unknown')})")
        
        print(f"\nTotal: {len(active_suts)} active, {len(deleted_suts)} deleted")
        
        return active_suts
    
    def test_sut_connectivity(self, host: str) -> bool:
        """Test basic connectivity to a SUT"""
        try:
            result = subprocess.run(['ping', '-c', '1', '-W', '5', host], 
                                  capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                print(f"✅ Ping to {host}: SUCCESS")
                return True
            else:
                print(f"❌ Ping to {host}: FAILED")
                return False
                
        except subprocess.TimeoutExpired:
            print(f"⏰ Ping to {host}: TIMEOUT")
            return False
        except Exception as e:
            print(f"❌ Ping to {host}: ERROR - {e}")
            return False
    
    def test_connectivity(self, name: str) -> bool:
        """Test connectivity to a specific SUT"""
        if name not in self.suts:
            print(f"❌ SUT '{name}' not found")
            return False
        
        sut = self.suts[name]
        if sut.get('status') == 'deleted':
            print(f"❌ Cannot test deleted SUT '{name}'")
            return False
        
        print(f"🔍 Testing connectivity to SUT '{name}' ({sut['host']})...")
        return self.test_sut_connectivity(sut['host'])

def main():
    parser = argparse.ArgumentParser(description='SUT Management Tool with Credentials')
    parser.add_argument('--action', required=True, 
                       choices=['add_sut', 'delete_sut', 'list_suts', 'update_sut', 
                               'test_connectivity', 'test_ssh_connection'],
                       help='Action to perform')
    parser.add_argument('--sut-name', help='SUT name')
    parser.add_argument('--sut-host', help='SUT host/IP address')
    parser.add_argument('--sut-port', default='22', help='SSH port')
    parser.add_argument('--sut-username', help='SSH username')
    parser.add_argument('--auth-method', default='password', help='Authentication method')
    parser.add_argument('--sut-description', default='', help='SUT description')
    parser.add_argument('--cpu-family', default='Generic', help='CPU family')
    parser.add_argument('--os-type', default='Linux', help='Operating system type')
    parser.add_argument('--labels', default='self-hosted,linux', help='Runner labels')
    parser.add_argument('--sudo-required', default='false', help='Sudo required')
    parser.add_argument('--github-token', help='GitHub token')
    parser.add_argument('--repo', help='GitHub repository')
    parser.add_argument('--include-deleted', action='store_true', help='Include deleted SUTs')
    
    args = parser.parse_args()
    
    # Initialize SUT manager
    sut_manager = SUTManager()
    
    try:
        if args.action == 'add_sut':
            if not args.sut_name or not args.sut_host or not args.sut_username:
                print("❌ SUT name, host, and username are required for add_sut action")
                sys.exit(1)
            
            sudo_required = str(args.sudo_required).lower() in ['true', '1', 'yes']
            
            success = sut_manager.add_sut(
                name=args.sut_name,
                host=args.sut_host,
                port=args.sut_port,
                username=args.sut_username,
                auth_method=args.auth_method,
                description=args.sut_description,
                cpu_family=args.cpu_family,
                os_type=args.os_type,
                labels=args.labels,
                sudo_required=sudo_required
            )
            sys.exit(0 if success else 1)
        
        elif args.action == 'test_ssh_connection':
            if not args.sut_name:
                print("❌ SUT name is required for test_ssh_connection action")
                sys.exit(1)
            
            success = sut_manager.test_ssh_connection(args.sut_name)
            sys.exit(0 if success else 1)
        
        # ... rest of the actions remain the same ...
        
        elif args.action == 'delete_sut':
            if not args.sut_name:
                print("❌ SUT name is required for delete_sut action")
                sys.exit(1)
            
            success = sut_manager.delete_sut(args.sut_name)
            sys.exit(0 if success else 1)
        
        elif args.action == 'list_suts':
            sut_manager.list_suts(include_deleted=args.include_deleted)
        
        elif args.action == 'test_connectivity':
            if not args.sut_name:
                print("❌ SUT name is required for test_connectivity action")
                sys.exit(1)
            
            success = sut_manager.test_connectivity(args.sut_name)
            sys.exit(0 if success else 1)
    
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
