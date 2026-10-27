# App Store kit

Paste-ready App Store Connect content for Health Access MCP, checked against Apple's limits:

- `text/`: one file per field (name, subtitle and a fallback, promotional text, description, keywords, review notes).
- `screenshots/`: iPhone 6.9" (1320 x 2868), synthetic data only. Rebuilt with `scripts/make-store-screenshots.py <folder of raw simulator captures>`.
- `ExportOptions.plist` and `scripts/archive-upload.sh`: archive and upload with an App Store Connect API key (the key stays outside the repo).

## Fields that are not text files

| Field | Value |
|---|---|
| Category | Health & Fitness, secondary Utilities |
| Price | Free; two optional in-app purchases |
| Privacy policy | https://healthaccessmcp.com/privacy-policy |
| Support | https://healthaccessmcp.com/support |
| Marketing | https://healthaccessmcp.com |
| Copyright | 2026 PRINZ TECHNOLOGY CONSULTANCY d.o.o. |
| Sign-in required | No |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in Info.plist (HTTPS only) |

## App Privacy

Matches `app/HealthAccess/Resources/PrivacyInfo.xcprivacy` and both privacy pages. Data is collected only because usage statistics exist (opt-in, off by default):

- Usage Data > Product Interaction: analytics, not linked to the user, not used for tracking.
- Diagnostics > Other Diagnostic Data (error domain and code of a failed export): app functionality, not linked, not used for tracking.
- Health & Fitness: not collected. Health data goes only into the folder the user picks.

## In-app purchases

| | Card | Coffee |
|---|---|---|
| Product ID | `com.healthaccessmcp.app.support.card` | `com.healthaccessmcp.app.support.coffee` |
| Type | Non-Consumable | Consumable |
| Price | €4.99 | €2.99 |
| Display name | Remove the support card | Coffee for the dev |
| Description | Hides the support card for good. Thank you. | A tip. The card stays, nothing else changes. |

## Age rating

Every content question "None". Medical or treatment information: None. Expected rating 4+.
