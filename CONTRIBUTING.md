# Contributing to AltVM

Thanks for helping. Bug reports, docs fixes and pull requests are all welcome.

## Build and test

You need an Apple silicon Mac and Xcode with the macOS 27 SDK.

```bash
swift build
codesign -f -s - --entitlements Resources/avm.entitlements .build/debug/avm   # required after every build
swift test                                  # unit tests, run in isolated temporary homes
./scripts/build.sh                          # release build → dist/AltVM.app + dist/avm
./scripts/e2e.sh                            # end-to-end on real VMs, in a throwaway ALTVM_HOME (downloads a Debian image)
```

Point `ALTVM_HOME` at a scratch folder while developing so test VMs stay out of your real library.

## Guidelines

- **Keep it on Virtualization.framework.** Features must work with Apple's public frameworks, or degrade cleanly where they need entitlements.
- **Test real behaviour.** Add a unit test for logic, and an `e2e.sh` check for anything that touches a running VM.
- **Be honest in docs.** Mark features ✅ only once they have been verified on a real VM.
- **Fail safe.** Never delete user data on an error path. Set it aside and tell the user.
- **One topic per pull request**, with a short description of what you tested.

## Project layout

See [Architecture](README.md#architecture) in the README.

## Reporting security issues

Please do not open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
