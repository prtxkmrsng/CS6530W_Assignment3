# CS6530W Assignment 3 — Site-to-Site IPsec/IKEv2 with strongSwan

> **Configure → Observe → Validate → Break → Diagnose → Restore**

This project builds a small "two offices connected over the Internet" lab on one computer, protects the traffic between the offices with **IPsec (IKEv2, tunnel-mode ESP)**, and then helps you collect the evidence the assignment asks for: packet captures, strongSwan status, Linux XFRM state, and four deliberate-failure diagnoses.

Everything uses real **strongSwan** and the Linux **XFRM** framework. Nothing here implements IKE, ESP or crypto itself.

---

## 1. What you are building

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

| Item | Site A | Site B |
|---|---|---|
| Protected host (namespace) | `hostA` `10.1.0.10/24` | `hostB` `10.2.0.10/24` |
| Gateway protected-side | `vethA-gw` `10.1.0.1/24` | `vethB-gw` `10.2.0.1/24` |
| Gateway transit/WAN | `192.0.2.1/24` | `192.0.2.2/24` |
| Protected subnet | `10.1.0.0/24` | `10.2.0.0/24` |
| IKE proposal | `aes256-sha256-modp2048!` | same |
| ESP proposal | `aes256-sha256!` | same |
| Authentication | PSK = `<ROLLNO>CS6530W-IPsec-A3-2026` | same |

The goal: traffic **hostA ↔ hostB** must cross the transit link **only as encrypted ESP**, while it is plaintext on each protected side.

---

## 2. Five-minute concept primer

| Term | Plain meaning | Where you will see it |
|---|---|---|
| **IKE_SA** | The *control* channel. The two gateways agree on algorithms and prove their identity (PSK here). | `ipsec statusall` → `ESTABLISHED` |
| **CHILD_SA** | The *data* channel: a pair of one-way ESP tunnels (one SPI per direction) that actually carry user traffic. | `ipsec statusall` → `INSTALLED, TUNNEL` |
| **IKE_SA_INIT** | 1st exchange: algorithm proposals, Diffie-Hellman values, nonces. **Proposal mismatch fails here.** | PCAP, UDP 500 |
| **IKE_AUTH** | 2nd exchange: authentication + traffic selectors + first CHILD_SA. **PSK mismatch fails here.** | PCAP, UDP 500 |
| **ESP / SPI** | Encrypted packet format / the 32-bit label that tells the receiver which SA to use. | PCAP `ESP(spi=0x…)` ↔ `ip xfrm state` |
| **Traffic selector** | "Which source/destination subnets does this tunnel protect?" | `leftsubnet/rightsubnet`, `ip xfrm policy` |
| **XFRM policy (SPD)** | Kernel rule: *which traffic must be IPsec-protected* and in which direction. | `ip xfrm policy` |
| **XFRM state (SAD)** | Kernel record: *how* it is protected (endpoints, SPI, mode, algorithms). | `ip xfrm state` |

**Golden rule of this assignment:** a successful `ping` is *not* proof of encryption. Always show ESP on the transit interface and no plaintext payload there.

---

## 3. What is in this repository

```
cs6530w-a3/
├── README.md                  ← you are here (overview)
├── GUIDE.md                   ← detailed step-by-step runbook
├── .gitignore
├── config.env.example         ← copy to config.env (your roll number, addresses)
├── scripts/
│   ├── lib.sh                 shared helpers: logging, captures, XFRM redaction, health check
│   ├── 01_setup_gateway.sh    one-time setup of a gateway (A or B)
│   ├── render_config.sh       writes /etc/ipsec.conf + /etc/ipsec.secrets
│   ├── tr1_plaintext.sh       TR-1  plaintext baseline
│   ├── tr2_ike_capture.sh     TR-2  fresh IKEv2 handshake capture
│   ├── tr3_protected.sh       TR-3  protected flow + SPI correlation
│   ├── fault.sh               TR-4/5/6/7 fault injection + automatic restore
│   ├── collect_peer.sh        peer-side (Gateway B) evidence during a fault
│   ├── tr8_boundary.sh        TR-8  security-boundary captures
│   ├── verify.sh              health check on demand
│   ├── restore.sh             return to the known-good configuration
│   ├── redact.sh              strips key bytes from `ip xfrm` output
│   ├── teardown.sh            cleanup, guarded by a manual-review prompt
│   └── package.sh             builds the submission ZIP
├── siteA/  siteB/             reference configs rendered with default addresses
├── evidence/                  logs + PCAPs are written here (one folder per TR)
└── report/REPORT_TEMPLATE.md  skeleton for the PDF report
```

---

## 4. Requirements

- One physical computer running **two Ubuntu 22.04/24.04 VMs** (VirtualBox, VMware, KVM…), each with:
  - one NIC for internet/`apt` (NAT), and
  - one NIC on a shared **internal/host-only network** used as the transit link.
- `sudo` rights on both VMs.
- Your **official roll number in UPPERCASE** for the PSK.

> Two IP aliases on one network stack are **not** acceptable. Each gateway must be its own VM (own strongSwan, own XFRM state).

---

## 5. Quick start

