# Certificate usage monitoring (optional)

`examples/09-netscaler-monitoring.json` makes a Gateway write **one syslog line per successful logon with a client
certificate**. A collector can then show which certificate was used, when, on which Gateway and by which IdP user, and
which certificates were never seen. The collector, parser, certificate inventory correlation and dashboards are in
[pki-monitoring](https://github.com/bensplittgerber/pki-monitoring) (`docs/netscaler-cert-usage.md`).

Not deployed unless you add the file to a run. It changes no authentication, mTLS or CRL setting.

## Tested configuration
- NetScaler VPX 14.1 build 73.58, an nFactor Gateway with client certificate Mandatory (`08-mtls-client-ca.json`) and
  an OIDC IdP factor. The message expressions were accepted, and a logon produced exactly one line with serial,
  issuer, subject and the IdP user.
- The NITRO steps were run on a lab HA pair (14.1-73.58): `-WhatIf`, deploy, re-run (all `[EXISTS]`), undo, redeploy.
  Offline test: `tests/Test-NsObjects.ps1`.

## What it configures

| Step | Object | Why |
|---|---|---|
| 1 | `auditsyslogaction sla_monitoring` | listener address, TCP 5140, level INFORMATIONAL, user-defined audit messages on, management logs off (`mgmtloglevel NONE`: the command log of a deploy contains the message text) |
| 2 | `auditsyslogpolicy slp_monitoring` (rule `true`) | sends to that action |
| 3 | `auditsyslogglobal_auditsyslogpolicy_binding` priority 900 | **added next to** existing global syslog policies; nothing is replaced |
| 4 | `auditmessageaction ma_cert_usage_<gateway>` | the line itself (below) |
| 5 | `rewritepolicy rw_pol_cert_usage_<gateway>` | `NOREWRITE` + log action on the StoreFront logon request (`gatewayauth/login`, `citrixagbasic/authenticate`) when a client certificate exists |
| 6 | `vpnvserver_rewritepolicy_binding` | on the selected Gateway only, REQUEST, priority 90, goto `NEXT`: the Gateway's own rewrite policies still run |

Line format (one per logon; the Gateway name is a literal per Gateway):
```
NSMON|v1|gateway_logon|gateway=gw_example_com|client_ip=..|cert_serial=..|cert_issuer=..|cert_subject=..|aaa_user=..|idp_upn=..
```

## Gateway selection
Steps 4-6 are per Gateway. To monitor another Gateway, copy them with a new name and the new vserver name in the
literal and in the binding. Gateways without the binding produce no lines. That is "not monitored", not "unused".

## Security considerations
- **Never log tokens.** The IdP's access token is available as `AAA.USER.ATTRIBUTE("accesstoken")`: it is a live
  bearer credential. Do not add it, or any session cookie or assertion, to the message.
- **Do not use DEBUG** for this. The SSL log profile, which logs every client-certificate handshake, only logs at DEBUG,
  and DEBUG also sends AAA/OAuth internals such as authorization codes. If you need failed handshakes for
  troubleshooting, enable it for a limited time and remove it again.
- Plain TCP syslog has no encryption and no sender authentication. Use a listener on a trusted network that accepts
  only the NSIPs (both nodes of an HA pair).
- The message contains personal data (subject, IdP user, client IP). Apply your retention rules on the collector.

## Deploy
Standalone:
```powershell
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./examples/09-netscaler-monitoring.json -WhatIf
./scripts/Deploy-NsObjects.ps1 -ConfigFile ./examples/09-netscaler-monitoring.json
```
In a site deployment ([end-to-end.md](end-to-end.md)), add it at the end of `objects`. It is not in
`site.example.json` by default:
```json
"objects": [
  "02-lb-storefront.json",
  "03-aaa-oidc-entra.json",
  "04-gateway.json",
  "05-ssl-hardening.json",
  "08-mtls-client-ca.json",
  "09-netscaler-monitoring.json"
]
```
A re-run finds every object and binding (`[EXISTS]`) and writes no journal.

## Verify
1. NetScaler: `show audit syslogAction sla_monitoring`, `show vpn vserver gw_example_com` (rewrite policy at 90, NEXT).
2. Log on through the Gateway with a client certificate, then `show audit messageaction ma_cert_usage_gw_example_com`:
   `Hits` goes up by one per logon.
3. `stat audit`: "Logs sent to syslog server(TCP)" goes up, "TCP connect failed for syslog" stays 0.
4. On the collector: one `NSMON|v1|gateway_logon` line per logon.

## Undo
`./scripts/Undo-NsObjects.ps1 -Journal ./scripts/journals/09-netscaler-monitoring-<time>.json` removes, in reverse order:
the Gateway binding, the rewrite policy, the message action, the global syslog binding (only this one, by policy
name), the syslog policy and the action. Nothing needs to be restored by hand: the file makes no "set" changes.
Redeploy right after an undo: with TCP the NetScaler keeps the session to the listener open after the action is removed,
and a new action to the same address fails with `1496: Auditlog service exists with this server information` until
that session closes. Restart the listener (or wait), then deploy again. Tested on 14.1-73.58: undo, listener restart,
redeploy OK.
By hand (CLI): `unbind vpn vserver gw_example_com -policy rw_pol_cert_usage_gw_example_com -type REQUEST`,
`rm rewrite policy ...`, `rm audit messageaction ...`, `unbind audit syslogGlobal slp_monitoring` (name without
`-policyName`), `rm audit syslogPolicy slp_monitoring`, `rm audit syslogAction sla_monitoring`.

## Limits
- Only successful logons: failed TLS handshakes (revoked or unknown CA), IdP failures after mTLS and reconnects without
  a new logon produce no line.
- `idp_upn` needs an IdP action that extracts a `upn` attribute. In the tested Entra OIDC setup it stayed empty, so
  `aaa_user` (the Entra object id) was the IdP identity.
- TCP syslog can lose lines while the listener is down.
