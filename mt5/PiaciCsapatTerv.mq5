//+------------------------------------------------------------------+
//| PiaciCsapatTerv.mq5                                              |
//| Piaci Csapat – Stratéga intraday terv megjelenítő (MetaTrader 5) |
//|                                                                  |
//| Szakértői tanácsadó (EA), de SOHA NEM KERESKEDIK: nincs megbízás,|
//| nincs CTrade, nincs OrderSend. Csak letölti a tervet és rajzol.  |
//| (EA azért, mert indikátorból a WebRequest nem hívható.)          |
//|                                                                  |
//| A terv forrása: GitHub terv.txt (pontosvesszős, lásd README).    |
//| Nincs számlaadat, lot vagy dolláros kockázat.                    |
//| Tájékoztatás, nem befektetési tanács.                            |
//+------------------------------------------------------------------+
#property copyright "Piaci Csapat"
#property version   "1.00"
#property description "Stratéga intraday terv megjelenítő. Nem kereskedik, csak rajzol."

//--- Bemenetek (a megjegyzés a beállításokban felirataként jelenik meg)
input string          InpUrl        = "https://raw.githubusercontent.com/nemethalex3-web/piaci-csapat-terv/main/terv.txt"; // Terv URL (terv.txt)
input string          InpKey        = "";                 // Instrumentum kulcs (üres = automatikus: XAUUSD/NAS100/EURUSD/BTCUSD)
input int             InpRefreshSec = 120;                // Frissítés gyakorisága (másodperc)
input bool            InpShowEmas   = true;               // EMA 20 / 50 megjelenítése a grafikonon
input bool            InpShowTable  = true;               // Információs táblázat
input ENUM_BASE_CORNER InpCorner    = CORNER_RIGHT_UPPER; // Táblázat helye
input int             InpEmaFast    = 20;                 // Gyors EMA (grafikon)
input int             InpEmaSlow    = 50;                 // Lassú EMA (grafikon)
input int             InpHtfEma     = 50;                 // 1 órás EMA hossza
input double          InpNeutralPct = 0.10;               // 1H semleges sáv (%)
input bool            InpZoneFill   = true;               // Belépési zóna kitöltése
input color           InpColZone    = C'120,95,30';       // Szín: belépési zóna
input color           InpColZoneTxt = clrGoldenrod;     // Szín: zóna felirat
input color           InpColSl      = clrTomato;          // Szín: SL
input color           InpColTp      = clrMediumSeaGreen;  // Szín: TP1–TP3
input color           InpColInv     = clrOrange;          // Szín: érvénytelenítés
input color           InpColText    = clrWhiteSmoke;      // Szín: táblázat szöveg
input color           InpColBg      = C'27,30,43';        // Szín: táblázat háttér
input int             InpFontSize   = 9;                  // Betűméret

//--- Konstansok
#define PFX        "PCT_"
#define TBL_W      270
#define TBL_PAD    8
#define TBL_MARGIN 10

//--- Terv adatai (globális, nem másoljuk a struktúrát)
struct PlanT
  {
   bool              ok;
   bool              isLong;
   double            lo, hi, sl, tp1, tp2, tp3, inv;
   long              startUtc, expUtc;
   string            id, note;
  };
PlanT  g_plan;

string g_key        = "";
bool   g_keyAuto    = false;
string g_err        = "";       // utolsó letöltési hiba (üres = nincs)
long   g_feedUpdUtc = 0;        // a terv.txt "# updated" ideje
long   g_lastOkUtc  = 0;        // utolsó sikeres letöltés (UTC)
long   g_lastTryUtc = 0;
bool   g_everOk     = false;
datetime g_nextFetchLocal = 0;
datetime g_nextCalcLocal  = 0;
string g_status     = "Nincs aktív terv";

int    g_hFast = INVALID_HANDLE, g_hSlow = INVALID_HANDLE, g_hHtf = INVALID_HANDLE;
string g_indNames[];

