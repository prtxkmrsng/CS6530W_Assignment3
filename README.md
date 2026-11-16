# CS6530W Assignment 3 — Site-to-Site IPsec/IKEv2 with strongSwan

> **Configure → Observe → Validate → Break → Diagnose → Restore**

This project builds a reproducible "two offices connected over the Internet" lab using two Ubuntu Server virtual machines (fully optimized for **VMware Workstation Pro**, VirtualBox, and KVM), protects the traffic between the offices with **IPsec (IKEv2, tunnel-mode ESP)**, and automatically gathers the required evidence: packet captures, strongSwan status, Linux XFRM state, and four deliberate-failure diagnoses.

Everything uses real **strongSwan** and the Linux **XFRM** framework.

---

## 1. Lab Architecture & Topology

```
   SITE A  (VM 1)                                             SITE B  (VM 2)
 ┌─────────────────────────────┐                         ┌─────────────────────────────┐
 │ hostA namespace             │                         │            hostB namespace  │
 │ 10.1.0.10/24                │                         │                10.2.0.10/24 │
 │      │                      │                         │                      │      │
 │  vethA-h ── vethA-gw        │                         │        vethB-gw ── vethB-h  │
 │            10.1.0.1         │                         │         10.2.0.1            │
 │      GATEWAY A (strongSwan) │    "untrusted transit"  │ GATEWAY B (strongSwan)      │
 │      WAN 192.0.2.1 ─────────┼─────────────────────────┼───────── WAN 192.0.2.2      │
 └─────────────────────────────┘   plaintext before IPsec └─────────────────────────────┘
                                   ESP after IPsec
```

| Item | Site A (VM 1) | Site B (VM 2) |
|---|---|---|
| Protected host (namespace) | `hostA` `10.1.0.10/24` | `hostB` `10.2.0.10/24` |
| Gateway protected-side | `vethA-gw` `10.1.0.1/24` | `vethB-gw` `10.2.0.1/24` |
| Gateway transit / WAN | `192.0.2.1/24` | `192.0.2.2/24` |
| Protected subnet | `10.1.0.0/24` | `10.2.0.0/24` |
| IKE proposal | `aes256-sha256-modp2048!` | `aes256-sha256-modp2048!` |
| ESP proposal | `aes256-sha256!` | `aes256-sha256!` |
| Authentication | PSK = `<ROLLNO>CS6530W-IPsec-A3-2026` | same |

The goal: traffic **hostA ↔ hostB** must cross the transit link **only as encrypted ESP**, while remaining plaintext on each site's protected internal side.

---

## 2. Virtual Machine Setup Guide (VMware & VirtualBox)

### VMware Workstation Pro:
1. **Network Adapter 1**: Set to **NAT** (Internet access for `apt`).
2. **Network Adapter 2**: Add Network Adapter → Set to **LAN Segment** (name: `transit`) or **Host-only** (VMnet1).
3. Ensure **Connected** and **Connect at power on** are both checked on both VMs.

### VirtualBox:
1. **Adapter 1**: Attached to **NAT**.
2. **Adapter 2**: Attached to **Internal Network** (name: `transit`).
3. Ensure **Cable Connected** is checked on both VMs.

> **Auto-Detection:** The setup script (`01_setup_gateway.sh`) automatically detects secondary interfaces across hypervisors (`ens34`/`ens38` on VMware, `enp0s8` on VirtualBox), configures transit IPs, applies persistent Netplan configs, and manages AppArmor permissions.

---

## 3. Quick Start (Step-by-Step)

```bash
# 1) On BOTH VMs: clone/copy the repo to $HOME, then set your roll number:
cp config.env.example config.env
nano config.env                         # Change ROLLNO="CS24M001" to your UPPERCASE roll number
chmod +x scripts/*.sh

# 2) One-time gateway setup:
sudo scripts/01_setup_gateway.sh A      # On VM 1 (Gateway A)
sudo scripts/01_setup_gateway.sh B      # On VM 2 (Gateway B)

# 3) Verify lab health & VMware connectivity:
sudo scripts/diagnose.sh                # Checks transit link, namespace, services, XFRM

# 4) Run the evidence tests (or use the interactive menu: sudo scripts/run_all.sh):
sudo scripts/tr1_plaintext.sh           # TR-1: Plaintext baseline
sudo scripts/tr2_ike_capture.sh         # TR-2: Fresh IKEv2 establishment capture
sudo scripts/tr3_protected.sh           # TR-3: Protected flow & SPI correlation
sudo scripts/fault.sh ike               # TR-4: IKE proposal fault (run collect_peer.sh TR-4 on VM 2)
sudo scripts/fault.sh psk               # TR-5: PSK fault
sudo scripts/fault.sh esp               # TR-6: ESP proposal fault
sudo scripts/fault.sh ts                # TR-7: Traffic selector fault
sudo scripts/tr8_boundary.sh 40         # TR-8: On VM 2 FIRST (starts 40s capture)...
sudo scripts/tr8_boundary.sh            # ...then on VM 1 within those 40s

# 5) Package your submission:
scripts/package.sh                      # Generates ../<ROLLNO>_CS6530W_Assignment3.zip
```

---

## 4. Requirement ↔ Script ↔ Evidence Map

| Test | Objective | Script | Output Evidence |
|---|---|---|---|
| **TR-1** | Plaintext baseline | `tr1_plaintext.sh` | `evidence/TR-1/tr1_plaintext.pcap`, `TR-1_gwA.log` |
| **TR-2** | Fresh IKEv2 handshake | `tr2_ike_capture.sh` | `evidence/TR-2/tr2_ike_establish.pcap`, `TR-2_gwA.log` |
| **TR-3** | Protected flow + SPI correlation | `tr3_protected.sh` | `evidence/TR-3/tr3_protected.pcap`, `TR-3_gwA.log` |
| **TR-4** | IKE proposal mismatch | `fault.sh ike` | `evidence/TR-4/tr4_fault.pcap`, logs A/B |
| **TR-5** | PSK mismatch | `fault.sh psk` | `evidence/TR-5/tr5_fault.pcap`, logs A/B |
| **TR-6** | ESP proposal mismatch | `fault.sh esp` | `evidence/TR-6/tr6_fault.pcap`, logs A/B |
| **TR-7** | Traffic selector mismatch | `fault.sh ts` | `evidence/TR-7/tr7_fault.pcap`, logs A/B |
| **TR-8** | Security boundary verification | `tr8_boundary.sh` | `evidence/TR-8/tr8_gw*_protected_side.pcap`, transit pcap |
| **Restore**| Return to known-good state | `restore.sh` | Verifies IKE & ESP protection |

---

## 5. Diagnostic & Troubleshooting Tools

- **`sudo scripts/diagnose.sh`**: Runs 7 automated diagnostic suites testing interface status, carrier detection, transit ping, namespaces, sysctl routing, strongSwan service, and XFRM states.
- **`sudo scripts/run_all.sh`**: An interactive terminal UI menu allowing you to run, inspect, and verify any test with a single keypress.
- **`sudo scripts/restore.sh`**: Instantly restores the known-good strongSwan and XFRM configuration and confirms tunnel health.
