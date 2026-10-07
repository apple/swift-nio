# Report a security vulnerability

## How to report a security vulnerability

Apple prioritizes the security of its open source projects and values the contributions of the security research community.
If you believe that you have discovered a security vulnerability in our open source software,
  please report it to us using the [GitHub private vulnerability feature](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/privately-reporting-a-security-vulnerability).
This can be done by navigating to the "Security" tab of the specific repository where you found the issue.
For other Apple software, please report a security or privacy vulnerability on [Apple Security Research](https://security.apple.com/).

Reports should include specific software version(s) that you believe are affected;
 a technical description of the behavior that you observed and the behavior that you expected;
 the steps required to reproduce the issue;
 and a proof of concept or exploit.

## How these reports are handled

Our goal is to confirm all security reports. This is neither an acceptance nor a rejection of the report.
We may follow up with further questions while working through the details of your report.
We may prioritize vulnerability remediation, and resolution times may vary according to several factors, such as complexity, severity, and active maintenance of a project.

For the development of secure product and the protection of our users, the project will not disclose or discuss security issues until the investigation is complete and any necessary updates are generally available, unless required by law.
After updates are made available, reports will be published as GitHub Security Advisories.

Some projects have additional security pages with further details or aggregated findings - consult project specific documentation for details.

## Additional guidelines

Output from automated security scans or fuzzers must include additional context demonstrating the vulnerability with a proof of concept or working exploit.
Please include enough information to allow us to reproduce the issue. We will credit you in the public advisory if the report is accepted.

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

While we welcome reports for open source software projects, they are not eligible for Apple Security Bounties.