//+------------------------------------------------------------------+
//| Segédfüggvények: idő                                             |
//+------------------------------------------------------------------+
// Adott év/hónap utolsó vasárnapja 01:00 UTC (EU nyári időszámítás váltás)
long LastSunday0100Utc(const int year, const int mon)
  {
   MqlDateTime d;
   ZeroMemory(d);
   d.year = year; d.mon = mon; d.day = 31; d.hour = 1; d.min = 0; d.sec = 0;
   datetime t = StructToTime(d);          // március és október is 31 napos
   MqlDateTime w;
   TimeToStruct(t, w);
   return (long)t - (long)w.day_of_week * 86400;
  }

// UTC unix -> budapesti helyi idő (CET/CEST, EU szabály)
long UtcToBudapest(const long utc)
  {
   MqlDateTime d;
   TimeToStruct((datetime)utc, d);
   long dstStart = LastSunday0100Utc(d.year, 3);
   long dstEnd   = LastSunday0100Utc(d.year, 10);
   bool dst = (utc >= dstStart && utc < dstEnd);
   return utc + (dst ? 7200 : 3600);
  }

string BudStr(const long utc, const bool withDate)
  {
   if(utc <= 0) return "—";
   MqlDateTime d;
   TimeToStruct((datetime)UtcToBudapest(utc), d);
   if(withDate)
      return StringFormat("%02d.%02d. %02d:%02d", d.mon, d.day, d.hour, d.min);
   return StringFormat("%02d:%02d", d.hour, d.min);
  }

// Szerveridő - UTC eltolás másodpercben, 15 percre kerekítve
long ServerOffset()
  {
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (long)MathRound((double)diff / 900.0) * 900;
  }

datetime UtcToServer(const long utc) { return (datetime)(utc + ServerOffset()); }

//+------------------------------------------------------------------+
//| Instrumentum kulcs                                               |
//+------------------------------------------------------------------+
string DetectKey()
  {
   string k = InpKey;
   StringTrimLeft(k); StringTrimRight(k);
   if(StringLen(k) > 0)
     {
      StringToUpper(k);
      g_keyAuto = false;
      return k;
     }
   g_keyAuto = true;
   string s = _Symbol;
   StringToUpper(s);
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return "XAUUSD";
   if(StringFind(s, "NAS") >= 0 || StringFind(s, "US100") >= 0 || StringFind(s, "USTEC") >= 0 ||
      StringFind(s, "NDX") >= 0 || StringFind(s, "NQ100") >= 0)                       return "NAS100";
   if(StringFind(s, "BTC") >= 0 || StringFind(s, "XBT") >= 0)                         return "BTCUSD";
   if(StringFind(s, "EURUSD") >= 0)                                                    return "EURUSD";
   return s; // ismeretlen: a szimbólum nevét keressük a fájlban
  }

//+------------------------------------------------------------------+
//| Letöltés és feldolgozás                                          |
//+------------------------------------------------------------------+
bool FetchFeed(string &text)
  {
   string url = InpUrl;
   url += (StringFind(url, "?") >= 0 ? "&" : "?") + "t=" + IntegerToString((long)TimeGMT());
   char   post[];
   char   result[];
   string resHeaders;
   string headers = "Cache-Control: no-cache\r\nUser-Agent: PiaciCsapatTerv-MT5\r\n";
   ResetLastError();
   int code = WebRequest("GET", url, headers, 5000, post, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         g_err = "Engedélyezd az URL-t: Eszközök > Beállítások > Szakértői tanácsadók|(https://raw.githubusercontent.com)";
      else
         g_err = "Letöltési hiba (kód " + IntegerToString(err) + ")|Ellenőrizd az internetkapcsolatot.";
      return false;
     }
   if(code != 200)
     {
      g_err = "Letöltési hiba: HTTP " + IntegerToString(code) + "|Ellenőrizd a Terv URL beállítást.";
      return false;
     }
   text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
  }

