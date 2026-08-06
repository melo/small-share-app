# Security

## Reporting a vulnerability

Please report privately through GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, rather than opening a public issue.

## What this project does and does not defend against

Read this first — several things that look like vulnerabilities are documented
trades.

**There is no authentication, by design.** Anything that can reach the port may
upload, list and delete. This is intended for private networks. Deploying it on
the open internet is a deployment mistake, not a bug in the software, and the
README says so. Reports of "no auth" will be closed as documented behaviour.

**The URL is the only credential** for a stored file: 32 base62 characters from
`/dev/urandom`, about 190 bits. Anyone holding a URL can read and delete that
file. That is the design.

**What IS in scope**, and worth reporting:

- Any way to get script to execute in the app's own origin from an uploaded
  file — a sanitiser bypass in `lib/Share/Render.pm`, a sandbox or CSP escape,
  or a stored file served with a `Content-Type` that lets it run.
- Any path traversal or way to read, write or delete a file outside the
  workspace directory.
- Any way to guess, enumerate or derive a share URL from anything other than
  being told it — including weaknesses in how the token is generated.
- Any way to make one uploaded file's secret leak into another response, a log,
  a referrer, or a cache.
- Denial of service that a single small request can cause, as distinct from
  "someone with network access uploaded a lot of files", which is expected.
