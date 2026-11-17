//+------------------------------------------------------------------+
//|                                  Azimuth_Tick_Audit_Exporter.mq5 |
//|                                  Copyright 2026, Azimuth Studio  |
//|                                             https://azimuthstudio.app |
//+------------------------------------------------------------------+
// Read-only forensic utility for MetaTrader 5 (zero trading orders,
// zero DLLs, zero network calls):
//   1. Streams real broker Bid/Ask ticks via CopyTicksRange in 15-day
//      RAM-safe chunks (up to 120 months).
//   2. Computes session-by-session real spread percentiles (Median P50
//      & P95 in pips) across London/NY Overlap, London, Asia, and the
//      23:00-00:15 Rollover window (Rollover widening multiplier).
//   3. Detects inverted quotes (Ask < Bid), non-monotonic millisecond
//      timestamps, and the Top 3 longest weekday intraday feed gaps.
//   4. Saves a standalone forensic report (TickAudit_*.txt) and an
//      optional clean UTF-8 TSV/CSV tick file in MQL5\Files\ ready for
//      quantitative Walk-Forward & slippage stress analysis.
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Azimuth Studio"
#property link        "https://azimuthstudio.app/?utm_source=github_mt5_tools"
#property version     "1.10"
#property description "Read-only Broker Tick & Rollover Spread Forensic Auditor + Chunked CSV Exporter."
#property description "Audits weekday quote gaps, P50/P95 session spreads, 23:00-00:15 rollover spikes, and exports clean Bid/Ask ticks."
#property script_show_inputs

enum ENUM_AZM_AUDIT_MODE
  {
   AZM_MODE_TICKS_AUDIT_AND_CSV = 0, // Audit Real Ticks + Export Clean CSV (Recommended)
   AZM_MODE_TICKS_AUDIT_ONLY    = 1, // Audit Real Ticks Only (Fast Forensic Report, No CSV)
   AZM_MODE_M1_BARS_CSV         = 2  // Export M1 OHLC + Spread CSV (Lightweight)
  };

input group "=== Broker Tick & Rollover Spread Forensic Audit ==="
input ENUM_AZM_AUDIT_MODE InpMode                = AZM_MODE_TICKS_AUDIT_AND_CSV; // Execution Mode
input int                 InpMonthsBack          = 12;                           // History Depth (Months: 1..120)
input string              InpCustomSymbol        = "";                           // Symbol (Empty = Current Chart)
input int                 InpGapThresholdMinutes = 15;                           // Weekday Intraday Gap Threshold (Minutes)
input bool                InpShowSummaryDialog   = true;                         // Show Summary Dialog When Finished

#define AZM_HIST_MAX_PTS 5000

