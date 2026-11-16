# GUIDE — Step-by-Step Runbook for VMware Workstation Pro

Contents: [0 Concepts](#0-concepts-in-plain-language) · [1 VMware Workstation Lab Setup](#1-vmware-workstation-lab-setup) · [2 Install & Configure](#2-install--configure-both-gateways) · [3 Tests TR-1…TR-8](#3-the-tests) · [4 Diagnostics & Troubleshooting](#4-diagnostics--troubleshooting) · [5 Packaging Submission](#5-packaging-submission)

---

## 0. Concepts in plain language

Think of two offices connected by a public road.

1. **IKE (Internet Key Exchange v2)** is the two office managers meeting to agree on a secret handshake and a lockbox type.
   - *IKE_SA_INIT*: "Here are the lockbox types I support" + Diffie-Hellman key-exchange numbers.
   - *IKE_AUTH*: "Prove who you are using the Pre-Shared Key (PSK), and let's agree what subnet traffic gets encrypted."
2. The result is an **IKE_SA** (the managers' control channel) and a **CHILD_SA** (the data channel: two one-way ESP tunnels, each with its own **SPI**).
3. The Linux kernel maintains two tables:
   - **Policy (SPD)** — *which* packets get protected (`10.1.0.0/24 ↔ 10.2.0.0/24`).
   - **State (SAD)** — *how* they are protected (peer addresses, SPI, tunnel mode, algorithms).
4. Packet journey: `hostA` → Gateway A (policy matches) → XFRM state encrypts into ESP → crosses transit link as `192.0.2.1 → 192.0.2.2 ESP` → Gateway B decrypts → `hostB`.

---

## 1. VMware Workstation Lab Setup

### 1.1 Virtual Machine Network Configuration

Each Ubuntu Server VM requires two virtual network adapters:

| Adapter | Type | Network Name | Purpose |
|---|---|---|---|
| **Adapter 1** | NAT | VMnet8 (Default NAT) | Internet connectivity for `apt` package downloads |
| **Adapter 2** | LAN Segment | `transit` | Isolated Layer-2 link between VM 1 and VM 2 |

#### Steps in VMware Workstation Pro:
1. Select **VM 1 (Site A)** in VMware Workstation.
2. Click **Edit virtual machine settings** (or `VM -> Settings`).
3. Ensure **Network Adapter** is set to **NAT**.
4. Click **Add...** → select **Network Adapter** → click **Finish**.
5. Select the newly added **Network Adapter 2**:
   - Select **LAN Segment**.
   - Click the **LAN Segments...** button, click **Add**, type `transit`, and click **OK**.
   - In the dropdown, choose `transit`.
   - Ensure **Connected** and **Connect at power on** checkboxes are BOTH checked.
6. Repeat the exact same step for **VM 2 (Site B)**, selecting the same `transit` LAN segment.
7. Power on both VMs.

> **Note on Interface Names:** In Ubuntu Server running under VMware, your primary adapter is usually `ens33`, and the second adapter is `ens34` (or `ens38`, `ens35`, `ens160`). The setup script will auto-detect your secondary adapter!

---

## 2. Install & Configure Both Gateways

### 2.1 Copy repository and configure identity
On **BOTH** VMs, place the project under `$HOME` (e.g., `~/CS6530W_Assignment3`):
```bash
cp config.env.example config.env
nano config.env          # Set ROLLNO="CS24M001" (replace with your UPPERCASE roll number)
chmod +x scripts/*.sh
```
> `config.env` must have the **exact same ROLLNO** on both VMs.

### 2.2 Run setup script
On **VM 1 (Site A)**:
```bash
sudo scripts/01_setup_gateway.sh A
```

On **VM 2 (Site B)**:
```bash
sudo scripts/01_setup_gateway.sh B
```

The script automatically:
1. Waits for and clears any background `apt` locks.
2. Installs `strongswan`, `strongswan-starter`, `tcpdump`, `iptables`, `zip`, `net-tools`, and crypto plugins.
3. Auto-detects the secondary network adapter (`ens34` / `ens38`).
4. Configures `192.0.2.1/24` (VM 1) or `192.0.2.2/24` (VM 2) and persists it in `/etc/netplan/` so it survives reboots.
5. Creates the protected host network namespace (`hostA` / `hostB`) and veth pair.
6. Sets kernel forwarding (`ip_forward=1`), disables `rp_filter`, and creates routing rules.
7. Configures iptables / UFW to allow IPsec (UDP 500, UDP 4500, ESP, ICMP).
8. Renders strongSwan configurations and verifies readiness.

### 2.3 Run Diagnostic Health Check
On either VM, run:
```bash
sudo scripts/diagnose.sh
```
This tests VMware interface status, carrier detection, inter-VM transit ping, namespaces, and strongSwan readiness.

---

## 3. The Tests

You can run each test directly or use the interactive lab runner: `sudo scripts/run_all.sh`.

### TR-1 — Plaintext Baseline (Run on VM 1)
- **Goal:** Verify that without IPsec, traffic between `hostA` and `hostB` is routed in plaintext across transit, with your roll number visible in the packet payload.
- **Run:** `sudo scripts/tr1_plaintext.sh`
- **Output:** `evidence/TR-1/tr1_plaintext.pcap` and `TR-1_gwA.log`
- **Pass condition:** Ping succeeds, ICMP is visible on transit, roll number string matches, zero XFRM states.

### TR-2 — Fresh IKEv2 Establishment Capture (Run on VM 1)
- **Goal:** Capture the initial IKEv2 handshake (`IKE_SA_INIT`, `IKE_AUTH`) and the subsequent CHILD_SA installation.
- **Run:** `sudo scripts/tr2_ike_capture.sh`
- **Output:** `evidence/TR-2/tr2_ike_establish.pcap` and `TR-2_gwA.log`
- **Pass condition:** IKE_SA ESTABLISHED, CHILD_SA INSTALLED, ISAKMP packets captured on UDP 500.

### TR-3 — Protected Session & SPI Correlation (Run on VM 1)
- **Goal:** Transmit host traffic under IPsec and correlate the captured ESP SPIs with Linux XFRM Security Associations (SAD).
- **Run:** `sudo scripts/tr3_protected.sh`
- **Output:** `evidence/TR-3/tr3_protected.pcap` and `TR-3_gwA.log`
- **Pass condition:** Encapsulation is ESP/UDP4500, 0 payload hits on transit, SPIs match active XFRM state entries.

### TR-4 … TR-7 — Fault Injections (VM 1 + VM 2)
For each fault test:
1. On **VM 1**: `sudo scripts/fault.sh <fault_name>`
2. When prompted, on **VM 2**: `sudo scripts/collect_peer.sh <TR-x>`
3. Back on **VM 1**: Press **Enter** to restore and verify healthy state.

| Test | Command on VM 1 | Fault Injected | Expected Observation |
|---|---|---|---|
| **TR-4** | `sudo scripts/fault.sh ike` | IKE proposal: `aes128-sha256-modp2048!` | IKE_SA_INIT rejected (`NO_PROPOSAL_CHOSEN`) |
| **TR-5** | `sudo scripts/fault.sh psk` | PSK suffix: `-FAULT` | IKE_AUTH failed (`AUTHENTICATION_FAILED`) |
| **TR-6** | `sudo scripts/fault.sh esp` | ESP proposal: `aes128-sha1!` | IKE_SA up, CHILD_SA rejected (`NO_PROPOSAL_CHOSEN`) |
| **TR-7** | `sudo scripts/fault.sh ts` | Remote subnet: `10.3.0.0/24` | CHILD_SA rejected (`TS_UNACCEPTABLE`) |

### TR-8 — Security Boundary Verification
- **Goal:** Prove security boundary isolation: plaintext on the LAN side (`veth*-gw`) vs ciphertext on the transit interface (`WAN_IF`).
- **Run:**
  1. On **VM 2** FIRST: `sudo scripts/tr8_boundary.sh 40` (starts 40s capture)
  2. On **VM 1** (within 40s): `sudo scripts/tr8_boundary.sh`
- **Pass condition:** LAN side shows plaintext ICMP + roll number payload; WAN transit link shows strictly ESP with 0 plaintext ICMP and 0 payload hits.

---

## 4. Diagnostics & Troubleshooting

| Symptom | Cause & Solution |
|---|---|
| `Transit link to peer is NOT reachable` | In VMware Workstation, ensure both VMs have Network Adapter 2 set to the **same** LAN Segment (or same Host-only VMnet). Check that the "Connected" checkbox is marked in VMware Settings. |
| `baseline not healthy` in `fault.sh` | Run `sudo scripts/restore.sh` on **both** VM 1 and VM 2 to return to the known-good state. |
| Ping fails between hostA and hostB | Run `sudo scripts/diagnose.sh` to check IP forwarding, interface status, and firewall rules. |
| `ipsec: command not found` | Run `sudo scripts/01_setup_gateway.sh A` (or B) to install missing packages. |

---

## 5. Packaging Submission

1. Copy VM 2's evidence into VM 1:
   ```bash
   scp -r user@<vm2-ip>:~/CS6530W_Assignment3/evidence/* ~/CS6530W_Assignment3/evidence/
   ```
2. Place terminal screenshots into `evidence/screenshots/`.
3. Verify no raw cryptographic keys are present:
   ```bash
   grep -rE '0x[0-9a-f]{20,}' evidence siteA siteB
   ```
4. Package the archive:
   ```bash
   scripts/package.sh
   ```
   Outputs: `../<ROLLNO>_CS6530W_Assignment3.zip`.
