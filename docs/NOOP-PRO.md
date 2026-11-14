# NOOP Pro

A personal fork of [NOOP](https://github.com/ryanbr/noop) for iPhone that adds real-time Dexcom G7
glucose and a whole-body read-out on top of everything NOOP already computes from a WHOOP strap.
Not affiliated with WHOOP or Dexcom. Not a medical device.

## Install

1. Install [SideStore](https://sidestore.io) once (needs a computer for the first pairing only).
2. On the iPhone, open the
   [latest build](https://github.com/louisjclarke/noop-pro/releases/tag/nooppro-latest), download
   `NOOP-Pro.ipa`, Share → SideStore.
3. Settings → General → VPN & Device Management → trust your Apple ID if asked.
4. Free Apple ID signatures last 7 days: refresh in SideStore (or a weekly Shortcuts automation).
   A free ID allows 3 active sideloaded apps, SideStore included.

Every push to `main` rebuilds the IPA (workflow `NOOP Pro IPA`).

## Glucose sources (best first)

| Source | Delay | Needs |
|---|---|---|
| **G7 Bluetooth** (passive) | live, every 5 min | Dexcom G7 app on the same iPhone, signed in, receiving readings. NOOP Pro only listens; it never writes to the sensor. |
| **Dexcom Share** | ~5 min | Share turned on in the Dexcom app; your Dexcom login (stored in the Keychain). Region "Outside the US" for the UK. Used automatically when Bluetooth hasn't delivered for 7 min. |
| **Apple Health** | 3 h | Dexcom app writing to Health. Fills history and gaps. |
| **Finger-prick** | manual | Entered in Glucose settings. |

Keep the Dexcom app as your source for alarms and any treatment decision.

## What's added

- **More → NOOP Pro → Glucose**: live value + arrow, 24 h curve, time in target (general-health
  3.9–7.8 or diabetes 3.9–10.0 mmol/L), mean, CV, GMI, GRI, MAGE, LBGI/HBGI, 14-day ambulatory profile,
  detected rises with a response score, glucose during each night's sleep (lows, bedtime value, last
  rise before sleep) and each workout (start/end/lowest 3 h after), 30-day time-in-target, dawn rise,
  CSV export.
- **More → NOOP Pro → Whole Picture**: Recovery, Sleep, Load balance, Metabolic and Nervous-system
  domains on one 0–100 scale, today's off-baseline flags (including the multi-vital illness pattern),
  and glucose → recovery/HRV/RHR/sleep relationships learned from your own history.

Code: `Packages/StrandGlucose` (pure, unit-tested) and `StrandiOS/Glucose` (Bluetooth, network,
storage, screens). G7 message layouts after LoopKit G7SensorKit (MIT, see
`Packages/StrandGlucose/LICENSE-G7SensorKit-MIT`).

## How glucose connects to the rest of NOOP

Glucose never overwrites a strap measurement (HRV, resting HR, stress and sleep stay exactly what the
strap measured). It adds causes, and becomes an input where the science supports one:

| NOOP area | Link |
|---|---|
| **Explore / Compare / correlations** | 12 daily glucose metrics (Metabolic category, source "Dexcom") are ordinary NOOP metrics, so Explore's correlation sweep tests them against every other metric. |
| **Vitality / Body Age** | 14-day GMI adds a "Glucose control" factor (rising arm above 5.7 %, ARIC/Selvin 2010, conservative). |
| **Sleep, HRV, resting HR, recovery** | Each night is explained: overnight lows, late meals, high or unstable overnight glucose, delayed lows after hard training. Shown on Sleep, Glucose and Whole Picture. |
| **Stress** | Every high-stress hour is labelled: low / fast-falling glucose (adrenaline response), a glucose rise (meal), or steady glucose (genuine stress). |
| **Illness pattern** | A raised overnight glucose counts alongside skin temperature, resting HR, HRV and breathing rate. |
| **What Moves You** | Glucose is an outcome: journal behaviours (alcohol, caffeine, late meals…) → average glucose. |
| **Findings, both directions** | Glucose → recovery, HRV, RHR, sleep duration/efficiency/deep/disturbances, skin temp, breathing; sleep, recovery, HRV, strain, steps and stress → next-day or overnight glucose. |
| **AI Coach** | Every prompt carries the glucose summary, last night's explanation, stress × glucose and the strongest personal patterns. |
| **Fitness Age** | Deliberately unchanged: it is a VO₂max model of resting HR and activity, and glucose is not a term in it. Metabolic health is scored in Vitality instead. |
