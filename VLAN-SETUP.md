# VLAN Setup on Raspberry Pi

A practical guide for setting up VLANs on a Raspberry Pi 3, 4, or 5 to use with service-discovery-helper at LAN parties.

## Prerequisites

- Raspberry Pi 3, 4, or 5 running Raspberry Pi OS or Debian 12 (Bookworm) / Debian 13 (Trixie)
- A managed switch with VLAN trunk port support
- Ethernet connection (built-in or USB adapter)

> **Pi 3/4** have a single Ethernet port — you'll run multiple VLANs as sub-interfaces on one trunk port.
> **Pi 5** also has one port, but USB 3.0 Gigabit adapters work well for a second physical interface.

## 1. Install VLAN Support

```bash
sudo apt update
sudo apt install vlan
sudo modprobe 8021q
echo "8021q" | sudo tee /etc/modules-load.d/8021q.conf
```

This loads the 802.1Q kernel module and makes it persist across reboots.

## 2. Identify Your Interface

```bash
ip link show
```

The interface name depends on your OS version:

| OS Version | Interface Name |
|------------|---------------|
| Raspberry Pi OS (Bullseye / older) | `eth0` |
| Raspberry Pi OS (Bookworm / Trixie) | `end0` |
| Debian 12/13 (standard install) | `eth0` or `enp...` |
| USB Gigabit adapter | `eth1`, `enx...` |

In this guide we use `eth0` — **replace with `end0`** if you're on Bookworm or Trixie.

## 3. Configure VLANs

### Option A: NetworkManager (Raspberry Pi OS Desktop)

```bash
# Create VLAN 10
sudo nmcli connection add type vlan \
  con-name vlan10 \
  dev eth0 \
  id 10 \
  ipv4.method manual \
  ipv4.addresses 10.0.10.1/24

# Create VLAN 20
sudo nmcli connection add type vlan \
  con-name vlan20 \
  dev eth0 \
  id 20 \
  ipv4.method manual \
  ipv4.addresses 10.0.20.1/24

# Bring them up
sudo nmcli connection up vlan10
sudo nmcli connection up vlan20
```

### Option B: /etc/network/interfaces (Raspberry Pi OS Lite / headless)

Edit `/etc/network/interfaces`:

```
# Trunk port (untagged / native VLAN)
auto eth0
iface eth0 inet dhcp

# VLAN 10
auto eth0.10
iface eth0.10 inet static
    address 10.0.10.1/24
    vlan-raw-device eth0

# VLAN 20
auto eth0.20
iface eth0.20 inet static
    address 10.0.20.1/24
    vlan-raw-device eth0

# VLAN 30
auto eth0.30
iface eth0.30 inet static
    address 10.0.30.1/24
    vlan-raw-device eth0
```

Then apply:

```bash
sudo systemctl restart networking
```

### Option C: systemd-networkd

Create `/etc/systemd/network/10-eth0.network`:

```ini
[Match]
Name=eth0

[Network]
DHCP=yes
VLAN=vlan10
VLAN=vlan20
```

Create `/etc/systemd/network/20-vlan10.netdev`:

```ini
[NetDev]
Name=vlan10
Kind=vlan

[VLAN]
Id=10
```

Create `/etc/systemd/network/20-vlan10.network`:

```ini
[Match]
Name=vlan10

[Network]
Address=10.0.10.1/24
```

Repeat for each VLAN, then:

```bash
sudo systemctl enable --now systemd-networkd
sudo systemctl restart systemd-networkd
```

## 4. Verify

```bash
# Check interfaces are up with correct IPs
ip -br addr show

# Expected output:
# eth0             UP    192.168.1.100/24
# eth0.10@eth0     UP    10.0.10.1/24
# eth0.20@eth0     UP    10.0.20.1/24
# eth0.30@eth0     UP    10.0.30.1/24
```

## 5. Switch Configuration

Your managed switch must be configured to send tagged VLAN traffic to the Pi's port. The exact steps vary by vendor, but the concept is:

1. **Create VLANs** 10, 20, 30 (matching your sub-interfaces) on the switch
2. **Set the Pi's port as a trunk** — allow VLANs 10, 20, 30 tagged
3. **Set player ports as access ports** — each port assigned to one VLAN untagged
4. **Set a native/untagged VLAN** on the trunk if the Pi also needs management access

Example layout:

```
Switch Port 1 (Trunk → Pi):     VLAN 10, 20, 30 tagged
Switch Ports 2-12 (Players):    VLAN 10 untagged (access)
Switch Ports 13-24 (Players):   VLAN 20 untagged (access)
Switch Ports 25-36 (Players):   VLAN 30 untagged (access)
```

## 6. Run service-discovery-helper

Once VLANs are up, SDH forwards broadcast traffic between them:

```bash
# Using the interactive installer
sudo ./deploy/install.sh

# Or run directly with the VLAN interfaces
sudo sdh-proxy -c /etc/sdh-proxy.conf
```

Example config (`/etc/sdh-proxy.conf`):

```ini
[interfaces]
eth0.10
eth0.20
eth0.30

[ports]
27015-27020
27036
6112

[settings]
rate_limit = yes
rate_limit_timeout = 1000
```

## Tips

- **Performance**: A Pi 4/5 easily handles broadcast forwarding for 200+ clients. A Pi 3 works fine for smaller events.
- **USB Ethernet**: If you prefer physical separation over sub-interfaces, a USB 3.0 Gigabit adapter on a Pi 4/5 gives you a second interface. Plug each into a different VLAN access port — no trunk needed.
- **Headless setup**: Configure VLANs before the event. Test with `ping` between VLANs from the Pi to confirm connectivity.
- **Firewall**: If `ufw` or `iptables` is active, ensure UDP traffic on your game ports is allowed on the VLAN interfaces.
- **IP forwarding**: SDH works at Layer 2 (rebroadcasts packets), so you do **not** need `net.ipv4.ip_forward=1` for SDH itself. Only enable it if you also want the Pi to route between VLANs.
