# Security

This document specifies the security process for the SwiftNIO project.

## Versions

The SwiftNIO core team will address security vulnerabilities in all SwiftNIO 2.x
versions. Since support for some Swift versions was dropped during the lifetime of
SwiftNIO 2, patch releases will be created for the last supported SwiftNIO versions
that supported older Swift versions.
If a hypothetical security vulnerability was introduced in 2.10.0, then SwiftNIO core
team would create the following patch releases:

* NIO 2.29. + plus next patch release to address the issue for projects that support
  Swift 5.0 and 5.1
* NIO 2.39. + plus next patch release to address the issue for projects that support
  Swift 5.2 and 5.3
* NIO 2.42. + plus next patch release to address the issue for projects that support
  Swift 5.4 and later
* NIO 2.50. + plus next patch release to address the issue for projects that support
  Swift 5.5.2 and later
* NIO 2.59. + plus next patch release to address the issue for projects that support
  Swift 5.6 and later
* mainline + plus next patch release to address the issue for projects that support
  Swift 5.7 and later

SwiftNIO 1.x is considered end of life and will not receive any security patches.

## Disclosures

If you believe that you have discovered a security or privacy vulnerability in our open source software, please report it to us using the GitHub private vulnerability feature. Reports should include specific product and software version(s) that you believe are affected; a technical description of the behavior that you observed and the behavior that you expected; the steps required to reproduce the issue; and a proof of concept or exploit.

The project team will do their best to acknowledge receiving all security reports within 7 days of submission. This initial acknowledgment is neither acceptance nor rejection of your report. The project team may come back to you with further questions or invite you to collaborate while working through the details of your report.

Keep these additional guidelines in mind when submitting your report:

* Reports concerning known, publicly disclosed CVEs can be submitted as normal issues to this project.
* Output from automated security scans or fuzzers MUST include additional context demonstrating the vulnerability with a proof of concept or working exploit.
* Application crashes due to malformed inputs are typically not treated as security vulnerabilities, unless they are shown to also impact other processes on the system.


While we welcome reports for open source software projects, they are not eligible for Apple Security Bounties.
