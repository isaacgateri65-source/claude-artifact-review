//+------------------------------------------------------------------+
//| GatesFX_HD_HistoryProbe.mq5                                      |
//| Stage 1 helper SCRIPT (run on a live chart, not in the tester).  |
//| Audits M1 and M15 history held by the terminal for the research  |
//| period using the same audit module as the EA.                    |
//| Read-only with respect to market data; writes only into a new    |
//| run folder under Common\Files\GatesFX_HistoricalDiscovery\Runs.  |
//| RESEARCH ONLY. No trading calls.                                 |
//+------------------------------------------------------------------+
#property copyright "GatesFX"
#property version   "1.00"
#property script_show_inputs

#include <GatesFX_HD\HD_Common.mqh>
#include <GatesFX_HD\HD_Persist.mqh>
#include <GatesFX_HD\HD_DataAudit.mqh>

input string   InpExpectedSymbol = "XAUUSDz";
input datetime InpPeriodStart    = D'2024.11.19 00:00:00';
input datetime InpPeriodEnd      = D'2026.11.18 23:59:59';
input int      InpChunkDays      = 14;
input int      InpMaxEventRows   = 200000;

CHDPersist g_p;
long g_rows = 0;
long g_supp = 0;

string SeriesInfo(const ENUM_TIMEFRAMES tf, const string name)
  {
   string s = "{";
   s += HD_JS("timeframe", name);
   s += HD_JN("series_bars_count", SeriesInfoInteger(_Symbol, tf, SERIES_BARS_COUNT));
   s += HD_JS("series_firstdate", HD_TimeStr((datetime)SeriesInfoInteger(_Symbol, tf, SERIES_FIRSTDATE)));
   s += HD_JS("series_terminal_firstdate", HD_TimeStr((datetime)SeriesInfoInteger(_Symbol, tf, SERIES_TERMINAL_FIRSTDATE)));
   s += HD_JS("series_server_firstdate", HD_TimeStr((datetime)SeriesInfoInteger(_Symbol, tf, SERIES_SERVER_FIRSTDATE)));
   s += "\"synchronized\":" + IntegerToString(SeriesInfoInteger(_Symbol, tf, SERIES_SYNCHRONIZED));
   s += "}";
   return s;
  }

bool AuditRange(const ENUM_TIMEFRAMES tf, HD_TfAudit &a, const HD_Sessions &sess)
  {
   // make sure the series is built before requesting data
   for(int attempt = 0; attempt < 10; attempt++)
     {
      if(SeriesInfoInteger(_Symbol, tf, SERIES_SYNCHRONIZED) != 0)
         break;
      Sleep(500);
     }
   long step = (long)InpChunkDays * 86400;
   datetime from = InpPeriodStart;
   while(from <= InpPeriodEnd)
     {
      datetime to = (datetime)MathMin((double)((long)from + step - 1), (double)InpPeriodEnd);
      MqlRates rates[];
      ArraySetAsSeries(rates, false);
      ResetLastError();
      int n = CopyRates(_Symbol, tf, from, to, rates);
      if(n < 0)
        {
         a.copyfail++;
         g_p.Log("WARN", a.name + " CopyRates " + HD_TimeStr(from) + ".." + HD_TimeStr(to) + " err=" + IntegerToString(GetLastError()));
        }
      else
        {
         HD_Event ev[];
         for(int i = 0; i < n; i++)
            HD_AuditBar(a, sess, rates[i], InpPeriodStart, InpPeriodEnd, ev);
         if(ArraySize(ev) > 0)
           {
            if(HD_WriteEvents(g_p, ev, g_rows, g_supp, InpMaxEventRows) < 0)
               return false;
           }
        }
      from = (datetime)((long)to + 1);
     }
   return true;
  }

