# Security Policy

AkvaLink is a **network-attached device** — it speaks Matter over Thread or
Wi-Fi. That means firmware bugs can have security consequences, and we take
vulnerability reports seriously even though this is a small, private
open-source initiative maintained in spare time.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Report privately instead, so a fix can ship before details are public:

1. **Preferred:** use GitHub's private vulnerability reporting —
   go to the **Security** tab → **Report a vulnerability**. This opens a
   private advisory visible only to you and the maintainer.
2. **Alternative:** email the maintainer at **stenmo@gmail.com** with
   `AkvaLink SECURITY` in the subject line.

Please include:

- affected build/variant (Thread vs. `--wifi`, direct GPIO vs. `--clickboard`)
- firmware version / commit hash
- a description of the issue and, if possible, steps to reproduce
- the impact you believe it has

## What to expect

This is a hobby/private project, so responses are **best-effort**, not
bound by a commercial SLA. Realistically:

- acknowledgement of your report within about a week
- a fix or mitigation plan for confirmed issues as maintainer time allows
- credit in the release notes if you'd like it (say so in your report)

## Scope

In scope: the AkvaLink firmware and helper scripts in this repository.

Out of scope: vulnerabilities in upstream dependencies
(esp-matter, connectedhomeip, ESP-IDF, the u-blox NORA-W40 module) — please
report those to their respective projects. If an upstream issue affects
AkvaLink specifically, a note here is still welcome so it can be tracked.

## No warranty

AkvaLink is provided under the Apache-2.0 License, "AS IS", without warranty
of any kind. See [LICENSE](../LICENSE).
