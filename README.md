# Singapore Rain Alert → Telegram

This uses NEA's open weather data (data.gov.sg) and runs on GitHub Actions every 5 minutes, so your computer can stay off. It sends a Telegram message when:

| Level | When | Message |
|---|---|---|
| 1 | Rain is forecast in an area next to yours (within 6 km) | "Rain may be coming" |
| 2 | Rain is forecast for **your** area (NEA 2-hour forecast) | "RAIN FORECAST… switch the pump on" |
| 3 | A rain gauge within 3 km of you recorded rain in the last 5 minutes | "IT IS RAINING near your house" |
| – | Everything is dry again | "All clear" |

You only get a message when the level goes **up**, plus one all-clear.

## `/update` command

Send `/update` in the chat to get the current forecast for your area and nearby areas, plus the latest reading from each rain gauge near you.

The reply comes on the bot's **next run**, usually within 5–15 minutes. It isn't instant, because GitHub only runs on a schedule. Press **Actions → Rain Alert → Run workflow** on GitHub for a faster answer.

## Settings (GitHub secrets)

**Settings → Secrets and variables → Actions:**

| Secret | Example |
|---|---|
| `TELEGRAM_BOT_TOKEN` | from @BotFather |
| `TELEGRAM_CHAT_ID` | `-123456789` |
| `HOME_AREA` | an NEA area name, e.g. `Tanglin` |
| `HOME_LAT`, `HOME_LON` | rough coordinates, 2 decimals, e.g. `1.30`, `103.80` |

Your location is kept in secrets, so nobody can see it even though the repo is public.

## Good to know

- **Timing:** GitHub sometimes starts scheduled runs a few minutes late when it's busy. Very rarely, it skips one.
- **Staying switched on:** GitHub pauses schedules in repos with no activity for 60 days. The workflow makes an empty commit once a month to prevent this.
- **Running it on Windows:** `rain-alert.ps1` works there too, using `config.json` or encrypted `secrets.dat`. Try `-DryRun`, `-Test` and `-ListAreas`.
