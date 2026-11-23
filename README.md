# larakube-runner

The disposable job image LaraKube Cloud runs for each server operation. It runs one allow-listed LaraKube CLI command, keeps credentials out of pod logs, and posts a signed result.

Production must pin an image digest. Local and staging may follow `canary`.

```
ghcr.io/luchavez-technologies/larakube-runner:canary
```

## License

The files in this repository are source-available under [`FSL-1.1-MIT`](LICENSE). The image also contains the LaraKube CLI, Debian, OpenTofu, kubectl and other third-party software, which keep their own licenses.

Contributions require the [Contributor License Agreement](CLA.md).
