# BastionOS installer

The public bootstrap script of [BastionOS](https://bastion-os.com). It holds
no secret and no BastionOS code: it fetches the deployment bundle of the
version you ask for (Compose files, OpenBao configuration, operating
scripts and the `bastionos` command) from its private image on ghcr.io,
then asks its questions and starts the stack.

```sh
curl -fsSL https://raw.githubusercontent.com/su2626/bastionos-install/main/install.sh | sudo bash
```

With no version it installs the latest one, 1.0.0; name one to pin it
(`… | sudo bash -s 1.0.0`).

- Requires Docker with Compose 2.24 or later, and openssl.
- The images are private: have the account and the token (`read:packages`)
  you were given ready, or set `BASTION_REGISTRY_USER` and
  `BASTION_REGISTRY_TOKEN`.
- Installs in `/var/dck/bastionos` (`--dir` to change). Run again on an
  installed host to upgrade.
- Before running anything it checks the cosign signature of the installer
  image (signed by BastionOS's CI without a key, through GitHub Actions
  OIDC, and logged in the public Sigstore logs) and runs it by digest. It
  needs `tuf-repo-cdn.sigstore.dev` and `rekor.sigstore.dev`. 1.0.0 was
  published before signing and passes with a warning.
- Without Internet access: `bash install.sh --bundle bastionos-airgap-<version>-linux-amd64.tar --pubkey release.pub`.

Afterwards: `bastionos status`, `bastionos backup`, `bastionos upgrade <version>`.

`install.sh` is a copy of `deploy/install/install.sh` in the BastionOS
repository (ADR-0095); change it there first.
