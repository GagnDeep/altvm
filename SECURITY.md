# Security policy

AltVM runs untrusted guest operating systems and offers enterprise controls such as signed policies, signed images,
encryption and audit, so security reports matter.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's **[Report a vulnerability](../../security/advisories/new)**
(Security → Advisories). Please include the affected version or commit, the steps to reproduce, and the impact.
Please don't open a public issue.

## In scope

- Guest-to-host escapes through AltVM components (guest agent channel, shared folders, control socket, virtual switch)
- Bypasses of signed policy, signed golden images, or audit-log tamper detection
- Exposure of secrets: VNC passwords, API tokens, encryption passphrases, escrow keys
- REST API or web console authentication issues

Issues in Apple's Virtualization.framework itself should go to Apple.
