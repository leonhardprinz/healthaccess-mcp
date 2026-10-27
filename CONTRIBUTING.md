# Contributing

Thanks for looking. A few rules keep this project what it is:

- **No real health data, ever.** Tests and docs use the synthetic folder in `examples/` (made by `examples/generate.py`). If you need a new case, add it to the generator. Never commit an export from your own phone.
- **Read [`docs/north-star.md`](docs/north-star.md)** before changing the app or the copy. Plain words, no em dashes, no charts.
- **The folder is the API.** A change to the files the app writes goes into [`docs/schema.md`](docs/schema.md) first.
- **Prompts live in [`docs/prompts.md`](docs/prompts.md).** Run `python3 scripts/sync-prompts.py` to copy them into the app, the site and the plugin; never edit the copies.

Build and test:

```bash
cargo test --workspace
```

The app builds with Xcode and `xcodegen` (see `app/README.md`); a free personal team is enough for the simulator and your own phone.

Open an issue before a large change, so we can agree on the shape first. Security problems go to support@healthaccessmcp.com, see [`SECURITY.md`](SECURITY.md).