void ClearPlan()
  {
   g_plan.ok = false; g_plan.isLong = true;
   g_plan.lo = 0; g_plan.hi = 0; g_plan.sl = 0;
   g_plan.tp1 = 0; g_plan.tp2 = 0; g_plan.tp3 = 0; g_plan.inv = 0;
   g_plan.startUtc = 0; g_plan.expUtc = 0;
   g_plan.id = ""; g_plan.note = "";
  }

// A fájlból kiválasztja a g_key sorát. Több találat esetén a még nem lejártat részesíti előnyben.
void ParseFeed(const string text)
  {
   ClearPlan();
   string lines[];
   int n = StringSplit(text, '\n', lines);
   long nowUtc = (long)TimeGMT();
   for(int i = 0; i < n; i++)
     {
      string ln = lines[i];
      StringTrimLeft(ln); StringTrimRight(ln);
      if(StringLen(ln) == 0) continue;
      if(StringGetCharacter(ln, 0) == '#')
        {
         if(StringFind(ln, "# updated ") == 0)
           {
            string hp[];
            if(StringSplit(ln, ' ', hp) >= 3) g_feedUpdUtc = StringToInteger(hp[2]);
           }
         continue;
        }
      string f[];
      int nf = StringSplit(ln, ';', f);
      if(nf < 12) continue;
      string key = f[0];
      StringTrimLeft(key); StringTrimRight(key); StringToUpper(key);
      if(key != g_key) continue;
      string dir = f[1];
      StringTrimLeft(dir); StringTrimRight(dir); StringToUpper(dir);
      double lo  = StringToDouble(f[2]);
      double hi  = StringToDouble(f[3]);
      double sl  = StringToDouble(f[4]);
      double tp1 = StringToDouble(f[5]);
      long   st  = StringToInteger(f[9]);
      long   ex  = StringToInteger(f[10]);
      if(lo <= 0 || hi <= 0 || sl <= 0 || tp1 <= 0 || ex <= st || (dir != "L" && dir != "S")) continue;
      // már van nem lejárt találat -> azt megtartjuk
      if(g_plan.ok && g_plan.expUtc > nowUtc) continue;
      g_plan.ok       = true;
      g_plan.isLong   = (dir == "L");
      g_plan.lo       = MathMin(lo, hi);
      g_plan.hi       = MathMax(lo, hi);
      g_plan.sl       = sl;
      g_plan.tp1      = tp1;
      g_plan.tp2      = StringToDouble(f[6]);
      g_plan.tp3      = StringToDouble(f[7]);
      g_plan.inv      = StringToDouble(f[8]);
      g_plan.startUtc = st;
      g_plan.expUtc   = ex;
      g_plan.id       = f[11];
      g_plan.note     = (nf >= 13 ? f[12] : "");
     }
  }

void DoFetch()
  {
   g_lastTryUtc = (long)TimeGMT();
   string text;
   if(FetchFeed(text))
     {
      ParseFeed(text);
      g_err = "";
      g_everOk = true;
      g_lastOkUtc = g_lastTryUtc;
     }
   // hiba esetén az utolsó sikeres terv marad
  }

//+------------------------------------------------------------------+
//| Státusz és R:R                                                   |
//+------------------------------------------------------------------+
double RR(const double tp)
  {
   if(!g_plan.ok || tp <= 0) return EMPTY_VALUE;
   double ref  = g_plan.isLong ? g_plan.hi : g_plan.lo;     // kedvezőtlenebb zónaszél
   double risk = MathAbs(ref - g_plan.sl);
   if(risk <= 0) return EMPTY_VALUE;
   double rew = g_plan.isLong ? (tp - ref) : (ref - tp);
   return rew / risk;
  }

string RRTxt(const double tp)
  {
   if(tp <= 0) return "—";
   double r = RR(tp);
   if(r == EMPTY_VALUE || r <= 0) return "n/a";
   return DoubleToString(r, 2) + "R";
  }