//+------------------------------------------------------------------+
//| Sanitize metadata value (strip semicolons, tabs, CR/LF)          |
//+------------------------------------------------------------------+
string AzmCleanMeta(const string raw)
  {
   string s = raw;
   StringReplace(s, ";", ",");
   StringReplace(s, "\t", " ");
   StringReplace(s, "\r", "");
   StringReplace(s, "\n", "");
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
//| Sanitize symbol token for cross-platform file names              |
//+------------------------------------------------------------------+
string AzmSafeFileToken(const string raw)
  {
   string out = "";
   int len = StringLen(raw);
   for(int i = 0; i < len; i++)
     {
      ushort ch = StringGetCharacter(raw, i);
      bool ok = ((ch >= 'A' && ch <= 'Z') ||
                 (ch >= 'a' && ch <= 'z') ||
                 (ch >= '0' && ch <= '9') ||
                 ch == '_' || ch == '-' || ch == '.');
      out += ok ? ShortToString(ch) : "_";
     }
   return (StringLen(out) > 0) ? out : "SYMBOL";
  }

//+------------------------------------------------------------------+
//| Resolve broker suffix automatically (e.g. EURUSD -> EURUSD.raw)  |
//+------------------------------------------------------------------+
string AzmBaseSymbol(const string rawSym)
  {
   string sym = rawSym;
   StringTrimLeft(sym);
   StringTrimRight(sym);
   int len = StringLen(sym);
   if(len <= 0)
      return "";
   if(len > 6 && (StringGetCharacter(sym, 0) == '#' || StringGetCharacter(sym, 0) == '.'))
     {
      sym = StringSubstr(sym, 1);
      len = StringLen(sym);
     }
   string seps = "._-#+!";
   for(int i = 3; i < len; i++)
     {
      ushort ch = StringGetCharacter(sym, i);
      if(StringFind(seps, ShortToString(ch)) >= 0)
         return StringSubstr(sym, 0, i);
     }
   if(len > 6)
     {
      bool upper6 = true;
      for(int k = 0; k < 6; k++)
        {
         ushort c = StringGetCharacter(sym, k);
         if(c < 'A' || c > 'Z')
           {
            upper6 = false;
            break;
           }
        }
      ushort c6 = StringGetCharacter(sym, 6);
      if(upper6 && c6 >= 'a' && c6 <= 'z')
         return StringSubstr(sym, 0, 6);
     }
   return sym;
  }

string AzmResolveSymbol(const string requested, const string chartSym)
  {
   if(SymbolSelect(requested, true))
      return requested;
   string base = AzmBaseSymbol(requested);
   string chartBase = AzmBaseSymbol(chartSym);
   if(StringLen(chartBase) > 0 && StringLen(chartSym) > StringLen(chartBase))
     {
      string suffix = StringSubstr(chartSym, StringLen(chartBase));
      string cand = base + suffix;
      if(SymbolSelect(cand, true))
         return cand;
     }
   if(base != requested && SymbolSelect(base, true))
      return base;
   return requested;
  }

//+------------------------------------------------------------------+
//| Exact histogram percentile in points (0..AZM_HIST_MAX_PTS)       |
//+------------------------------------------------------------------+
double AzmPercentilePts(const long &hist[], const long totalCount, const double quantile)
  {
   if(totalCount <= 0)
      return 0.0;
   long target = (long)MathCeil((double)totalCount * quantile);
   if(target < 1)
      target = 1;
   long cum = 0;
   for(int b = 0; b <= AZM_HIST_MAX_PTS; b++)
     {
      cum += hist[b];
      if(cum >= target)
         return (double)b;
     }
   return (double)AZM_HIST_MAX_PTS;
  }

//+------------------------------------------------------------------+
//| Ignore expected weekend closure & Christmas / New Year holidays  |
//+------------------------------------------------------------------+
bool AzmIsExpectedClosure(const datetime prevSec, const datetime curSec)
  {
   MqlDateTime d1, d2;
   TimeToStruct(prevSec, d1);
   TimeToStruct(curSec, d2);

   // Weekend market close (Friday >= 20:00 server time or Saturday/Sunday)
   if(d1.day_of_week == 6 || d1.day_of_week == 0 || d2.day_of_week == 6 || d2.day_of_week == 0)
      return true;
   if(d1.day_of_week == 5 && d1.hour >= 20)
      return true;
   if(d2.day_of_week == 1 && d2.hour <= 2 && (curSec - prevSec) > 36 * 3600)
      return true;

   // Major global bank holidays (Dec 25 & Jan 1)
   if((d1.mon == 12 && (d1.day == 24 || d1.day == 25)) || (d2.mon == 12 && d2.day == 26))
      return true;
   if((d1.mon == 12 && d1.day == 31) || (d2.mon == 1 && (d2.day == 1 || d2.day == 2)))
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//| Maintain Top 3 longest weekday intraday feed blackouts           |
//+------------------------------------------------------------------+
void AzmRecordGap(const long gapSec,
                  const datetime gapFrom,
                  const datetime gapTo,
                  long &topDur[],
                  datetime &topFrom[],
                  datetime &topTo[])
  {
   for(int pos = 0; pos < 3; pos++)
     {
      if(gapSec > topDur[pos])
        {
         for(int shift = 2; shift > pos; shift--)
           {
            topDur[shift]  = topDur[shift - 1];
            topFrom[shift] = topFrom[shift - 1];
            topTo[shift]   = topTo[shift - 1];
           }
         topDur[pos]  = gapSec;
         topFrom[pos] = gapFrom;
         topTo[pos]   = gapTo;
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Script Entry Point                                               |
//+------------------------------------------------------------------+
void OnStart()
  {
   string sym = InpCustomSymbol;
   StringTrimLeft(sym);
   StringTrimRight(sym);
   if(StringLen(sym) == 0)
      sym = _Symbol;
   else
      sym = AzmResolveSymbol(sym, _Symbol);

   if(!SymbolSelect(sym, true))
     {
      PrintFormat("[Tick Audit] Symbol not found in Market Watch: %s (error %d)", sym, GetLastError());
      if(InpShowSummaryDialog)
         MessageBox("Symbol not found in MetaTrader 5: " + sym, "Tick Audit & Exporter", MB_OK | MB_ICONERROR);
      return;
     }

   int months = MathMax(1, MathMin(120, InpMonthsBack));
   int gapMin = MathMax(2, MathMin(1440, InpGapThresholdMinutes));
   long gapThresholdMs = (long)gapMin * 60LL * 1000LL;

   datetime endSec = TimeCurrent();
   if(endSec <= 0)
      endSec = TimeTradeServer();
   if(endSec <= 0)
      endSec = TimeLocal();

   long spanSec = (long)months * 30LL * 86400LL + (long)(months / 2) * 86400LL;
   datetime startSec = (datetime)MathMax(0LL, (long)endSec - spanSec);

   int    digits       = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pointVal     = SymbolInfoDouble(sym, SYMBOL_POINT);
   double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   long   spreadNowPts = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   string brokerName   = AzmCleanMeta(AccountInfoString(ACCOUNT_COMPANY));
   string acctCurrency = AzmCleanMeta(AccountInfoString(ACCOUNT_CURRENCY));

   if(StringLen(brokerName) == 0)
      brokerName = "MT5_Broker";
   if(StringLen(acctCurrency) == 0)
      acctCurrency = "USD";
   if(digits < 0 || digits > 10)
      digits = 5;
   if(pointVal <= 0.0)
      pointVal = MathPow(10.0, -digits);

   // Pip conversion factor (5-digit / 3-digit fractional pip = 10 points per pip)
   double ptsPerPip = (digits == 5 || digits == 3) ? 10.0 : 1.0;

   MqlDateTime dtEnd;
   TimeToStruct(endSec, dtEnd);
   string safeSym = AzmSafeFileToken(sym);

   bool writeCsv  = (InpMode == AZM_MODE_TICKS_AUDIT_AND_CSV || InpMode == AZM_MODE_M1_BARS_CSV);
   bool ticksMode = (InpMode != AZM_MODE_M1_BARS_CSV);

   string modeTag  = ticksMode ? "TICKS" : "M1";
   string modeMeta = ticksMode ? "ticks" : "bars";
   string csvName  = StringFormat("Azimuth_%s_%s_%04d%02d%02d.csv", safeSym, modeTag, dtEnd.year, dtEnd.mon, dtEnd.day);
   string rptName  = StringFormat("TickAudit_%s_%04d%02d%02d.txt", safeSym, dtEnd.year, dtEnd.mon, dtEnd.day);

   int csvHandle = INVALID_HANDLE;
   if(writeCsv)
     {
      ResetLastError();
      csvHandle = FileOpen(csvName, FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
      if(csvHandle == INVALID_HANDLE)
        {
         PrintFormat("[Tick Audit] Failed to create MQL5\\Files\\%s (error %d)", csvName, GetLastError());
         return;
        }
      string metaHeader = StringFormat(
         "#AZIMUTH_META:v=1;symbol=%s;broker=%s;currency=%s;contract=%.2f;digits=%d;point=%.8f;spread_pts=%I64d;mode=%s\r\n",
         AzmCleanMeta(sym), brokerName, acctCurrency, contractSize, digits, pointVal, spreadNowPts, modeMeta
      );
      FileWriteString(csvHandle, metaHeader);
     }

   // Spread histograms in points (0..AZM_HIST_MAX_PTS)
   long histAll[];
   long histOverlap[];
   long histLondon[];
   long histAsia[];
   long histRollover[];
   ArrayResize(histAll,      AZM_HIST_MAX_PTS + 1);
   ArrayResize(histOverlap,  AZM_HIST_MAX_PTS + 1);
   ArrayResize(histLondon,   AZM_HIST_MAX_PTS + 1);
   ArrayResize(histAsia,     AZM_HIST_MAX_PTS + 1);
   ArrayResize(histRollover, AZM_HIST_MAX_PTS + 1);
   ArrayInitialize(histAll,      0);
   ArrayInitialize(histOverlap,  0);
   ArrayInitialize(histLondon,   0);
   ArrayInitialize(histAsia,     0);
   ArrayInitialize(histRollover, 0);

   long cntAll = 0, cntOverlap = 0, cntLondon = 0, cntAsia = 0, cntRollover = 0;
   long invertedQuotes = 0;
   long nonMonotonicTicks = 0;
   long zeroSideTicks = 0;
   long maxRolloverSpreadPts = 0;
   long weekdayGapCount = 0;

   long     topGapSec[3]  = {0, 0, 0};
   datetime topGapFrom[3] = {0, 0, 0};
   datetime topGapTo[3]   = {0, 0, 0};

   long     prevTickMs = 0;
   datetime firstQuoteSec = 0;
   datetime lastQuoteSec  = 0;
   long     totalRows = 0;
   ulong    t0 = GetTickCount64();

   if(ticksMode)
     {
      if(writeCsv)
         FileWriteString(csvHandle, "<DATE>\t<TIME>\t<BID>\t<ASK>\t<VOLUME>\r\n");

      long startMs = (long)startSec * 1000LL;
      long endMs   = (long)endSec * 1000LL + 999LL;
      long chunkMs = 15LL * 86400LL * 1000LL;

      // Warm-up probe on the last 7 days so MT5 syncs .tkc tick containers if cold
      long probeMs = MathMax(startMs, endMs - 7LL * 86400LL * 1000LL);
      for(int w = 0; w < 12 && !IsStopped(); w++)
        {
         MqlTick probe[];
         int got = CopyTicksRange(sym, probe, COPY_TICKS_ALL, (ulong)probeMs, (ulong)endMs);
         ArrayFree(probe);
         if(got > 0 || (!TerminalInfoInteger(TERMINAL_CONNECTED) && w >= 1))
            break;
         Comment(StringFormat("\n\n\n\n\n\n\n[Tick Audit] Syncing %s tick container from broker (%d/12)...", sym, w + 1));
         Sleep(1200);
        }

      long curStartMs = startMs;
      int  stepIdx = 0;
      int  totalSteps = (int)MathMax(1LL, ((endMs - startMs) / chunkMs) + 1LL);

      while(curStartMs <= endMs && !IsStopped())
        {
         stepIdx++;
         long curEndMs = MathMin(endMs, curStartMs + chunkMs - 1LL);
         Comment(StringFormat("\n\n\n\n\n\n\n[Tick Audit] Auditing %s (%d/%d) — %I64d ticks analyzed...",
                              sym, stepIdx, totalSteps, totalRows));

         MqlTick ticks[];
         ResetLastError();
         int copied = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, (ulong)curStartMs, (ulong)curEndMs);
         if(copied < 0 && TerminalInfoInteger(TERMINAL_CONNECTED))
           {
            int err = GetLastError();
            if(err == 4401 || err == 4403)
              {
               for(int r = 0; r < 3 && copied < 0 && !IsStopped(); r++)
                 {
                  Sleep(700);
                  copied = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, (ulong)curStartMs, (ulong)curEndMs);
                 }
              }
           }

         if(copied > 0)
           {
            string batch = "";
            int batchCount = 0;
            MqlDateTime dt;

            for(int i = 0; i < copied; i++)
              {
               double bid = ticks[i].bid;
               double ask = ticks[i].ask;
               if(bid <= 0.0 && ask <= 0.0)
                  continue;
               if(bid <= 0.0 || ask <= 0.0)
                 {
                  zeroSideTicks++;
                  if(bid <= 0.0)
                     bid = ask;
                  if(ask <= 0.0)
                     ask = bid;
                 }
               if(ask < bid)
                  invertedQuotes++;

               long tMsc = ticks[i].time_msc;
               if(prevTickMs > 0)
                 {
                  if(tMsc < prevTickMs)
                     nonMonotonicTicks++;
                  long deltaMs = tMsc - prevTickMs;
                  if(deltaMs >= gapThresholdMs)
                    {
                     datetime pSec = (datetime)(prevTickMs / 1000LL);
                     datetime cSec = (datetime)(tMsc / 1000LL);
                     if(!AzmIsExpectedClosure(pSec, cSec))
                       {
                        weekdayGapCount++;
                        AzmRecordGap(deltaMs / 1000LL, pSec, cSec, topGapSec, topGapFrom, topGapTo);
                       }
                    }
                 }
               if(tMsc > prevTickMs)
                  prevTickMs = tMsc;

               datetime tSec = (datetime)(tMsc / 1000LL);
               if(firstQuoteSec == 0)
                  firstQuoteSec = tSec;
               lastQuoteSec = tSec;

               int msPart = (int)(tMsc % 1000LL);
               if(msPart < 0)
                  msPart = 0;
               TimeToStruct(tSec, dt);

               // Spread bucket in points
               long spPts = (ask >= bid) ? (long)MathRound((ask - bid) / pointVal) : 0;
               int bucket = (int)MathMax(0LL, MathMin((long)AZM_HIST_MAX_PTS, spPts));
               histAll[bucket]++;
               cntAll++;

               bool isRollover = (dt.hour == 23 || (dt.hour == 0 && dt.min <= 15));
               if(isRollover)
                 {
                  histRollover[bucket]++;
                  cntRollover++;
                  if(spPts > maxRolloverSpreadPts)
                     maxRolloverSpreadPts = spPts;
                 }
               else if(dt.hour >= 12 && dt.hour < 16)
                 {
                  histOverlap[bucket]++;
                  cntOverlap++;
                 }
               else if(dt.hour >= 7 && dt.hour < 12)
                 {
                  histLondon[bucket]++;
                  cntLondon++;
                 }
               else if(dt.hour >= 1 && dt.hour < 6)
                 {
                  histAsia[bucket]++;
                  cntAsia++;
                 }

               totalRows++;

               if(writeCsv)
                 {
                  ulong vol = ticks[i].volume;
                  if(vol == 0 && ticks[i].volume_real > 0.0)
                     vol = (ulong)MathMax(1.0, MathRound(ticks[i].volume_real));

                  batch += StringFormat("%04d.%02d.%02d\t%02d:%02d:%02d.%03d\t%s\t%s\t%I64u\r\n",
                                        dt.year, dt.mon, dt.day,
                                        dt.hour, dt.min, dt.sec, msPart,
                                        DoubleToString(bid, digits),
                                        DoubleToString(ask, digits),
                                        vol);
                  batchCount++;
                  if(batchCount >= 256)
                    {
                     FileWriteString(csvHandle, batch);
                     batch = "";
                     batchCount = 0;
                    }
                 }
              }

            if(writeCsv && batchCount > 0)
               FileWriteString(csvHandle, batch);

            ArrayFree(ticks);
           }

         curStartMs = curEndMs + 1LL;
        }
     }
   else
     {
      FileWriteString(csvHandle, "<DATE>\t<TIME>\t<OPEN>\t<HIGH>\t<LOW>\t<CLOSE>\t<TICKVOL>\t<SPREAD>\r\n");
      long chunkSec = 30LL * 86400LL;
      datetime curStart = startSec;
      datetime lastBar = 0;

      while(curStart <= endSec && !IsStopped())
        {
         datetime curEnd = (datetime)MathMin((long)endSec, (long)curStart + chunkSec - 1LL);
         MqlRates rates[];
         ArraySetAsSeries(rates, false);
         int copied = CopyRates(sym, PERIOD_M1, curStart, curEnd, rates);
         if(copied > 0)
           {
            string batch = "";
            int batchCount = 0;
            MqlDateTime dt;
            for(int i = 0; i < copied; i++)
              {
               if(rates[i].time <= lastBar)
                  continue;
               lastBar = rates[i].time;
               if(firstQuoteSec == 0)
                  firstQuoteSec = rates[i].time;
               lastQuoteSec = rates[i].time;
               TimeToStruct(rates[i].time, dt);
               batch += StringFormat("%04d.%02d.%02d\t%02d:%02d:%02d\t%s\t%s\t%s\t%s\t%I64d\t%d\r\n",
                                     dt.year, dt.mon, dt.day,
                                     dt.hour, dt.min, dt.sec,
                                     DoubleToString(rates[i].open, digits),
                                     DoubleToString(rates[i].high, digits),
                                     DoubleToString(rates[i].low, digits),
                                     DoubleToString(rates[i].close, digits),
                                     rates[i].tick_volume,
                                     rates[i].spread);
               batchCount++;
               totalRows++;
               if(batchCount >= 512)
                 {
                  FileWriteString(csvHandle, batch);
                  batch = "";
                  batchCount = 0;
                 }
              }
            if(batchCount > 0)
               FileWriteString(csvHandle, batch);
            ArrayFree(rates);
           }
         if(curEnd >= endSec)
            break;
         curStart = (datetime)((long)curEnd + 1LL);
        }
     }

   if(writeCsv && csvHandle != INVALID_HANDLE)
     {
      FileFlush(csvHandle);
      FileClose(csvHandle);
      if(totalRows == 0)
         FileDelete(csvName);
     }
   Comment("");

   double elapsedSec = (double)(GetTickCount64() - t0) / 1000.0;
   string filesDir   = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";

   // Compute forensic summary metrics
   double p50All      = AzmPercentilePts(histAll,      cntAll,      0.50) / ptsPerPip;
   double p95All      = AzmPercentilePts(histAll,      cntAll,      0.95) / ptsPerPip;
   double p50Overlap  = AzmPercentilePts(histOverlap,  cntOverlap,  0.50) / ptsPerPip;
   double p95Overlap  = AzmPercentilePts(histOverlap,  cntOverlap,  0.95) / ptsPerPip;
   double p50London   = AzmPercentilePts(histLondon,   cntLondon,   0.50) / ptsPerPip;
   double p95London   = AzmPercentilePts(histLondon,   cntLondon,   0.95) / ptsPerPip;
   double p50Asia     = AzmPercentilePts(histAsia,     cntAsia,     0.50) / ptsPerPip;
   double p95Asia     = AzmPercentilePts(histAsia,     cntAsia,     0.95) / ptsPerPip;
   double p50Roll     = AzmPercentilePts(histRollover, cntRollover, 0.50) / ptsPerPip;
   double p95Roll     = AzmPercentilePts(histRollover, cntRollover, 0.95) / ptsPerPip;
   double maxRollPips = (double)maxRolloverSpreadPts / ptsPerPip;

   double baseRefPips = (p50London > 0.05) ? p50London : MathMax(0.10, p50All);
   double rolloverMult = (cntRollover > 0) ? (p95Roll / baseRefPips) : 1.0;

   // Build forensic text report
   string rpt = "";
   rpt += "====================================================================\r\n";
   rpt += " MT5 BROKER TICK & ROLLOVER SPREAD FORENSIC AUDIT REPORT\r\n";
   rpt += "====================================================================\r\n";
   rpt += StringFormat(" Symbol           : %s (%d digits, 1 pip = %.0f pts)\r\n", sym, digits, ptsPerPip);
   rpt += StringFormat(" Broker / Account : %s (%s)\r\n", brokerName, acctCurrency);
   rpt += StringFormat(" Period Covered   : %s -> %s\r\n",
                       firstQuoteSec > 0 ? TimeToString(firstQuoteSec, TIME_DATE | TIME_MINUTES) : "N/A",
                       lastQuoteSec > 0  ? TimeToString(lastQuoteSec,  TIME_DATE | TIME_MINUTES) : "N/A");
   rpt += StringFormat(" Rows Processed   : %I64d (%s) in %.1f sec\r\n", totalRows, modeTag, elapsedSec);
   if(writeCsv && totalRows > 0)
      rpt += StringFormat(" Clean CSV Output : %s%s\r\n", filesDir, csvName);

   if(ticksMode && totalRows > 0)
     {
      rpt += "--------------------------------------------------------------------\r\n";
      rpt += " 1. SESSION SPREAD PROFILE (REAL BID/ASK TICKS, IN PIPS)\r\n";
      rpt += "--------------------------------------------------------------------\r\n";
      rpt += StringFormat("   All Sessions            : Median = %6.2f pips | P95 = %6.2f pips (%I64d ticks)\r\n", p50All, p95All, cntAll);
      rpt += StringFormat("   London+NY (12:00-16:00) : Median = %6.2f pips | P95 = %6.2f pips\r\n", p50Overlap, p95Overlap);
      rpt += StringFormat("   London    (07:00-12:00) : Median = %6.2f pips | P95 = %6.2f pips\r\n", p50London, p95London);
      rpt += StringFormat("   Asia      (01:00-06:00) : Median = %6.2f pips | P95 = %6.2f pips\r\n", p50Asia, p95Asia);
      rpt += StringFormat("   Rollover  (23:00-00:15) : Median = %6.2f pips | P95 = %6.2f pips | Max = %6.2f pips\r\n",
                          p50Roll, p95Roll, maxRollPips);
      rpt += StringFormat("   Rollover Widening Ratio : %.1fx vs London Median\r\n", rolloverMult);

      rpt += "--------------------------------------------------------------------\r\n";
      rpt += " 2. FEED INTEGRITY & WEEKDAY BLACKOUT GAPS\r\n";
      rpt += "--------------------------------------------------------------------\r\n";
      rpt += StringFormat("   Inverted Quotes (Ask < Bid)     : %I64d\r\n", invertedQuotes);
      rpt += StringFormat("   Out-of-Order Millisecond Ticks  : %I64d\r\n", nonMonotonicTicks);
      rpt += StringFormat("   Single-Sided Quotes Repaired    : %I64d\r\n", zeroSideTicks);
      rpt += StringFormat("   Weekday Intraday Gaps (>= %d m) : %I64d\r\n", gapMin, weekdayGapCount);

      for(int g = 0; g < 3; g++)
        {
         if(topGapSec[g] > 0)
           {
            rpt += StringFormat("     #%d Gap : %.1f min (%s -> %s)\r\n",
                                g + 1,
                                (double)topGapSec[g] / 60.0,
                                TimeToString(topGapFrom[g], TIME_DATE | TIME_MINUTES),
                                TimeToString(topGapTo[g],   TIME_DATE | TIME_MINUTES));
           }
        }

      rpt += "--------------------------------------------------------------------\r\n";
      rpt += " 3. QUANTITATIVE & PROP-FIRM EXECUTION DIAGNOSTIC\r\n";
      rpt += "--------------------------------------------------------------------\r\n";
      if(rolloverMult >= 3.0)
         rpt += StringFormat("   [!] Rollover spread widens %.1fx (P95 = %.2f pips). OHLC M1 backtests\r\n"
                             "       with fixed spread will underestimate midnight SL hits & floating DD.\r\n",
                             rolloverMult, p95Roll);
      else
         rpt += "   [OK] Rollover spread widening is moderate relative to London liquidity.\r\n";

      if(weekdayGapCount > 0)
         rpt += StringFormat("   [!] %I64d weekday feed gaps detected. Stress-test SL/TP slippage (2x/3x)\r\n"
                             "       across sub-periods before deploying an EA on live or Prop-Firm capital.\r\n",
                             weekdayGapCount);
      else
         rpt += "   [OK] Zero abnormal weekday feed blackouts detected above threshold.\r\n";
     }

   rpt += "====================================================================\r\n";
   rpt += " Generated by Azimuth_Tick_Audit_Exporter.mq5 (Azimuth Studio)\r\n";
   rpt += "====================================================================\r\n";

   if(totalRows > 0)
     {
      int rptHandle = FileOpen(rptName, FILE_WRITE | FILE_TXT | FILE_ANSI, '\t', CP_UTF8);
      if(rptHandle != INVALID_HANDLE)
        {
         FileWriteString(rptHandle, rpt);
         FileFlush(rptHandle);
         FileClose(rptHandle);
        }
     }

   Print("\n" + rpt);

   if(InpShowSummaryDialog)
     {
      if(totalRows > 0)
        {
         string summaryMsg = ticksMode
            ? StringFormat(
                 "Tick Forensic Audit Complete!\n\n"
                 "Symbol: %s (%I64d ticks in %.1f s)\n"
                 "London Median Spread: %.2f pips\n"
                 "Rollover P95 Spread (23:00-00:15): %.2f pips (%.1fx widening)\n"
                 "Inverted Quotes: %I64d | Weekday Gaps (>=%dm): %I64d\n\n"
                 "Audit Report: MQL5\\Files\\%s\n%s",
                 sym, totalRows, elapsedSec,
                 p50London, p95Roll, rolloverMult,
                 invertedQuotes, gapMin, weekdayGapCount,
                 rptName,
                 writeCsv ? ("Clean CSV: MQL5\\Files\\" + csvName) : "(CSV export disabled)"
              )
            : StringFormat(
                 "M1 Bars Export Complete!\n\n"
                 "Symbol: %s (%I64d M1 bars in %.1f s)\n"
                 "Clean CSV: MQL5\\Files\\%s",
                 sym, totalRows, elapsedSec, csvName
              );
         MessageBox(summaryMsg, "MT5 Tick Audit & CSV Exporter", MB_OK | MB_ICONINFORMATION);
        }
      else
        {
         MessageBox(
            StringFormat("No historical data returned by broker for %s.\nOpen a %s chart or connect your MT5 account first.", sym, sym),
            "MT5 Tick Audit & CSV Exporter",
            MB_OK | MB_ICONWARNING
         );
        }
     }
  }
//+------------------------------------------------------------------+
