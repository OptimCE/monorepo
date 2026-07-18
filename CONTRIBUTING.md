# Contributing to OptimCE

Thank you for your interest in contributing! Issues and pull requests are
welcome from everyone. By participating in this project, you agree to abide by
our [Code of Conduct](CODE_OF_CONDUCT.md).

## Where to Contribute

The OptimCE platform is split across several repositories under the
[OptimCE organization](https://github.com/OptimCE):

- **Service code** (backend, frontend, microservices) lives in the individual
  service repositories, included here as git submodules. If your change
  concerns a specific service, please open your issue or pull request in that
  service's repository — see the repository map in the [README](README.md).
- **This monorepo** is the right place for changes to the development
  environment and orchestration: Docker Compose configuration, the API gateway
  (KrakenD), authentication (Keycloak realm and providers), the reverse proxy
  (nginx), shared reference data, and cross-cutting documentation.

## Setting Up a Development Environment

```bash
git clone --recurse-submodules https://github.com/OptimCE/monorepo.git
cd monorepo
./docker-stack.sh start
```

The [README](README.md) covers the prerequisites, the `.env.dev` configuration,
and everything the stack wrapper can do.

## Reporting Bugs and Suggesting Features

Open a [GitHub issue](https://github.com/OptimCE/monorepo/issues) (or one in
the relevant service repository). For bugs, include what you did, what you
expected, and what happened instead — logs and reproduction steps help a lot.

For security vulnerabilities, **do not open a public issue**; follow the
[security policy](SECURITY.md) instead.

## Submitting Pull Requests

1. Fork the repository and create a feature branch from `main`.
2. Make your changes. Keep each pull request focused on a single topic.
3. Make sure the development stack still starts and runs
   (`./docker-stack.sh start`).
4. Open a pull request against `main`, describing **what** you changed and
   **why**.

Notes:

- Submodule pointer updates (bumping a service to a newer commit) are handled
  by the maintainers — please don't include them in feature pull requests.
- Small documentation fixes are welcome as direct pull requests; for larger
  changes, opening an issue first to discuss the approach can save you time.

## Commit Messages

Use short, imperative commit messages, preferably following the
[Conventional Commits](https://www.conventionalcommits.org/) style used in this
repository:

```
feat: add billing service to the dev stack
fix: correct krakend route for document generation
chore: update submodule crm-backend
docs: document the init profile
```

## License

OptimCE is licensed under the [Apache License 2.0](LICENSE). By contributing,
you agree that your contributions will be licensed under the same license.