// Gyertyák végigjárása a terv kezdetétől (M1, ha nincs: a grafikon idősíkja)
string ComputeStatus()
  {
   if(!g_plan.ok) return "Nincs aktív terv";
   long nowUtc = (long)TimeGMT();
   long off = ServerOffset();
   datetime startSrv = (datetime)(g_plan.startUtc + off);
   datetime expSrv   = (datetime)(g_plan.expUtc + off);
   datetime nowSrv   = TimeTradeServer();
   datetime stopSrv  = (nowSrv < expSrv ? nowSrv : expSrv);

   bool hadEntry = false, hitSL = false, hitInv = false;
   bool tp1 = false, tp2 = false, tp3 = false;
   bool terminal = false;
   string termStatus = "";

   if(stopSrv > startSrv)
     {
      MqlRates r[];
      ArraySetAsSeries(r, false);
      int cnt = CopyRates(_Symbol, PERIOD_M1, startSrv, stopSrv, r);
      if(cnt <= 0)
         cnt = CopyRates(_Symbol, _Period, startSrv, stopSrv, r);
      bool L = g_plan.isLong;
      for(int i = 0; i < cnt && !terminal; i++)
        {
         if(r[i].time < startSrv || r[i].time >= expSrv) continue;
         double h = r[i].high, lw = r[i].low;
         bool invNow = (g_plan.inv > 0) && (L ? lw <= g_plan.inv : h >= g_plan.inv);
         if(!hadEntry && invNow)
           { terminal = true; termStatus = "Érvénytelen"; break; }
         if(h >= g_plan.lo && lw <= g_plan.hi) hadEntry = true;
         if(!hadEntry) continue;
         bool slNow  = (L ? lw <= g_plan.sl : h >= g_plan.sl);
         bool anyTpBefore = (tp1 || tp2 || tp3);
         if(slNow)
           {
            hitSL = true;
            terminal = true;
            // ugyanazon a gyertyán SL és TP: konzervatívan SL; korábbi TP után a TP marad
            termStatus = anyTpBefore ? "" : "SL elérve";
            break;
           }
         if(invNow && !tp1)
           { hitInv = true; terminal = true; termStatus = "Érvénytelen"; break; }
         if(L ? h >= g_plan.tp1 : lw <= g_plan.tp1) tp1 = true;
         if(g_plan.tp2 > 0 && (L ? h >= g_plan.tp2 : lw <= g_plan.tp2)) tp2 = true;
         if(g_plan.tp3 > 0 && (L ? h >= g_plan.tp3 : lw <= g_plan.tp3)) { tp3 = true; terminal = true; }
        }
     }
   if(termStatus != "") return termStatus;
   if(tp3) return "TP3 elérve";
   if(tp2) return "TP2 elérve";
   if(tp1) return "TP1 elérve";
   if(nowUtc >= g_plan.expUtc) return "Lejárt";
   if(hadEntry) return "Belépés zónában";
   return "Vár belépésre";
  }

//+------------------------------------------------------------------+
//| Trend                                                            |
//+------------------------------------------------------------------+
string HtfTrend()
  {
   if(g_hHtf == INVALID_HANDLE) return "—";
   double e[];
   if(CopyBuffer(g_hHtf, 0, 1, 1, e) != 1) return "Betöltés…";
   double c = iClose(_Symbol, PERIOD_H1, 1);       // utolsó lezárt 1 órás gyertya
   if(c <= 0 || e[0] <= 0) return "Betöltés…";
   double distPct = MathAbs(c - e[0]) / e[0] * 100.0;
   if(distPct <= InpNeutralPct) return "Semleges";
   return (c > e[0]) ? "Emelkedő" : "Csökkenő";
  }

string ChartTrend()
  {
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE) return "—";
   double f[], s[];
   if(CopyBuffer(g_hFast, 0, 0, 1, f) != 1 || CopyBuffer(g_hSlow, 0, 0, 1, s) != 1) return "Betöltés…";
   double c = iClose(_Symbol, _Period, 0);
   if(c <= 0) return "Betöltés…";
   if(f[0] > s[0] && c > f[0]) return "Emelkedő";
   if(f[0] < s[0] && c < f[0]) return "Csökkenő";
   return "Semleges";
  }

