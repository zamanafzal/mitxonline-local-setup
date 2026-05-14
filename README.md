# mitxonline-local-setup

Automation scripts and documentation for setting up **MITx Online** local development SSO and LMS integration.

The setup is split into two independent parts so you can work on each separately:

| Part | What it does | Script |
|------|-------------|--------|
| **Part 1** | MITx Online ↔ MIT Learn SSO via Keycloak + APISIX | `scripts/setup_mitxonline_mitlearn.sh` |
| **Part 2** | Tutor LMS ↔ MITx Online (Docker network, CORS, OAuth) | `scripts/setup_mitxonline_lms.sh` |

---

## Quick Start

### Prerequisites

- Docker Desktop running
- MITx Online repo cloned (the scripts run from its root)
- For Part 1: MIT Learn running (`docker compose up` in the MIT Learn repo)
- For Part 2: Part 1 completed + Tutor LMS installed

### Part 1 — MITx Online + MIT Learn SSO

```bash
cd /path/to/mitxonline
/path/to/mitxonline-local-setup/scripts/setup_mitxonline_mitlearn.sh
```

The script will:
1. Add required hostnames to `/etc/hosts` (asks for sudo)
2. Auto-detect the Keycloak port and fetch the `apisix` client secret
3. Update `.env` with all SSO settings
4. Create `docker-compose.override.yml` for container DNS
5. Start services and run verification checks

After completion, open `http://mitxonline.odl.local:9080/login/` to test SSO.

### Part 2 — Tutor LMS + MITx Online

```bash
cd /path/to/mitxonline
/path/to/mitxonline-local-setup/scripts/setup_mitxonline_lms.sh
```

The script will:
1. Add LMS hostnames to `/etc/hosts`
2. Update `.env` with CORS settings for all MFE origins
3. Patch the Tutor `docker-compose.yml` to join `mitxonline_default` network
4. Connect the running LMS container to the network
5. **Create (or retrieve) the OAuth2 Application** in MITx Online and print the Client ID + Secret
6. Append CORS config to LMS `development.py`
7. Restart MITx Online web/nginx and verify connectivity

**Manual step after the script:** Create the OAuth2ProviderConfig in LMS admin using the Client ID and Secret printed by the script (see [Part 2 docs](docs/part2-tutor-lms-mitxonline.md#step-6--update-the-lms-oauth2-provider-config)).

---

## CLI Options

Both scripts accept flags to override defaults. Use `--help` for the full list:

```bash
./scripts/setup_mitxonline_mitlearn.sh --help
./scripts/setup_mitxonline_lms.sh --help
```

Common overrides:

```bash
# Part 1: custom Keycloak port
./scripts/setup_mitxonline_mitlearn.sh --keycloak-port 9066

# Part 2: custom Tutor root
./scripts/setup_mitxonline_lms.sh --tutor-root ~/tutor-main
```

All values can also be set via environment variables (`KC_PORT`, `APISIX_PORT`, `LMS_HOST`, etc.).

---

## Idempotent

Both scripts are safe to re-run. They:
- Skip `/etc/hosts` entries that already exist
- Update `.env` keys in-place (no duplicates)
- Skip Tutor compose patching if already done
- Skip LMS CORS snippet if the marker comment is found
- Back up files before overwriting

---

## Documentation

Detailed step-by-step guides (for when you want to do things manually):

- [Part 1 — MITx Online + MIT Learn SSO](docs/part1-mitxonline-mitlearn-sso.md)
- [Part 2 — Tutor LMS + MITx Online](docs/part2-tutor-lms-mitxonline.md)

---

## Repo Structure

```
mitxonline-local-setup/
├── README.md
├── .gitignore
├── docs/
│   ├── part1-mitxonline-mitlearn-sso.md
│   └── part2-tutor-lms-mitxonline.md
└── scripts/
    ├── setup_mitxonline_mitlearn.sh
    └── setup_mitxonline_lms.sh
```

---

## Troubleshooting

See the troubleshooting sections in each doc:
- [Part 1 troubleshooting](docs/part1-mitxonline-mitlearn-sso.md#troubleshooting)
- [Part 2 troubleshooting](docs/part2-tutor-lms-mitxonline.md#troubleshooting)

