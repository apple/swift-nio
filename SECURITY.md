# Security

This document specifies the security process for the SwiftNIO project.

## Disclosures

### Private Disclosure Process

The SwiftNIO core team asks that known and suspected vulnerabilities be
privately and responsibly disclosed by emailing
[sswg-security-reports@forums.swift.org](mailto:sswg-security-reports@forums.swift.org)
with the [details usually included with bug reports][issue-template].
**Do not file a public issue.**

#### When to report a vulnerability

* You think you have discovered a potential security vulnerability in SwiftNIO
  or any of the SwiftNIO projects.
* You are unsure how a vulnerability affects SwiftNIO or any of the SwiftNIO
  projects.

#### What happens next?

* A member of the team will acknowledge receipt of the report within 3
  working days (United States). This may include a request for additional
  information about reproducing the vulnerability.
* We will privately inform the Swift Server Work Group ([SSWG][sswg]) of the
  vulnerability within 10 days of the report as per their [security
  guidelines][sswg-security].
* Once we have identified a fix we may ask you to validate it. We aim to do this
  within 30 days. In some cases this may not be possible, for example when the
  vulnerability exists at the protocol level and the industry must coordinate on
  the disclosure process.
* If a CVE number is required, one will be requested from [MITRE][mitre]
  providing you with full credit for the discovery.
* We will decide on a planned release date and let you know when it is.
* Prior to release, we will inform major dependents that a security-related
  patch is impending.
* Once the fix has been released we will publish a security advisory on GitHub
  and the [SSWG][sswg] will announce the vulnerability on the [Swift
  forums][swift-forums-sec].

[issue-template]: https://github.com/apple/swift-nio/blob/main/.github/ISSUE_TEMPLATE.md
[sswg]: https://github.com/swift-server/sswg
[sswg-security]: https://github.com/swift-server/sswg/blob/main/process/incubation.md#security-best-practices
[swift-forums-sec]: https://forums.swift.org/c/server/security-updates/
[mitre]: https://cveform.mitre.org/