color TrendCol(const string t)
  {
   if(t == "Emelkedő" || t == "LONG") return InpColTp;
   if(t == "Csökkenő" || t == "SHORT") return InpColSl;
   return clrSilver;
  }

color StatusCol(const string s)
  {
   if(StringFind(s, "TP") == 0) return InpColTp;
   if(s == "SL elérve") return InpColSl;
   if(s == "Érvénytelen") return InpColInv;
   if(s == "Belépés zónában") return clrGold;
   return clrSilver;
  }

//+------------------------------------------------------------------+
//| Objektum segédek                                                 |
//+------------------------------------------------------------------+
void ObjCommon(const string name)
  {
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void Rect(const string name, datetime t1, double p1, datetime t2, double p2, color col)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjCommon(name);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FILL, InpZoneFill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
  }

void HLine(const string name, datetime t1, datetime t2, double p, color col, ENUM_LINE_STYLE style, int width)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p, t2, p);
      ObjCommon(name);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

void Text(const string name, datetime t, double p, const string txt, color col, ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
      ObjCommon(name);
     }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
  }

void Del(const string name) { if(ObjectFind(0, name) >= 0) ObjectDelete(0, name); }

string Px(const double p) { return DoubleToString(p, _Digits); }

//+------------------------------------------------------------------+
//| Terv rajzolása                                                   |
//+------------------------------------------------------------------+
void DrawPlan()
  {
   string lineNames[5];
   lineNames[0] = PFX + "SL";  lineNames[1] = PFX + "TP1"; lineNames[2] = PFX + "TP2";
   lineNames[3] = PFX + "TP3"; lineNames[4] = PFX + "INV";
   if(!g_plan.ok)
     {
      Del(PFX + "ZONE"); Del(PFX + "ZONE_T");
      for(int i = 0; i < 5; i++) { Del(lineNames[i]); Del(lineNames[i] + "_T"); }
      return;
     }
   long off = ServerOffset();
   datetime t1 = (datetime)(g_plan.startUtc + off);
   datetime t2 = (datetime)(g_plan.expUtc + off);

   // zóna (ha a két szél azonos, kicsit megnyitjuk, hogy látszódjon)
   double top = g_plan.hi, bot = g_plan.lo;
   if(top == bot) { top += 2 * _Point; bot -= 2 * _Point; }
   Rect(PFX + "ZONE", t1, top, t2, bot, InpColZone);
   string zt = (g_plan.isLong ? "LONG" : "SHORT") + " zóna " + Px(g_plan.lo) + "–" + Px(g_plan.hi) +
               (g_plan.id != "" ? "  #" + g_plan.id : "") + (g_plan.note != "" ? "  " + g_plan.note : "");
   Text(PFX + "ZONE_T", t1, top, zt, InpColZoneTxt, ANCHOR_LEFT_LOWER);

   // vonalak + feliratok
   double prices[5];
   string texts[5];
   color  cols[5];
   bool   on[5];
   ENUM_LINE_STYLE styles[5] = {STYLE_SOLID, STYLE_SOLID, STYLE_DASH, STYLE_DOT, STYLE_DASHDOT};
   int    widths[5] = {2, 2, 1, 1, 1};
   prices[0] = g_plan.sl;  texts[0] = "SL  " + Px(g_plan.sl);                                     cols[0] = InpColSl;  on[0] = g_plan.sl > 0;
   prices[1] = g_plan.tp1; texts[1] = "TP1  " + Px(g_plan.tp1) + "  (" + RRTxt(g_plan.tp1) + ")"; cols[1] = InpColTp;  on[1] = g_plan.tp1 > 0;
   prices[2] = g_plan.tp2; texts[2] = "TP2  " + Px(g_plan.tp2) + "  (" + RRTxt(g_plan.tp2) + ")"; cols[2] = InpColTp;  on[2] = g_plan.tp2 > 0;
   prices[3] = g_plan.tp3; texts[3] = "TP3  " + Px(g_plan.tp3) + "  (" + RRTxt(g_plan.tp3) + ")"; cols[3] = InpColTp;  on[3] = g_plan.tp3 > 0;
   prices[4] = g_plan.inv; texts[4] = "Érvénytelen  " + Px(g_plan.inv);                           cols[4] = InpColInv; on[4] = g_plan.inv > 0;

   // feliratok függőleges széthúzása, hogy közeli szinteknél ne fedjék egymást
   double pmax = ChartGetDouble(0, CHART_PRICE_MAX, 0);
   double pmin = ChartGetDouble(0, CHART_PRICE_MIN, 0);
   long   hpx  = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   double sep  = 0;
   if(hpx > 0 && pmax > pmin)
      sep = (pmax - pmin) * (double)(InpFontSize * 2 + 2) / (double)hpx;
   int    idx[5];
   int    m = 0;
   for(int i = 0; i < 5; i++) if(on[i]) idx[m++] = i;
   // beszúrásos rendezés ár szerint növekvő
   for(int a = 1; a < m; a++)
     {
      int v = idx[a];
      int b = a - 1;
      while(b >= 0 && prices[idx[b]] > prices[v]) { idx[b + 1] = idx[b]; b--; }
      idx[b + 1] = v;
     }
   double ly[5];
   for(int i = 0; i < 5; i++) ly[i] = prices[i];
   for(int a = 1; a < m; a++)
     {
      int cur = idx[a], prv = idx[a - 1];
      if(ly[cur] < ly[prv] + sep) ly[cur] = ly[prv] + sep;
     }

   for(int i = 0; i < 5; i++)
     {
      if(on[i])
        {
         HLine(lineNames[i], t1, t2, prices[i], cols[i], styles[i], widths[i]);
         Text(lineNames[i] + "_T", t2, ly[i], "  " + texts[i], cols[i], ANCHOR_LEFT);
        }
      else
        {
         Del(lineNames[i]);
         Del(lineNames[i] + "_T");
        }
     }
  }

