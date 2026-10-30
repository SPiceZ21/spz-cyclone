# spz-cyclone

> Cyclone: a roaming tornado throws cars off the deck.

![version](https://img.shields.io/badge/version-1.0.0-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

Everyone drives on one big deck in the sky while a cyclone roams it, lifting cars and throwing them off. Last car standing wins the round.

## Features

- Roaming, chasing cyclone
- Multi-round matches
- Random car category per round

## Requirements

| Resource | Type |
|---|---|
| `ox_lib` | third-party |
| `oxmysql` | third-party |
| `spz-core` | SPiceZ module |
| `spz-identity` | SPiceZ module |
| `spz-progression` | SPiceZ module |
| `spz-minigames` | SPiceZ module |
| `spz-colorrush` | SPiceZ module |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-cyclone` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-cyclone
```

## Configuration

- `config.lua`

See the file for every option.

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)
