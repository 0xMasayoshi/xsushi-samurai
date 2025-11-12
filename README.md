# Yojimbo 🤺

Minimal **SushiBar executor** for RedSnwapper.  
Handles **SUSHI ↔ xSUSHI** conversions with **minimum output** protection, providing safer execution than interacting with the SushiBar directly.

---

## Description

Yojimbo is a thin wrapper around **SushiBar (xSUSHI)** with clear methods to:

- Deposit SUSHI → receive xSUSHI (`enterSushiBar`)
- Withdraw xSUSHI → receive SUSHI (`leaveSushiBar`)
- Quote expected conversions on-chain (`quoteEnterSushiBar` / `quoteLeaveSushiBar`)

---

## Build & Test

### Install
```bash
forge install
```

### Build
```bash
forge build
```

### Test
```bash
forge test
```

---

## Deployment

**Network:** Ethereum Mainnet  
**Yojimbo Address:** `0xF4162050601F09E971194b4E9983f893442523EE`