//+------------------------------------------------------------------+
//| Táblázat                                                         |
//+------------------------------------------------------------------+
bool IsRightCorner() { return InpCorner == CORNER_RIGHT_UPPER || InpCorner == CORNER_RIGHT_LOWER; }
bool IsLowerCorner() { return InpCorner == CORNER_LEFT_LOWER  || InpCorner == CORNER_RIGHT_LOWER; }

void Lbl(const string name, int x, int y, const string txt, color col, ENUM_ANCHOR_POINT anchor, int fsize)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjCommon(name);
     }
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fsize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

void DrawTable(const string htf, const string ltf)
  {
   ObjectsDeleteAll(0, PFX + "TBL_");
   if(!InpShowTable) return;

   string overall = "SEMLEGES";
   if(htf == "Emelkedő" && ltf == "Emelkedő") overall = "LONG";
   else if(htf == "Csökkenő" && ltf == "Csökkenő") overall = "SHORT";

   string names[];
   string vals[];
   color  vcols[];
   int    n = 0;
   ArrayResize(names, 20); ArrayResize(vals, 20); ArrayResize(vcols, 20);
   string planDir = g_plan.ok ? (g_plan.isLong ? "LONG" : "SHORT") : "Nincs";
   names[n] = "1H trend";      vals[n] = htf;                                   vcols[n] = TrendCol(htf); n++;
   names[n] = "Grafikon trend"; vals[n] = ltf;                                  vcols[n] = TrendCol(ltf); n++;
   names[n] = "Irány";         vals[n] = overall;                               vcols[n] = TrendCol(overall); n++;
   names[n] = "Terv iránya";   vals[n] = planDir + (g_plan.ok && g_plan.id != "" ? "  #" + g_plan.id : ""); vcols[n] = g_plan.ok ? TrendCol(planDir) : clrSilver; n++;
   names[n] = "Zóna";          vals[n] = g_plan.ok ? Px(g_plan.lo) + "–" + Px(g_plan.hi) : "—"; vcols[n] = InpColText; n++;
   names[n] = "TP1 R:R";       vals[n] = g_plan.ok ? RRTxt(g_plan.tp1) : "—";  vcols[n] = InpColText; n++;
   names[n] = "TP2 R:R";       vals[n] = g_plan.ok ? RRTxt(g_plan.tp2) : "—";  vcols[n] = InpColText; n++;
   names[n] = "TP3 R:R";       vals[n] = g_plan.ok ? RRTxt(g_plan.tp3) : "—";  vcols[n] = InpColText; n++;
   names[n] = "R:R bázis";     vals[n] = "zóna széle";                          vcols[n] = clrSilver; n++;
   names[n] = "Kezdet";        vals[n] = g_plan.ok ? BudStr(g_plan.startUtc, true) : "—"; vcols[n] = InpColText; n++;
   names[n] = "Lejárat";       vals[n] = g_plan.ok ? BudStr(g_plan.expUtc, true) : "—";   vcols[n] = InpColText; n++;
   names[n] = "Státusz";       vals[n] = g_status;                              vcols[n] = StatusCol(g_status); n++;
   if(g_plan.ok && g_plan.note != "")
     { names[n] = "Megjegyzés"; vals[n] = g_plan.note; vcols[n] = clrSilver; n++; }
   names[n] = "Terv frissítve"; vals[n] = g_feedUpdUtc > 0 ? BudStr(g_feedUpdUtc, true) : "—"; vcols[n] = InpColText; n++;
   names[n] = "Utolsó letöltés"; vals[n] = g_lastOkUtc > 0 ? BudStr(g_lastOkUtc, true) : "—"; vcols[n] = g_err == "" ? InpColText : InpColSl; n++;

   string errLines[];
   int ne = 0;
   if(g_err != "") ne = StringSplit(g_err, '|', errLines);
   if(!g_plan.ok && g_everOk && g_err == "")
     {
      ArrayResize(errLines, 1);
      errLines[0] = "Nincs terv erre: " + g_key + (g_keyAuto ? " (automatikus)" : "");
      ne = 1;
     }

   int fs    = InpFontSize;
   int rowH  = fs * 2;
   int titleH = rowH + 4;
   int H = TBL_PAD * 2 + titleH + n * rowH + (ne > 0 ? ne * rowH + 4 : 0);
   bool right = IsRightCorner(), lower = IsLowerCorner();

   // háttér: az OBJ_RECTANGLE_LABEL rögzítési pontja mindig a bal felső sarka
   string bg = PFX + "TBL_BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjCommon(bg);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, right ? TBL_MARGIN + TBL_W : TBL_MARGIN);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, lower ? TBL_MARGIN + H : TBL_MARGIN);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, TBL_W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, H);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpColBg);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDarkGoldenrod);
   ObjectSetInteger(0, bg, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);

   // oszlopok x-távolsága a választott saroktól
   int xL = right ? TBL_MARGIN + TBL_W - TBL_PAD : TBL_MARGIN + TBL_PAD;   // bal oldali szöveg kezdete
   int xR = right ? TBL_MARGIN + TBL_PAD : TBL_MARGIN + TBL_W - TBL_PAD;   // jobb oldali szöveg vége
   ENUM_ANCHOR_POINT aL = ANCHOR_LEFT_UPPER;   // alsó sarkoknál is: a szöveg a ponttól lefelé
   ENUM_ANCHOR_POINT aR = ANCHOR_RIGHT_UPPER;
   // y: felső sarkoknál lefelé nő, alsóknál a táblázat tetejétől számolunk vissza
   int yTop = lower ? TBL_MARGIN + H - TBL_PAD : TBL_MARGIN + TBL_PAD;
   int dir  = lower ? -1 : 1;

   Lbl(PFX + "TBL_TITLE", xL, yTop, "Piaci Csapat terv  –  " + g_key, clrGoldenrod, aL, fs + 1);
   for(int i = 0; i < n; i++)
     {
      int y = yTop + dir * (titleH + i * rowH);
      Lbl(PFX + "TBL_N" + IntegerToString(i), xL, y, names[i], clrSilver, aL, fs);
      Lbl(PFX + "TBL_V" + IntegerToString(i), xR, y, vals[i], vcols[i], aR, fs);
     }
   for(int j = 0; j < ne; j++)
     {
      int y = yTop + dir * (titleH + n * rowH + 4 + j * rowH);
      Lbl(PFX + "TBL_E" + IntegerToString(j), xL, y, errLines[j], (g_err != "" ? InpColSl : clrSilver), aL, fs - 1);
     }
  }