void OnStart()
  {
   if(_Symbol != InpExpectedSymbol)
     {
      Print("HD probe: attach to ", InpExpectedSymbol, " (current ", _Symbol, ")");
      return;
     }
   if(!g_p.OpenNew("HDP"))
     {
      Print("HD probe: cannot create run dir: ", g_p.LastError());
      return;
     }
   string rep = "";
   bool fsOk = g_p.SelfTest(rep);
   g_p.Log("INFO", "fs_selftest overall=" + (fsOk ? "PASS" : "FAIL") + " " + rep);
   if(!fsOk)
     {
      g_p.WriteTextVerified("init_failed.txt", rep);
      return;
     }
   if(!g_p.WriteTextVerified("data_quality.csv", HD_DQ_HEADER + "\n"))
      return;
   g_p.AppendIndex("STARTED", "", "STARTED", _Symbol, "history probe");

   HD_Sessions sess;
   HD_LoadSessions(_Symbol, sess);
   HD_TfAudit m1, m15;
   HD_AuditInit(m1, "M1", 60);
   HD_AuditInit(m15, "M15", 900);

   bool ok = AuditRange(PERIOD_M1, m1, sess);
   ok = AuditRange(PERIOD_M15, m15, sess) && ok;

   string man = "{";
   man += HD_JN("schema", HD_SCHEMA_VERSION);
   man += HD_JS("run_id", g_p.RunId());
   man += HD_JS("run_type", "STAGE1_HISTORY_PROBE");
   man += HD_JS("status", ok ? "FINALISED" : "FINALISED_AFTER_IO_FAILURE");
   man += HD_JS("ea_version", HD_VERSION);
   man += HD_JS("broker_company", AccountInfoString(ACCOUNT_COMPANY));
   man += HD_JS("server", AccountInfoString(ACCOUNT_SERVER));
   man += HD_JS("symbol", _Symbol);
   man += HD_JS("period_start", HD_TimeStr(InpPeriodStart));
   man += HD_JS("period_end", HD_TimeStr(InpPeriodEnd));
   man += HD_JS("source", "LIVE TERMINAL HISTORY via CopyRates (not Strategy Tester)");
   man += HD_JS("note", "if M1 bars_audited is suspiciously round or truncated check Tools>Options>Charts>Max bars in chart");
   man += HD_JS("timezone", "BROKER_SERVER_TIME; UTC offset not assumed or verified");
   man += HD_JN("session_schedule_known", (long)sess.known);
   man += HD_JN("terminal_build", TerminalInfoInteger(TERMINAL_BUILD));
   man += HD_JN("event_rows_written", g_rows);
   man += HD_JN("event_rows_suppressed_by_cap", g_supp);
   man += "\"series_info\":[" + SeriesInfo(PERIOD_M1, "M1") + "," + SeriesInfo(PERIOD_M15, "M15") + "],";
   man += "\"data_quality\":{\"M1\":" + HD_AuditJson(m1) + ",\"M15\":" + HD_AuditJson(m15) + "}";
   man += "}";
   bool okm = g_p.WriteTextVerified("manifest.json", man);

   string s = "timeframe,metric,value\n" + HD_AuditSummaryCsv(m1) + HD_AuditSummaryCsv(m15);
   bool oks = g_p.WriteTextVerified("data_quality_summary.csv", s);

   if(ok && okm && oks && g_p.Failures() == 0)
     {
      uchar mb[];
      int mn = HD_StringToBytes(man, mb);
      string c = "{";
      c += HD_JS("run_id", g_p.RunId());
      c += HD_JS("status", "FINALISED");
      c += HD_JS("manifest_crc32", StringFormat("%08X", HD_Crc32(mb, mn)));
      c += HD_JN("dq_rows", g_rows);
      c += "\"probe\":1}";
      if(g_p.WriteTextVerified("completion.json", c))
        {
         g_p.AppendIndex("FINALISED", "", "FINALISED", _Symbol, "history probe m1=" + IntegerToString(m1.bars) + " m15=" + IntegerToString(m15.bars));
         Print("HD probe finished. M1 bars=", m1.bars, " M15 bars=", m15.bars, " run=", g_p.RunId());
         return;
        }
     }
   Print("HD probe: completed WITH I/O FAILURES; completion marker withheld. ", g_p.LastError());
  }
//+------------------------------------------------------------------+
