# ibm-doc-collector

PowerShell CLI tool that collects IBM troubleshooting documentation from IBM sources, deduplicates content, and uploads to SharePoint via Microsoft Graph.

---

## Requirements

| Requirement | Details |
|---|---|
| PowerShell | 7.2 or later |
| Auth provider (one of) | [MSAL.PS](https://github.com/AzureAD/MSAL.PS) **or** Az.Accounts |
| Network access | ibm.com, graph.microsoft.com |

Install an auth provider:
```powershell
Install-Module MSAL.PS -Scope CurrentUser      # recommended
# or
Install-Module Az.Accounts -Scope CurrentUser
```

---

## Instalasi (global)

Jalankan installer sekali dari direktori proyek:

```powershell
.\install.ps1
```

Installer akan:
1. Membuat `%LOCALAPPDATA%\ibm-doc-collector\bin`
2. Menyalin `cli.ps1`, `ibm-doc-collector.cmd`, dan semua modul ke direktori tersebut
3. Menambahkan direktori bin ke **PATH** (User scope)

Setelah membuka sesi PowerShell baru, jalankan dari mana saja:

```powershell
ibm-doc-collector help
ibm-doc-collector init
ibm-doc-collector collect --category Support
ibm-doc-collector doctor
```

> **Catatan:** Jika `where ibm-doc-collector` belum menemukan perintah, tutup dan buka kembali terminal agar perubahan PATH aktif.

> ⚠️ **Jangan gunakan** `powershell -File ibm-doc-collector.cmd` — PowerShell menolak eksekusi `.cmd` dengan flag `-File`. `ibm-doc-collector.cmd` adalah batch launcher Windows; jalankan langsung tanpa `powershell -File`.

---

## Quick Start

> **After global install**, replace `.\cli.ps1` with `ibm-doc-collector` in all commands below.
> Run the launcher directly — **do not** prefix it with `powershell -File`.
> `ibm-doc-collector.cmd` is a Windows batch launcher; Windows runs it directly from PATH.

### 1. Configure

```powershell
ibm-doc-collector init
# or, from the project directory before installing:
.\cli.ps1 init
```

Prompts for:
- **Microsoft Tenant ID** — your Azure AD tenant GUID
- **SharePoint Site ID** — e.g. `contoso.sharepoint.com,/sites/mysite`
- **Document Library** — default `Documents`
- **Destination folder** — default `IBM/Troubleshooting`

Config is saved to `data/config.json` (never contains tokens or passwords).

### 2. Authenticate

```powershell
ibm-doc-collector auth ibm          # IBM credentials (interactive — not stored to disk)
ibm-doc-collector auth sharepoint   # Microsoft / SharePoint via device-code flow
```

### 3. Collect

```powershell
ibm-doc-collector collect                      # all sources
ibm-doc-collector collect --category Support   # specific category
```

### 4. Check status

```powershell
ibm-doc-collector status
```

### 5. Export report

```powershell
ibm-doc-collector report
```

Writes a CSV to `data/report_<timestamp>.csv`.

### 6. Health check

```powershell
ibm-doc-collector doctor
```

Checks PowerShell version, config keys, auth state, MSAL availability, and SharePoint connectivity.

---

## Project Structure

```
ibm-doc-collector/
├── cli.ps1                          # Entry point — all commands
├── src/
│   └── Modules/
│       ├── Logger.psm1              # Structured logging; redacts credentials
│       ├── Config.psm1              # Flat JSON config; no secrets stored
│       ├── AuthManager.psm1         # IBMid + Microsoft device-code auth
│       ├── IbmSourceConnector.psm1  # Fetch document lists + content
│       ├── DocumentProcessor.psm1   # Save bytes, compute SHA-256 hash
│       ├── MetadataStore.psm1       # JSON-Lines metadata store + dedup
│       └── SharePointConnector.psm1 # Upload via Microsoft Graph
├── tests/
│   └── Unit.Tests.ps1               # Pester unit tests
├── data/                            # Runtime data (gitignored)
│   ├── config.json
│   ├── metadata.jsonl
│   ├── staging/
│   └── logs/
├── .github/
│   └── workflows/ci.yml             # CI: Pester + secret-leak lint
└── gitignore.txt                    # Rename to .gitignore
```

---

## Metadata Fields (PRD §8)

| Field | Description |
|---|---|
| `judul` | Document title |
| `sourceUrl` | Original IBM URL |
| `kategori` | Source category (Support, Documentation, Redbooks…) |
| `subkategori` | Subcategory if available |
| `product` | Product / model |
| `contentType` | PDF, HTML, etc. |
| `publishDate` | As found on source |
| `ambilTanggal` | Timestamp when collected |
| `hash` | SHA-256 of file content |
| `status` | `new` · `updated` · `uploaded` · `upload-failed` · `skipped` · `potential-duplicate` |
| `sharepointUrl` | Final SharePoint web URL |
| `localPath` | Staging file path |

---

## Deduplication Logic (PRD §10)

| Condition | Action |
|---|---|
| Same URL + same hash | Skip (no change) |
| Same URL + different hash | Update (content changed) |
| Different URL + same hash | Add with status `potential-duplicate` |

---

## Security

- IBM password and Microsoft tokens are **never written to disk or logs**.
- Log entries with `token=`, `password=`, `Bearer …` are automatically redacted to `[REDACTED]`.
- `data/` is gitignored; `config.json` contains only non-secret config keys.

---

## Running Tests

```powershell
Install-Module Pester -Force -Scope CurrentUser
Invoke-Pester -Path ./tests -Output Detailed
```

---

## Adding Sources

Edit `data/config.json` to add custom sources:

```json
{
  "tenantId": "...",
  "siteId": "...",
  "sources": [
    { "Id": "my-source", "BaseUrl": "https://example.com/docs/", "Category": "Custom" }
  ]
}
```

---

## License

MIT