```bash
# 1) On BOTH VMs: copy the project under $HOME, then
cp config.env.example config.env        # edit ROLLNO (UPPERCASE) – same file on both VMs
chmod +x scripts/*.sh

# 2) One-time gateway setup
sudo scripts/01_setup_gateway.sh A      # on VM 1
sudo scripts/01_setup_gateway.sh B      # on VM 2

# 3) Evidence runs (VM 1 unless noted)
sudo scripts/tr1_plaintext.sh           # TR-1
sudo scripts/tr2_ike_capture.sh         # TR-2
sudo scripts/tr3_protected.sh           # TR-3
sudo scripts/fault.sh ike               # TR-4  (then on VM 2: sudo scripts/collect_peer.sh TR-4)
sudo scripts/fault.sh psk               # TR-5
sudo scripts/fault.sh esp               # TR-6
sudo scripts/fault.sh ts                # TR-7
sudo scripts/tr8_boundary.sh 40         # TR-8, on VM 2 FIRST (optional)…
sudo scripts/tr8_boundary.sh            # …then on VM 1 within 40 s

# 4) Package
scripts/package.sh                      # → ../<ROLLNO>_CS6530W_Assignment3.zip
```

Every evidence script prints a final line like `RESULT [PASS] …` or `RESULT [FAIL] …`, and saves a full command log plus any PCAPs under `evidence/<TR-x>/`.

For detailed explanations, what to screenshot and how to interpret results, read **[GUIDE.md](GUIDE.md)**.

---

## 6. Requirement ↔ script ↔ evidence map

| Assignment item | Script | Main evidence files |
|---|---|---|
| FR-1, TR-1 plaintext baseline | `01_setup_gateway.sh`, `tr1_plaintext.sh` | `evidence/TR-1/tr1_plaintext.pcap`, `TR-1_gwA.log` |
| FR-2/3/4, TR-2 IKE establishment | `render_config.sh`, `tr2_ike_capture.sh` | `evidence/TR-2/tr2_ike_establish.pcap`, log |
| FR-5/6/7, TR-3 protected + SPI | `tr3_protected.sh` | `evidence/TR-3/tr3_protected.pcap`, log (SPI section) |
| TR-4 IKE proposal mismatch | `fault.sh ike`, `collect_peer.sh TR-4` | `evidence/TR-4/tr4_fault.pcap`, logs A/B |
| TR-5 PSK mismatch | `fault.sh psk`, `collect_peer.sh TR-5` | `evidence/TR-5/…` |
| TR-6 ESP proposal mismatch | `fault.sh esp`, `collect_peer.sh TR-6` | `evidence/TR-6/…` |
| TR-7 selector mismatch | `fault.sh ts`, `collect_peer.sh TR-7` | `evidence/TR-7/…` |
| TR-8 security boundary | `tr8_boundary.sh` | `evidence/TR-8/tr8_gw*_protected_side.pcap`, `tr8_gw*_transit.pcap` |
| FR-8 restore after each fault | automatic in `fault.sh`; manual `restore.sh` | `*_restored.pcap`, `RESULT` lines |

---

## 7. The four deliberate faults

All faults are applied **only on Gateway A**; Gateway B always keeps the healthy configuration. `fault.sh` always: verifies a healthy tunnel → injects the fault → captures evidence → (pauses for B's evidence) → restores and verifies.

| TR | Command | One-sided change on A | Expected place of failure* |
|---|---|---|---|
| TR-4 | `fault.sh ike` | `ike=aes128-sha256-modp2048!` | IKE_SA_INIT — no IKE_SA at all |
| TR-5 | `fault.sh psk` | PSK + `-FAULT` | IKE_AUTH — IKE_SA never established |
| TR-6 | `fault.sh esp` | `esp=aes128-sha1!` | IKE_SA up, **CHILD_SA** fails |
| TR-7 | `fault.sh ts` | `rightsubnet=10.3.0.0/24` | CHILD_SA traffic-selector negotiation |

\* Expectations only. The report must describe what **your** evidence shows.

A fault can leave ordinary routed traffic working in **plaintext** (setup adds a plain route between the sites). The scripts therefore report `connectivity` and `protection` separately — do the same in your report.

---

## 8. Safety and hygiene

- **Lab PSK only.** Never reuse it for any real service.
- **No key material in the report:** `ip xfrm state` output is piped through `redact.sh`; `ipsec.secrets` copies in `evidence/` are redacted.
- `teardown.sh` is the only script that removes things, and it prints each command and requires you to type `REVIEWED` first.
- `config.env` and `.role` are git-ignored (they identify you / the machine).
- Keep the project under `$HOME`; Ubuntu's AppArmor profile for `tcpdump` can block writing PCAPs elsewhere.

---

## 9. Frequently asked questions

**Do I need to edit any strongSwan files by hand?** No. `render_config.sh` generates both `ipsec.conf` and `ipsec.secrets` from `config.env` (originals are backed up as `/etc/ipsec.conf.orig`).

**Can I change the WAN addresses?** Yes — edit `SITE_A_WAN_IP` / `SITE_B_WAN_IP` in `config.env` (same on both VMs) before running setup.

**Which interface is "transit"?** The one holding the gateway's WAN IP. Detected automatically (or set `WAN_IF`).

**Is a native ESP or UDP-encapsulated ESP expected?** Whatever you actually observe; the scripts print counts of both (UDP 4500 appears only if NAT traversal kicks in). Report what you saw.

**Something broke mid-run.** `sudo scripts/restore.sh` returns the gateway to the known-good configuration and verifies it.
