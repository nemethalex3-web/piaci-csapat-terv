# Piaci Csapat – intraday terv feed

Ebben a repóban van a Stratéga aktuális napon belüli terve (`terv.txt`) és a MetaTrader 5-ös megjelenítő (`mt5/PiaciCsapatTerv.mq5`).
Az MT5 szakértői tanácsadó (EA) néhány percenként letölti a `terv.txt`-t, és kirajzolja a belépési zónát, az SL-t, a TP-ket és az érvénytelenítési szintet.

**Az EA nem kereskedik:** nem nyit, nem módosít és nem zár pozíciót, csak rajzol. A fájlban nincs számlaadat, lotméret vagy dolláros kockázat.
Tájékoztatás, nem befektetési tanács.

## A `terv.txt` formátuma

- Sima ASCII szöveg, egy sor = egy aktív terv (instrumentumonként legfeljebb egy).
- A `#`-tel kezdődő sorok megjegyzések. Az első sor: `# updated <unix idő> <budapesti ISO idő>`.
- A mezőket pontosvessző (`;`) választja el, ebben a sorrendben:

| # | Mező | Jelentés |
|---|------|----------|
| 1 | kulcs | `XAUUSD`, `NAS100`, `EURUSD` vagy `BTCUSD` |
| 2 | irány | `L` = long, `S` = short |
| 3 | entry_lo | belépési zóna alsó széle |
| 4 | entry_hi | belépési zóna felső széle |
| 5 | sl | stop loss |
| 6 | tp1 | első cél |
| 7 | tp2 | második cél (`0` = nincs) |
| 8 | tp3 | harmadik cél (`0` = nincs) |
| 9 | inv | érvénytelenítési szint (`0` = nincs) |
| 10 | start | a terv kezdete, unix másodperc (UTC) |
| 11 | expiry | a terv lejárata, unix másodperc (UTC) |
| 12 | id | a terv sorszáma a naplóban |
| 13 | megjegyzés | rövid szöveg, pontosvessző nélkül |

Példa:

```
# updated 1794688950 2026-11-14T21:42:30+01:00
BTCUSD;S;65900;66050;66250;65300;64980;64500;66200;1794687240;1794700800;12;TESZT
```

A tizedesjel pont. Az időket UTC-ben tároljuk; az EA a táblázatban budapesti idő szerint mutatja őket (nyári/téli időszámítással), a grafikonon pedig a bróker szerveridejére számolja át.

## Telepítés MetaTrader 5-be

1. Töltsd le az `mt5/PiaciCsapatTerv.mq5` fájlt (a fájl oldalán: „Download raw file”).
2. MT5: **Fájl > Adatmappa megnyitása**, majd másold a fájlt az `MQL5/Experts` mappába.
3. Nyisd meg a MetaEditorban (F4), és fordítsd le (**F7**). Hiba nélkül kell lefordulnia.
4. MT5: **Eszközök > Beállítások > Szakértői tanácsadók**: pipáld be az „Engedélyezd a WebRequest-et a következő URL-ekhez” lehetőséget, és add hozzá: `https://raw.githubusercontent.com`
5. A Navigátorban a *Szakértői tanácsadók* alatt húzd a `PiaciCsapatTerv`-et a grafikonra (XAUUSD, NAS100/US100, EURUSD vagy BTCUSD, 5 vagy 15 perces idősík).

Az „Algo Trading” gombot nem kell bekapcsolni: az EA anélkül is fut és rajzol, mert nem küld megbízást.

A szimbólumból az EA magától felismeri a kulcsot (XAU/GOLD → XAUUSD; NAS/US100/USTEC/NDX → NAS100; BTC → BTCUSD; EURUSD → EURUSD). Ha a brókered másképp nevezi, add meg kézzel az „Instrumentum kulcs” beállításban.
