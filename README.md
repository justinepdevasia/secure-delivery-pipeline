# secure-delivery-pipeline

A portfolio repository demonstrating GitHub Actions CI/CD, software supply chain
security, Bash and Python automation, and AWS/EKS delivery — built and verified
entirely inside GitHub Actions.

> **Status: under construction.** This stub is replaced by the full README in a
> later phase. See `buildspec.md` for the specification being built out.

## What is real and what is emulated

The supply chain pipeline is fully operational: images are built, scanned, signed
and attested on every push to `main`, and the signatures are independently
verifiable with `gh attestation verify`. The AWS and Kubernetes layers run against
a local AWS emulator inside the GitHub Actions runner — no AWS account is involved.

## License

MIT — see [LICENSE](LICENSE).
