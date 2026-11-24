#!/usr/bin/env python3
"""Find the WLED controller without internet, whatever state its network settings are in.

    python3 scripts/find_wled.py            # find it, fixing the wired link if needed
    python3 scripts/find_wled.py --look     # only look; change nothing

It first only looks: saved addresses, Bonjour, and every address on the local /24 of each
connected interface. If that finds nothing it repairs a wired link that has no DHCP server
(a cable straight from the Mac to the controller):

  * a controller with a fixed address on another subnet is heard over Bonjour, and the
    Mac's adapter is moved onto that subnet;
  * a controller waiting for DHCP is handed an address by a one-off responder here.

The responder never runs on a network that already has a DHCP server. Every change to the
Mac is printed with the command that undoes it. Standard library only.
"""
import argparse
import concurrent.futures
import ipaddress
import json
import re
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

RESCUE_MAC_SIDE = '192.168.77.1'      # the addresses the direct-cable setup has always used
RESCUE_CONTROLLER = '192.168.77.2'
KNOWN_CONTROLLERS = {'70:4b:ca:41:3f:fb': 'WLED-Gledopto'}
VJ_API = 'http://127.0.0.1:9120'
STATE_FILES = [Path.home() / 'Library/Application Support/VJ Native Development/native-state.json']
NOT_WIRED = re.compile(r'wi-?fi|bluetooth|thunderbolt bridge|iphone|tailscale|vpn', re.I)
IP_BOUND_IF = 25                       # <netinet/in.h> on macOS