//+------------------------------------------------------------------+
//| Frissítés                                                        |
//+------------------------------------------------------------------+
void Recalc()
  {
   g_status = ComputeStatus();
   DrawPlan();
   DrawTable(HtfTrend(), ChartTrend());
   ChartRedraw(0);
  }

void AddEmas()
  {
   ArrayResize(g_indNames, 0);
   if(!InpShowEmas) return;
   int hs[2];
   hs[0] = g_hFast; hs[1] = g_hSlow;
   for(int i = 0; i < 2; i++)
     {
      if(hs[i] == INVALID_HANDLE) continue;
      int before = ChartIndicatorsTotal(0, 0);
      if(ChartIndicatorAdd(0, 0, hs[i]))
        {
         int after = ChartIndicatorsTotal(0, 0);
         if(after > before)
           {
            int k = ArraySize(g_indNames);
            ArrayResize(g_indNames, k + 1);
            g_indNames[k] = ChartIndicatorName(0, 0, after - 1);
           }
        }
      else
         PrintFormat("PiaciCsapatTerv: EMA hozzáadása nem sikerült (hiba %d)", GetLastError());
     }
  }

void RemoveEmas()
  {
   for(int i = 0; i < ArraySize(g_indNames); i++)
      if(g_indNames[i] != "") ChartIndicatorDelete(0, 0, g_indNames[i]);
   ArrayResize(g_indNames, 0);
  }

