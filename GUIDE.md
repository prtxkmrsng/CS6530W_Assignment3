# GUIDE — Step-by-Step Runbook

Read this top to bottom the first time. Each test (TR) section follows the same pattern:
**Goal → Run → What the script does → What to look for → Screenshots → What to write.**

Contents: [0 Concepts](#0-concepts-in-plain-language) · [1 Build the lab](#1-build-the-lab) · [2 Install & configure](#2-install--configure-both-gateways) · [3 Tests TR-1…TR-8](#3-the-tests) · [4 Report](#4-writing-the-report) · [5 Package](#5-packaging-the-submission) · [6 Troubleshooting](#6-troubleshooting) · [7 Manual command cheat-sheet](#7-manual-command-cheat-sheet) · [8 Glossary](#8-glossary)

---

## 0. Concepts in plain language

Think of two offices connected by a public road.

1. **IKE** is the two office managers meeting to agree on a secret handshake and a lockbox type.
   - *IKE_SA_INIT*: "Here are the lockbox types I support" + key-exchange numbers.
   - *IKE_AUTH*: "Prove you are who you say (PSK), and let's agree what traffic goes in the lockbox."
2. The result is an **IKE_SA** (the managers' private line) and a **CHILD_SA** (the lockbox convoy). The CHILD_SA is really **two one-way ESP tunnels**, each with its own **SPI**.
3. The Linux kernel keeps two tables:
   - **Policy (SPD)** — *which* packets get protected (`10.1.0.0/24 ↔ 10.2.0.0/24`).
   - **State (SAD)** — *how* (peer addresses, SPI, tunnel mode, algorithms).
4. A packet's journey: hostA → Gateway A (policy matches) → state encrypts it into ESP → crosses transit as `192.0.2.1 → 192.0.2.2 ESP` → Gateway B decrypts → hostB.

**What "evidence" means here:** you must connect the dots
`hostA packet → traffic selector/policy → ESP state → SPI → capture on the transit interface`.

---

## 1. Build the lab

### 1.1 Two VMs, one transit network

| | VM 1 (Site A) | VM 2 (Site B) |
|---|---|---|
| NIC 1 | NAT (internet for `apt`) | NAT |
| NIC 2 | Internal network `transit` | Internal network `transit` |
| Transit IP | `192.0.2.1/24` | `192.0.2.2/24` |

- VirtualBox: *Settings → Network → Adapter 2 → Internal Network → name `transit`* (same name on both).
- VMware: use a custom/host-only VMnet shared by both. KVM/libvirt: an isolated network.
- Find the NIC 2 name with `ip -br addr` (for example `enp0s8`).

### 1.2 Give each VM its transit IP (choose one)

**Option A — let the setup script do it (non-persistent).** In `config.env` set `WAN_IF_ASSIGN=enp0s8`.

**Option B — netplan (persistent).** `/etc/netplan/60-transit.yaml` (use `192.0.2.2/24` on VM 2):
```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [192.0.2.1/24]
```
then `sudo netplan apply`.

### 1.3 Check the transit link
```bash
ping -c2 192.0.2.2      # from VM 1 (use 192.0.2.1 from VM 2)
```
It must work before you continue. The "UDP/500 only" or firewall issues later are much harder to spot if this is broken.

> The addresses are examples; you may use others. Change them in `config.env` (identically on both VMs).

---

## 2. Install & configure both gateways

### 2.1 Copy the project and set your identity
Copy the project folder to both VMs (put it under `$HOME`), then on each:
```bash
cd cs6530w-a3
cp config.env.example config.env
nano config.env          # set ROLLNO="CS24M001" → your official roll number, UPPERCASE
chmod +x scripts/*.sh
```
`config.env` must be **identical on both VMs**. The PSK is derived automatically as `<ROLLNO>CS6530W-IPsec-A3-2026`; no one types it by hand, which avoids mismatches.

### 2.2 Run the setup script
```bash
sudo scripts/01_setup_gateway.sh A      # VM 1
sudo scripts/01_setup_gateway.sh B      # VM 2
```

| Step done by the script | Why |
|---|---|
| Install `strongswan-starter`, `tcpdump`, `iproute2` (+ `tshark` if available) | Classic `ipsec.conf` interface |
| Disable the `strongswan` (swanctl) service, enable `strongswan-starter` | Two IKE daemons must not run together |
| Create namespace `hostA`/`hostB` + veth pair, assign addresses, default route via gateway | The protected host, isolated from the gateway |
| Enable IP forwarding, disable ICMP redirects, `rp_filter=2` | Gateways must route between LAN and WAN |
| Add a **plaintext route** to the peer's protected subnet | Lets TR-1 work without IPsec (and lets faults still "ping") |
| Allow UDP 500/4500, ESP, and forwarding in iptables | So a host firewall does not interfere |
| Render `/etc/ipsec.conf` + `/etc/ipsec.secrets` (`auto=add`), restart strongSwan | Load the connection without starting it |

### 2.3 Verify the plumbing (no IPsec yet)
On VM 1:
```bash
sudo ip netns exec hostA ping -c2 10.1.0.1      # host → its gateway
sudo ipsec statusall | head                       # strongSwan running, conn loaded
ip -br addr                                       # identify the WAN interface (screenshot)
```
Same on VM 2 with `hostB` and `10.2.0.1`.

> **`auto=add`** means the connection is *loaded but not started*. Nothing negotiates until **you** run `ipsec up`, which is exactly what TR-2 needs.

---

## 3. The tests

Run in order. Scripts write to `evidence/<TR-x>/`. Take screenshots **with the terminal title/prompt visible** so the gateway (A or B) and command are clear.

### TR-1 — Plaintext baseline (VM 1)

- **Goal:** show that, with IPsec inactive, hostA → hostB works and the transit link carries **readable** ICMP: inner addresses and your roll-number payload.
- **Run:** `sudo scripts/tr1_plaintext.sh`
- **What it does:** brings the tunnel down, logs `ip -br addr`, `ip route`, forwarding, empty XFRM tables, starts `tcpdump` on the WAN interface (`icmp`), sends a ping from `hostA` whose payload is your roll number, stops the capture, and counts packets and payload hits.
- **Look for:** `10.1.0.10 > 10.2.0.10 ICMP`; payload text visible with `tcpdump -nn -A -r …`; `xfrm_states=0`; `RESULT [PASS]`.
- **Screenshots:** `ip -br addr`, routes + `ip_forward=1`, the `tcpdump -r` listing, the payload line.
- **Write:** expected (plaintext on transit) vs observed; interpretation: "routed connectivity without protection."

### TR-2 — Fresh IKEv2 establishment (VM 1; VM 2 just needs to be up)

- **Goal:** capture a *brand-new* IKE negotiation and explain each exchange.
- **Run:** `sudo scripts/tr2_ike_capture.sh`
- **What it does:** takes the tunnel down, **starts the capture first**, then runs `ipsec up cs6530-site-to-site` from Gateway A, sends traffic, saves status/XFRM/charon log, stops the capture, and prints numbered packet listings (`tcpdump -# -v`, plus `tshark` fields if installed).
- **Look for (Wireshark filter `isakmp || esp`):**

| # (your numbers) | Exchange | What it carries |
|---|---|---|
| first request/response | `IKE_SA_INIT` | proposal (`aes256-sha256-modp2048`), DH public values, nonces |
| next request/response | `IKE_AUTH` | encrypted: identities, PSK authentication, traffic selectors, first CHILD_SA |
| later | ESP | data traffic after the CHILD_SA is installed |

- **Also note:** the first CHILD_SA outcome (`INSTALLED, TUNNEL`) and whether ESP is native (IP proto 50) or UDP 4500.
- **Write:** a table of packet number → exchange → purpose.

### TR-3 — Protected session and SPI correlation (VM 1)

- **Goal:** repeat the TR-1 flow under IPsec and prove ESP protects it.
- **Run:** `sudo scripts/tr3_protected.sh`
- **What it does:** ensures the tunnel is up, captures `esp or udp port 4500 or udp port 500`, sends the same roll-number ping, saves `ipsec statusall`, redacted `ip xfrm state`, `ip xfrm policy`, then **automatically matches every captured SPI to its XFRM state**.
- **Look for:**
  - `ipsec statusall`: `ESTABLISHED` and `INSTALLED, TUNNEL`, plus the two ESP SPIs.
  - PCAP: `192.0.2.1 > 192.0.2.2: ESP(spi=0x…)` and the reverse direction with a **different** SPI.
  - The log's `SPI correlation` section: the XFRM state block with the same SPI, `src/dst`, `mode tunnel`, `reqid`, algorithms.
  - `payload_hits_on_transit=0`.
- **Why the payload is invisible:** ESP encrypts the entire original IP packet (inner addresses, ICMP header, payload) and wraps it in a new outer header between the gateways.
- **Write:** SPI table (direction, outer src→dst, SPI, state match, mode, algorithm, reqid); never paste key bytes.

### TR-4 … TR-7 — Deliberate faults (VM 1 + VM 2)

Same workflow each time:

1. **VM 1:** `sudo scripts/fault.sh <ike|psk|esp|ts>`
2. When it prints `Now run on Gateway B`, **VM 2:** `sudo scripts/collect_peer.sh TR-x` (peer's view: status, XFRM, charon log).
3. Back on VM 1 press **Enter** → the script restores the healthy config and verifies it.

`fault.sh` internally: **(1)** healthy baseline + verification → **(2)** fault, capture, `statusall`, XFRM, ping, logs, summary → **(3)** restore + verify. The summary line looks like:
```
SUMMARY[TR-x]: IKE_SA_established=0|1 CHILD_SA_installed=0|1 ping_rc=… native_esp=… plaintext_icmp_on_wan=…
connectivity=reachable|unreachable  protection=ESP-protected|NOT-protected
```

| TR | Command | Change on A only | Expected lead (verify!) | Charon log keywords to look for |
|---|---|---|---|---|
| TR-4 | `fault.sh ike` | IKE `aes128-…` vs B `aes256-…` | IKE_SA_INIT rejected | `NO_PROPOSAL_CHOSEN`, "no IKE proposal" |
| TR-5 | `fault.sh psk` | PSK `…-FAULT` | IKE_AUTH fails | `AUTHENTICATION_FAILED`, "tried 1 shared key" |
| TR-6 | `fault.sh esp` | ESP `aes128-sha1!` vs B `aes256-sha256!` | IKE_SA up, CHILD_SA refused | `NO_PROPOSAL_CHOSEN` in IKE_AUTH/CHILD |
| TR-7 | `fault.sh ts` | `rightsubnet=10.3.0.0/24` | selectors don't match B | `TS_UNACCEPTABLE`, "traffic selectors … inacceptable" |

**Interpreting results**

- Compare **IKE_SA** and **CHILD_SA** outcomes separately (TR-6 is the one where they differ).
- **Connectivity vs protection:** with a plain route in place, `hostA → hostB` may still answer — as **plaintext ICMP** visible on the WAN. That is *reachable but not protected*.
- **TR-7:** compare four things — configured selectors (A vs B conf), negotiated selectors (log/`statusall`), installed `ip xfrm policy`, and actual traffic. Then say whether the outcome was rejection, narrowing, or a non-matching policy — based on what you see, not on assumption.
- Each fault needs the six-part record:
  **Symptom → Evidence → Failure layer → Root cause → Correction → Verification.**

### TR-8 — Security boundary (VM 2 first, then VM 1)

- **Goal:** show the same flow in three places: before encapsulation, across transit, after decapsulation.
- **Run:**
  - VM 2: `sudo scripts/tr8_boundary.sh 40` (captures both Gateway B interfaces for 40 s)
  - VM 1 (within those 40 s): `sudo scripts/tr8_boundary.sh`
- **Captured:** Gateway A `vethA-gw` (protected side) + WAN; Gateway B `vethB-gw` + WAN.
- **Expect:** inner `10.1.0.10 → 10.2.0.10` + payload visible on both protected-side captures; only ESP between `192.0.2.1` and `192.0.2.2` on transit.
- **Write:** a table: capture point → addresses → protocol → payload visible (yes/no). Explain that plaintext on a protected-side interface is *inside* the site's trust boundary and is not WAN exposure.

### After every fault: confirm the known-good state
```bash
sudo scripts/verify.sh       # on each gateway
```
`PASS` means: IKE_SA ESTABLISHED, CHILD_SA INSTALLED, ping OK, ESP on the wire, no plaintext on transit.

---

## 4. Writing the report

Use `report/REPORT_TEMPLATE.md`. For **each** TR include:

1. Objective · 2. Procedure with exact commands · 3. Input/configuration change · 4. Expected · 5. Observed · 6. Pass/Fail · 7. Evidence identifiers (file, packet #, screenshot #) · 8. A concise 2–3 sentence interpretation.

Also: gateway-specific outputs, screenshots showing command + gateway, PCAP packet numbers, and the **AI-use disclosure** required by course policy. Export as `<RollNo>_CS6530W_Assignment3.pdf`.

Good evidence habits: one scenario per screenshot, readable font, never include key bytes (they're already redacted by the scripts), cite *packet numbers* rather than "see capture".

---

## 5. Packaging the submission

1. Copy VM 2's `evidence/` files into VM 1's project tree (e.g., `scp -r vm2:~/cs6530w-a3/evidence/. evidence/`).
2. Put screenshots in `evidence/screenshots/`.
3. Check for leaked keys (must print nothing): `grep -rE '0x[0-9a-f]{20,}' evidence siteA siteB`
4. `scripts/package.sh` → `../<ROLLNO>_CS6530W_Assignment3.zip` (excludes `config.env`, `.role`).
5. Upload the PDF + ZIP. **Deadline: Sat 21 Nov 2026, 11:59 PM IST** (22 Nov: −20 marks, 23 Nov: −40 marks).

---

## 6. Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| `ipsec: command not found` | `sudo apt install strongswan-starter` |
| Both `strongswan` and `strongswan-starter` active | `sudo systemctl disable --now strongswan; sudo systemctl restart strongswan-starter` |
| Setup says WAN IP not on any interface | Assign it (netplan) or set `WAN_IF_ASSIGN` in `config.env` |
| `ping 192.0.2.2` fails between VMs | Both NICs not on the same internal network; wrong IP/prefix |
| Tunnel up but hostA↔hostB ping fails | `sysctl net.ipv4.ip_forward` (=1?), `sudo iptables -S FORWARD`, host default route, `ip route get 10.2.0.10` on gateway |
| Ping works, no ESP seen | Tunnel isn't up (plaintext route used). Run `sudo scripts/verify.sh`, then `ipsec statusall` |
| `AUTHENTICATION_FAILED` on a healthy run | ROLLNO differs / not uppercase on the two VMs; fix `config.env`, run `scripts/restore.sh` on both |
| tcpdump: "Permission denied" writing PCAP | Move project under `$HOME`; scripts already use `-Z root` |
| Stale/odd SAs after experiments | `sudo scripts/restore.sh` |
| `fault.sh` aborts "baseline not healthy" | Fix the healthy tunnel first (start with `restore.sh` on **both** gateways) |
| Need to remove the lab | `sudo scripts/teardown.sh` (shows commands; type `REVIEWED` to proceed) |

Where to look for logs: `sudo journalctl -t charon --since -10min --no-pager`, or `evidence/<TR>/*.log`.

---

## 7. Manual command cheat-sheet

Everything the scripts do can be done by hand (useful for your "exact commands" section).

```bash
# Which interface is WAN / LAN
ip -br addr
# Plaintext capture (TR-1)
sudo tcpdump -i <WAN-IF> -n -s 0 -w tr1_plaintext.pcap icmp
sudo ip netns exec hostA ping -c5 10.2.0.10
# Protected capture (TR-3)
sudo tcpdump -i <WAN-IF> -n -s 0 -w tr3_protected.pcap "esp or udp port 4500 or udp port 500"
# Controlled initiation (TR-2) — capture running first, then on Gateway A:
sudo ipsec up cs6530-site-to-site
sudo ipsec statusall
sudo ip xfrm policy
sudo ip xfrm state | sed -E 's/0x[0-9a-fA-F]{20,}/0x<REDACTED>/g'
# Read a pcap
tcpdump -nn -# -v -r tr2_ike_establish.pcap
tcpdump -nn -A  -r tr1_plaintext.pcap | grep <ROLLNO>
# Bring the tunnel down / reload config
sudo ipsec down cs6530-site-to-site
sudo systemctl restart strongswan-starter
```

---

## 8. Glossary

| Term | Meaning |
|---|---|
| **ESP** | Encapsulating Security Payload: IPsec's encrypt + integrity-protect packet format (IP proto 50). |
| **SPI** | Security Parameter Index; labels an SA so the receiver finds the right keys. One per direction. |
| **SA** | Security Association — an agreed set of algorithms/keys for one direction or channel. |
| **Tunnel mode** | The whole original IP packet is encrypted and given a new outer IP header (gateway→gateway). |
| **PSK** | Pre-shared key authentication (lab-only secret here). |
| **DH / modp2048** | Diffie-Hellman group used to derive keys without sending them. |
| **NAT-T** | NAT traversal: ESP wrapped in UDP 4500; used only when NAT is detected. |
| **reqid** | Kernel ID that ties a policy to its state(s). |
| **SPD / SAD** | Security Policy Database (`ip xfrm policy`) / Security Association Database (`ip xfrm state`). |
| **Traffic selector (TS)** | The subnet pair a CHILD_SA protects. |
| **Namespace** | A Linux network stack of its own; used to emulate hostA and hostB. |