def run(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def interfaces():
    """Connected network services: service, device, wired, manual, [(address, network)]."""
    found = []
    order = run('networksetup', '-listnetworkserviceorder')
    for service, port, device in re.findall(r'\(\d+\)\s+(.+)\n\(Hardware Port: (.+), Device: (\w+)\)', order):
        status = run('ifconfig', device)
        if 'status: active' not in status:
            continue
        addresses = []
        for address, mask in re.findall(r'inet (\S+) netmask (0x[0-9a-f]+)', status):
            addresses.append((address, ipaddress.ip_network(f'{address}/{bin(int(mask, 16)).count("1")}', strict=False)))
        found.append(dict(service=service, device=device, wired=not NOT_WIRED.search(port), addresses=addresses,
                          manual=run('networksetup', '-getinfo', service).startswith('Manual')))
    return found


def usable(interface):
    """Addresses a controller could share: private, and not self-assigned."""
    return [(a, n) for a, n in interface['addresses'] if ipaddress.ip_address(a).is_private and not a.startswith('169.254.')]


def probe(host, timeout=0.8):
    """WLED's own description of itself, or None."""
    try:
        with urllib.request.urlopen(f'http://{host}/json/info', timeout=timeout) as response:
            info = json.load(response)
        if 'ver' not in info or 'leds' not in info:
            return None
        return dict(host=host, name=info.get('name', 'WLED'), version=info['ver'], leds=info['leds'].get('count', 0),
                    mac=':'.join(re.findall('..', info.get('mac', ''))), port=info.get('udpport', 21324))
    except Exception:
        return None


def sweep(network):
    """Every address on the network's local /24 that answers as WLED."""
    if network.prefixlen < 24:
        network = ipaddress.ip_network(f'{network.network_address}/24', strict=False)

    def check(address):
        try:
            socket.create_connection((str(address), 80), 0.35).close()
        except OSError:
            return None
        return probe(str(address))
    with concurrent.futures.ThreadPoolExecutor(128) as pool:
        return [device for device in pool.map(check, network.hosts()) if device]


def bonjour(found_interfaces, seconds=3.0):
    """Addresses of controllers announcing _wled._tcp. Multicast reaches us even across subnets."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(('', 5353))
    except OSError as error:
        print(f'  Bonjour unavailable: {error}')
        return set()
    name = b''.join(bytes([len(part)]) + part for part in (b'_wled', b'_tcp', b'local')) + b'\0'
    query = struct.pack('>6H', 0, 0, 1, 0, 0, 0) + name + struct.pack('>2H', 12, 1)
    ours = set()
    for interface in found_interfaces:
        for address, _ in interface['addresses']:
            ours.add(address)
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton('224.0.0.251') + socket.inet_aton(address))
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
                sock.sendto(query, ('224.0.0.251', 5353))
            except OSError:
                pass
    heard, deadline = set(), time.time() + seconds
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            data, (source, _) = sock.recvfrom(9000)
        except OSError:
            break
        # A response (QR bit) naming the service came from a controller.
        if len(data) > 12 and data[2] & 0x80 and b'\x05_wled' in data and source not in ours:
            heard.add(source)
    sock.close()
    return heard


def set_manual(interface, address):
    """Give the Mac's adapter a fixed address. Returns the command that undoes it."""
    before = run('networksetup', '-getinfo', interface['service'])
    if before.startswith('Manual'):
        old = dict(re.findall(r'(IP address|Subnet mask): (\S+)', before))
        undo = f'networksetup -setmanual "{interface["service"]}" {old.get("IP address")} {old.get("Subnet mask")}'
    else:
        undo = f'networksetup -setdhcp "{interface["service"]}"'
    print(f'  Setting "{interface["service"]}" ({interface["device"]}) to {address} / 255.255.255.0')
    print(f'    undo with: {undo}')
    subprocess.run(['networksetup', '-setmanual', interface['service'], address, '255.255.255.0'], check=True)
    for _ in range(40):
        if f'inet {address} ' in run('ifconfig', interface['device']):
            return
        time.sleep(0.25)
    print('    the adapter did not take the address; continuing anyway')


def dhcp_parse(data):
    if len(data) < 244 or data[0] != 1 or data[236:240] != b'\x63\x82\x53\x63':
        return None
    options, at = {}, 240
    while at < len(data) and data[at] != 255:
        if data[at] == 0:
            at += 1
            continue
        options[data[at]] = data[at + 2:at + 2 + data[at + 1]]
        at += 2 + data[at + 1]
    return dict(kind=options.get(53, b'\0')[0], xid=data[4:8], chaddr=data[28:44],
                mac=':'.join(f'{b:02x}' for b in data[28:34]), name=options.get(12, b'').decode(errors='replace'))


def dhcp_reply(request, kind, offered, server):
    """OFFER (2) or ACK (5). The lease never expires, so the address lasts until power-off."""
    lease = b''.join([bytes([53, 1, kind]), bytes([54, 4]) + socket.inet_aton(server), bytes([51, 4]) + b'\xff' * 4,
                      bytes([1, 4]) + socket.inet_aton('255.255.255.0'), bytes([3, 4]) + socket.inet_aton(server), b'\xff'])
    packet = struct.pack('>4B4sHH', 2, 1, 6, 0, request['xid'], 0, 0x8000) + bytes(4) + socket.inet_aton(offered) \
        + socket.inet_aton(server) + bytes(4) + request['chaddr'] + bytes(192) + b'\x63\x82\x53\x63' + lease
    return packet.ljust(300, b'\0')


def dhcp_rescue(interface, server, offered, seconds, assume_yes):
    """Answer a controller that is asking for an address on this cable. Returns its MAC or None."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, socket.if_nametoindex(interface['device']))
    sock.bind(('', 67))
    print(f'  Listening on {interface["device"]} for a controller asking for an address (up to {seconds} s).')
    print('  If the light has been powered for a while, unplug and replug its power now.')
    declined, deadline = set(), time.time() + seconds
    try:
        while time.time() < deadline:
            sock.settimeout(max(0.05, deadline - time.time()))
            try:
                data, _ = sock.recvfrom(2048)
            except OSError:
                break
            request = dhcp_parse(data)
            if not request or request['kind'] not in (1, 3) or request['mac'] in declined:
                continue
            label = KNOWN_CONTROLLERS.get(request['mac']) or request['name'] or 'unknown device'
            if request['kind'] == 1:
                if request['mac'] not in KNOWN_CONTROLLERS and not assume_yes:
                    if input(f'  {label} ({request["mac"]}) is asking for an address. Give it {offered}? [y/N] ').strip().lower() != 'y':
                        declined.add(request['mac'])
                        continue
                print(f'  {label} ({request["mac"]}) asked for an address; offering {offered}')
                sock.sendto(dhcp_reply(request, 2, offered, server), ('255.255.255.255', 68))
            else:
                sock.sendto(dhcp_reply(request, 5, offered, server), ('255.255.255.255', 68))
                print(f'  {label} accepted {offered}')
                return request['mac']
    finally:
        sock.close()
    return None


def wait_for(host, seconds=12):
    deadline = time.time() + seconds
    while time.time() < deadline:
        device = probe(host)
        if device:
            return device
        time.sleep(0.5)
    return None


def make_static(device, gateway):
    """Save the controller's current address as fixed, so it needs no DHCP next time."""
    quad = lambda text: [int(part) for part in text.split('.')]
    body = json.dumps({'nw': {'ins': [{'ip': quad(device['host']), 'gw': quad(gateway), 'sn': [255, 255, 255, 0]}]}}).encode()
    request = urllib.request.Request(f'http://{device["host"]}/json/cfg', data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=4) as response:
        response.read()
    print(f'  Saved {device["host"]} as the controller\'s fixed address. It applies from its next restart.')


def report(devices, apply):
    print()
    for device in devices:
        print(f'FOUND  {device["name"]} at {device["host"]}  ·  {device["leds"]} LEDs  ·  WLED {device["version"]}'
              f'  ·  UDP {device["port"]}  ·  {device["mac"]}')
    device = devices[0]
    print(f'\nController page: http://{device["host"]}/')
    if not apply:
        return
    try:
        body = json.dumps({'action': 'set', 'host': device['host'], 'port': device['port']}).encode()
        request = urllib.request.Request(VJ_API + '/api/v1/fixture-output', data=body, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=4) as response:
            response.read()
        print(f'VJ now points at {device["host"]}:{device["port"]}. Press Start WLED on the LEDs page.')
    except Exception as error:
        detail = error.read().decode(errors='replace') if hasattr(error, 'read') else str(error)
        print(f'VJ was not updated ({detail.strip() or error}).')
        print(f'In VJ: LEDs page, stop WLED if it is running, then enter {device["host"]} port {device["port"]} or use Scan for WLED.')


def look(found_interfaces):
    hosts = [RESCUE_CONTROLLER]
    for path in STATE_FILES + sorted((Path.home() / 'Projection3000/VJ/Projects').glob('.local/*/native-state.json')):
        try:
            hosts += re.findall(r'"host"\s*:\s*"([^"]+)"', path.read_text())
        except OSError:
            pass
    hosts = [host for host in dict.fromkeys(hosts) if host not in ('127.0.0.1', 'localhost', '')]
    print(f'Trying saved addresses: {", ".join(hosts)}')
    devices = [device for device in map(probe, hosts) if device]
    print('Listening for Bonjour announcements…')
    heard = bonjour(found_interfaces)
    devices += [device for device in map(probe, heard) if device]
    unreachable = sorted(heard - {device['host'] for device in devices})
    for interface in found_interfaces:
        for address, network in usable(interface):
            print(f'Checking every address near {address} on {interface["device"]}…')
            devices += sweep(network)
    return list({device['host']: device for device in devices}.values()), unreachable


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--look', action='store_true', help='only look; never change the Mac or hand out an address')
    parser.add_argument('--yes', action='store_true', help='answer yes to every question')
    parser.add_argument('--no-vj', action='store_true', help='do not point VJ at the controller')
    parser.add_argument('--wait', type=int, default=75, help='seconds to wait for a controller to ask for an address')
    args = parser.parse_args()
    found = interfaces()
    if not found:
        sys.exit('No network adapter is connected. Plug in the Ethernet adapter and the cable to the light.')
    for interface in found:
        addresses = ', '.join(address for address, _ in interface['addresses']) or 'no address'
        print(f'{interface["device"]:6} {interface["service"]}: {addresses}{" (self-assigned)" if addresses.startswith("169.254.") else ""}')
    devices, unreachable = look(found)
    if devices:
        return report(devices, not args.no_vj)
    wired = [interface for interface in found if interface['wired']]
    if args.look or not wired:
        print('\nNothing found.' + ('' if wired else ' No wired adapter is connected, so there is no link to repair.'))
        for host in unreachable:
            print(f'A controller announced itself at {host}, which this Mac cannot reach from its current addresses.')
        sys.exit(1)

    # A controller with a fixed address on a subnet the Mac is not on.
    for host in unreachable:
        interface = next((i for i in wired if not usable(i)), wired[0])
        print(f'\nA controller announced itself at {host}, outside this Mac\'s networks.')
        prefix, last = host.rsplit('.', 1)
        set_manual(interface, f'{prefix}.{"254" if last == "1" else "1"}')
        device = wait_for(host)
        if device:
            return report([device], not args.no_vj)

    # A wired link with no DHCP server: a fixed-address adapter, or one that had to self-assign.
    for interface in wired:
        if usable(interface) and not interface['manual']:
            continue    # this network has a DHCP server; never answer DHCP here
        print(f'\nRepairing the direct link on {interface["device"]} ({interface["service"]}).')
        if usable(interface):
            server = usable(interface)[0][0]
        else:
            server = RESCUE_MAC_SIDE
            set_manual(interface, server)
            devices = sweep(ipaddress.ip_network(server + '/24', strict=False))
            if devices:
                return report(devices, not args.no_vj)
        prefix, last = server.rsplit('.', 1)
        offered = f'{prefix}.{"3" if last == "2" else "2"}'
        if dhcp_rescue(interface, server, offered, args.wait, args.yes):
            device = wait_for(offered)
            if device:
                report([device], not args.no_vj)
                if args.yes or input(f'\nSave {offered} as the controller\'s fixed address so this is not needed again? [Y/n] ').strip().lower() != 'n':
                    try:
                        make_static(device, server)
                    except Exception as error:
                        print(f'  Could not save it ({error}). Set it by hand at http://{offered}/ under Config, WiFi Setup, Ethernet/Static IP.')
                return
            print(f'  It took the address but is not answering at http://{offered}/ yet. Run this again in a few seconds.')
            sys.exit(1)

    print('\nStill nothing. Check, in order:')
    print('  1. The light has power and the Ethernet link lights are on at both ends.')
    print('  2. The cable goes to the Ethernet adapter listed above.')
    print('  3. Power-cycle the light and run this again; it only asks for an address for a while after starting.')
    print('  4. If the controller was factory-reset its Ethernet port is off. Join its "WLED-AP" Wi-Fi network')
    print('     (default password wled1234), open http://4.3.2.1/ and re-enable Ethernet under Config, WiFi Setup.')
    sys.exit(1)


if __name__ == '__main__':
    main()