//+------------------------------------------------------------------+
//| Eseménykezelők                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   ClearPlan();
   g_key = DetectKey();
   g_hFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hHtf  = iMA(_Symbol, PERIOD_H1, InpHtfEma, 0, MODE_EMA, PRICE_CLOSE);
   AddEmas();
   g_nextFetchLocal = 0;
   g_nextCalcLocal  = 0;
   if(!EventSetTimer(1))
     {
      Print("PiaciCsapatTerv: az időzítő nem indult el");
      return INIT_FAILED;
     }
   PrintFormat("PiaciCsapatTerv: kulcs=%s (%s), forrás=%s. Ez az EA nem kereskedik, csak rajzol.",
               g_key, g_keyAuto ? "automatikus" : "kézi", InpUrl);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   RemoveEmas();
   if(g_hFast != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hHtf  != INVALID_HANDLE) IndicatorRelease(g_hHtf);
   g_hFast = g_hSlow = g_hHtf = INVALID_HANDLE;
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
  }

void OnTimer()
  {
   datetime nowL = TimeLocal();
   bool changed = false;
   if(nowL >= g_nextFetchLocal)
     {
      DoFetch();
      int sec = (InpRefreshSec < 30 ? 30 : InpRefreshSec);
      g_nextFetchLocal = nowL + sec;
      changed = true;
     }
   if(changed || nowL >= g_nextCalcLocal)
     {
      Recalc();
      g_nextCalcLocal = nowL + 5;
     }
  }

void OnTick()
  {
   // szándékosan üres: az EA nem kereskedik; a frissítést az időzítő végzi
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      DrawPlan();          // nagyítás / görgetés után a feliratok távolságának újraszámolása
      ChartRedraw(0);
     }
  }
//+------------------------------------------------------------------+
