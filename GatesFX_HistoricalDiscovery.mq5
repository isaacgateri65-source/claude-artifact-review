//+------------------------------------------------------------------+
//| GatesFX_HistoricalDiscovery.mq5                                  |
//| Stage 1: M1 + M15 data audit, manifests, persistence, checkpoints|
//| RESEARCH ONLY. This file contains no trading calls.              |
//| Not implemented in Stage 1: features, outcomes, discovery,       |
//| statistics, virtual trades.                                      |
//+------------------------------------------------------------------+
#property copyright "GatesFX"
#property version   "1.00"
#property description "GatesFX Historical Discovery - Stage 1. Research only; places no orders."

#include <GatesFX_HD\HD_Common.mqh>
#include <GatesFX_HD\HD_Persist.mqh>
#include <GatesFX_HD\HD_DataAudit.mqh>

input string   InpExpectedSymbol     = "XAUUSDz";                // Required symbol
input datetime InpPeriodStart        = D'2024.11.19 00:00:00';   // Research period start (server time)
input datetime InpPeriodEnd          = D'2026.11.18 23:59:59';   // Research period end (server time)
input string   InpDeclaredModelling  = "M1_OHLC";                // Label only; EA cannot verify the mode
input int      InpCheckpointEveryM15 = 96;                       // Checkpoint every N completed M15 bars
input int      InpMaxEventRows       = 200000;                   // Cap on data_quality.csv rows
input string   InpResumeFromRunId    = "";                       // Parent run id to resume from (new run is created)
input int      InpTestAbortAtM15Bars = 0;                        // TEST ONLY: simulate a crash (skip finalisation)
input bool     InpAllowNonTester     = false;                    // Must stay false for research runs

CHDPersist  g_p;
HD_TfAudit  g_m1;
HD_TfAudit  g_m15;
HD_Sessions g_sess;

bool   g_initOk = false;
bool   g_aborted = false;
bool   g_ioFatal = false;
string g_parent = "";
long   g_dqRows = 0;
long   g_dqSuppressed = 0;
long   g_ticks = 0;
long   g_m15Processed = 0;
long   g_lastCkptAt = 0;
long   g_ckptCount = 0;
bool   g_resumed = false;

//+------------------------------------------------------------------+
string CheckpointInner(const bool isFinal)
  {
   string s = "";
   s += HD_AuditCk("m1", g_m1);
   s += HD_AuditCk("m15", g_m15);
   s += HD_JN("dq_rows", g_dqRows);
   s += HD_JN("dq_supp", g_dqSuppressed);
   s += HD_JN("ticks", g_ticks);
   s += HD_JN("m15_proc", g_m15Processed);
   s += HD_JN("p_start", (long)InpPeriodStart);
   s += HD_JN("p_end", (long)InpPeriodEnd);
   s += HD_JS("symbol", _Symbol);
   s += "\"final\":" + (isFinal ? "1" : "0");
   return s;
  }

bool WriteCk(const bool isFinal)
  {
   bool ok = g_p.WriteCheckpoint(CheckpointInner(isFinal));
   if(ok)
     {
      g_ckptCount++;
      g_lastCkptAt = g_m15Processed;
     }
   return ok;
  }

//+------------------------------------------------------------------+
string BuildConfigJson()
  {
   string j = "{";
   j += HD_JS("InpExpectedSymbol", InpExpectedSymbol);
   j += HD_JS("InpPeriodStart", HD_TimeStr(InpPeriodStart));
   j += HD_JS("InpPeriodEnd", HD_TimeStr(InpPeriodEnd));
   j += HD_JS("InpDeclaredModelling", InpDeclaredModelling);
   j += HD_JN("InpCheckpointEveryM15", InpCheckpointEveryM15);
   j += HD_JN("InpMaxEventRows", InpMaxEventRows);
   j += HD_JS("InpResumeFromRunId", InpResumeFromRunId);
   j += HD_JN("InpTestAbortAtM15Bars", InpTestAbortAtM15Bars);
   j += HD_JN("InpAllowNonTester", (long)InpAllowNonTester);
   j += "\"schema\":" + IntegerToString(HD_SCHEMA_VERSION);
   j += "}";
   return j;
  }

string BuildManifest(const string status, const long deinitReason, const long dqBytes, const string dqCrc)
  {
   string j = "{";
   j += HD_JN("schema", HD_SCHEMA_VERSION);
   j += HD_JS("run_id", g_p.RunId());
   j += HD_JS("parent_run_id", g_parent);
   j += HD_JS("run_type", "STAGE1_DATA_AUDIT");
   j += HD_JS("status", status);
   j += HD_JS("ea_name", "GatesFX_HistoricalDiscovery");
   j += HD_JS("ea_version", HD_VERSION);
   j += HD_JS("source_hash", "NOT_COMPUTED_BY_EA: compute SHA-256 externally (hd_inspect_runs.py --sha256) and record in review");
   j += HD_JS("compiled_at", TimeToString((datetime)__DATETIME__, TIME_DATE | TIME_SECONDS));
   j += HD_JN("mql_build_macro", __MQLBUILD__);
   j += HD_JN("terminal_build", TerminalInfoInteger(TERMINAL_BUILD));
   j += HD_JN("is_tester", MQLInfoInteger(MQL_TESTER));
   j += HD_JS("broker_company", AccountInfoString(ACCOUNT_COMPANY));
   j += HD_JS("server", AccountInfoString(ACCOUNT_SERVER));
   j += HD_JS("symbol", _Symbol);
   j += HD_JS("symbol_description", SymbolInfoString(_Symbol, SYMBOL_DESCRIPTION));
   j += HD_JN("symbol_digits", (long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   j += HD_JS("timeframes_audited", "M1,M15");
   j += HD_JS("primary_timeframe", "M15");
   j += HD_JS("period_start", HD_TimeStr(InpPeriodStart));
   j += HD_JS("period_end", HD_TimeStr(InpPeriodEnd));
   j += HD_JS("modelling_mode_declared", InpDeclaredModelling);
   j += HD_JS("modelling_mode_verified", "NO - EA cannot read the tester model; see avg_ticks_per_m1_bar as weak evidence");
   j += HD_JS("timezone", "BROKER_SERVER_TIME; UTC offset not assumed or verified");
   j += HD_JS("session_schedule_note", "sessions come from the symbol's CURRENT declared schedule, not historical");
   j += HD_JN("session_schedule_known", (long)g_sess.known);
   j += HD_JS("fs_common_path", TerminalInfoString(TERMINAL_COMMONDATA_PATH));
   j += HD_JS("run_dir_relative", g_p.Dir());
   j += HD_JN("resumed_from_checkpoint", (long)g_resumed);
   j += HD_JN("checkpoint_every_m15", InpCheckpointEveryM15);
   j += HD_JN("tester_ticks_seen", g_ticks);
   if(g_m1.bars > 0)
      j += HD_JS("avg_ticks_per_m1_bar", DoubleToString((double)g_ticks / (double)g_m1.bars, 2));
   j += HD_JN("event_rows_written", g_dqRows);
   j += HD_JN("event_rows_suppressed_by_cap", g_dqSuppressed);
   j += HD_JN("deinit_reason", deinitReason);
   j += HD_JN("data_quality_csv_bytes", dqBytes);
   j += HD_JS("data_quality_csv_crc32", dqCrc);
   j += HD_JS("not_implemented_stage1", "features,outcomes,candidates,statistics,virtual_trades,validation,html_report");
   j += "\"data_quality\":{\"M1\":" + HD_AuditJson(g_m1) + ",\"M15\":" + HD_AuditJson(g_m15) + "}";
   j += "}";
   return j;
  }

//+------------------------------------------------------------------+
int InitFail(const string msg)
  {
   Print("HD INIT FAILED: ", msg);
   if(g_p.RunId() != "")
     {
      g_p.WriteTextVerified("init_failed.txt", msg);
      g_p.AppendIndex("INIT_FAILED", g_parent, "INIT_FAILED", _Symbol, msg);
     }
   return INIT_FAILED;
  }

int OnInit()
  {
   g_initOk = false;
   g_aborted = false;
   g_ioFatal = false;

   if(MQLInfoInteger(MQL_TESTER) == 0 && !InpAllowNonTester)
     {
      Print("HD: refusing to run outside the Strategy Tester (InpAllowNonTester=false).");
      return INIT_FAILED;
     }
   if(_Symbol != InpExpectedSymbol)
     {
      Print("HD: symbol mismatch. Expected ", InpExpectedSymbol, " got ", _Symbol);
      return INIT_FAILED;
     }
   if(InpPeriodStart >= InpPeriodEnd || InpCheckpointEveryM15 < 1 || InpMaxEventRows < 1)
     {
      Print("HD: invalid inputs.");
      return INIT_FAILED;
     }

   string tag = "HDL";
   if(MQLInfoInteger(MQL_TESTER) != 0)
      tag = "HDT";
   if(!g_p.OpenNew(tag))
     {
      Print("HD: cannot create run directory: ", g_p.LastError());
      return INIT_FAILED;
     }

   string rep = "";
   bool fsOk = g_p.SelfTest(rep);
   g_p.WriteTextVerified("fs_selftest.txt", rep);
   g_p.Log("INFO", "fs_selftest overall=" + (fsOk ? "PASS" : "FAIL") + " " + rep);
   if(!fsOk)
      return InitFail("file-system self-test failed: " + rep);

   HD_AuditInit(g_m1, "M1", 60);
   HD_AuditInit(g_m15, "M15", 900);
   HD_LoadSessions(_Symbol, g_sess);
   g_p.Log("INFO", "session_schedule_known=" + IntegerToString((long)g_sess.known));

   g_dqRows = 0;
   g_dqSuppressed = 0;
   g_ticks = 0;
   g_m15Processed = 0;
   g_resumed = false;
   g_parent = "";
   bool needHeader = true;

   if(InpResumeFromRunId != "")
     {
      string pdir = HD_RUNS_DIR + "\\" + InpResumeFromRunId;
      string body = "";
      ulong seq = 0;
      if(!HD_LoadBestCheckpoint(pdir, body, seq))
         return InitFail("no valid checkpoint in parent run " + InpResumeFromRunId);
      long pstart = 0, pend = 0, fin = 1;
      string psym = "";
      HD_JsonNum(body, "p_start", pstart);
      HD_JsonNum(body, "p_end", pend);
      HD_JsonNum(body, "final", fin);
      HD_JsonStr(body, "symbol", psym);
      if(psym != _Symbol || pstart != (long)InpPeriodStart || pend != (long)InpPeriodEnd)
         return InitFail("parent checkpoint symbol/period does not match current inputs");
      if(fin != 0)
         return InitFail("parent checkpoint is final; nothing to resume");
      if(!HD_AuditRestore(body, "m1", g_m1) || !HD_AuditRestore(body, "m15", g_m15))
         return InitFail("parent checkpoint is missing audit fields");
      long v = 0;
      if(!HD_JsonNum(body, "dq_rows", v))
         return InitFail("parent checkpoint lacks dq_rows");
      g_dqRows = v;
      if(HD_JsonNum(body, "dq_supp", v))
         g_dqSuppressed = v;
      if(HD_JsonNum(body, "ticks", v))
         g_ticks = v;
      if(HD_JsonNum(body, "m15_proc", v))
         g_m15Processed = v;
      if(!g_p.CopyCsvPrefixFrom(pdir + "\\data_quality.csv", "data_quality.csv", g_dqRows))
         return InitFail("parent data_quality.csv has fewer rows than its checkpoint claims");
      g_parent = InpResumeFromRunId;
      g_resumed = true;
      needHeader = false;
      g_lastCkptAt = g_m15Processed;
      g_p.Log("INFO", "resumed from " + g_parent + " ckpt_seq=" + IntegerToString((long)seq) +
              " dq_rows=" + IntegerToString(g_dqRows) + " m15_bars=" + IntegerToString(g_m15.bars) +
              " m1_bars=" + IntegerToString(g_m1.bars));
     }

   if(needHeader)
     {
      if(!g_p.WriteTextVerified("data_quality.csv", HD_DQ_HEADER + "\n"))
         return InitFail("cannot create data_quality.csv");
      g_lastCkptAt = 0;
     }

   if(!g_p.WriteTextVerified("configuration.json", BuildConfigJson()))
      return InitFail("cannot write configuration.json");
   if(!g_p.WriteTextVerified("manifest.json", BuildManifest("STARTED", -1, 0, "")))
      return InitFail("cannot write manifest.json");
   if(!WriteCk(false))
      return InitFail("cannot write initial checkpoint");
   g_p.AppendIndex("STARTED", g_parent, "STARTED", _Symbol, "resumed=" + IntegerToString((long)g_resumed));
   g_p.Log("INFO", "run " + g_p.RunId() + " started; EA " + HD_VERSION + "; refuses to place orders (no trade code)");

   g_initOk = true;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void PollTf(const ENUM_TIMEFRAMES tf, HD_TfAudit &a, HD_Event &ev[])
  {
   datetime t0 = iTime(_Symbol, tf, 0);
   if(t0 == 0 || t0 == a.last_seen_open)
      return;
   a.last_seen_open = t0;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int n = 0;
   if(a.last_fetched == 0)
     {
      n = CopyRates(_Symbol, tf, 1, 1, rates);
     }
   else
     {
      datetime from = a.last_fetched + 1;
      datetime to = t0 - 1;
      if(from > to)
         return;
      int cnt = Bars(_Symbol, tf, from, to);
      if(cnt <= 0)
         return;
      n = CopyRates(_Symbol, tf, from, to, rates);
     }
   if(n <= 0)
     {
      a.copyfail++;
      g_p.Log("WARN", a.name + " CopyRates failed err=" + IntegerToString(GetLastError()));
      return;
     }
   for(int i = 0; i < n; i++)
      HD_AuditBar(a, g_sess, rates[i], InpPeriodStart, InpPeriodEnd, ev);
   a.last_fetched = rates[n - 1].time;
   if(tf == PERIOD_M15)
      g_m15Processed += n;
  }

void OnTick()
  {
   if(!g_initOk || g_aborted || g_ioFatal)
      return;
   g_ticks++;

   HD_Event ev[];
   PollTf(PERIOD_M1, g_m1, ev);
   PollTf(PERIOD_M15, g_m15, ev);

   if(ArraySize(ev) > 0)
     {
      if(HD_WriteEvents(g_p, ev, g_dqRows, g_dqSuppressed, InpMaxEventRows) < 0)
        {
         g_ioFatal = true;
         Print("HD: I/O FAILURE writing data_quality.csv - processing stopped. ", g_p.LastError());
         return;
        }
     }

   if(InpTestAbortAtM15Bars > 0 && g_m15.bars >= InpTestAbortAtM15Bars)
     {
      g_aborted = true;
      Print("HD TEST ABORT: simulating a crash. Finalisation will be skipped. m15_bars=", g_m15.bars);
      return;
     }

   if(g_m15Processed - g_lastCkptAt >= InpCheckpointEveryM15)
     {
      if(!WriteCk(false))
        {
         g_ioFatal = true;
         Print("HD: I/O FAILURE writing checkpoint - processing stopped. ", g_p.LastError());
        }
     }
  }

//+------------------------------------------------------------------+
void Finalise(const int reason)
  {
   string status = "FINALISED";
   if(g_ioFatal)
      status = "FINALISED_AFTER_IO_FAILURE";
   g_p.Log("INFO", "finalising status=" + status + " deinit_reason=" + IntegerToString(reason));

   bool ok = true;
   ok = WriteCk(true) && ok;

   string s = "timeframe,metric,value\n" + HD_AuditSummaryCsv(g_m1) + HD_AuditSummaryCsv(g_m15);
   s += "ALL,event_rows_written," + IntegerToString(g_dqRows) + "\n";
   s += "ALL,event_rows_suppressed_by_cap," + IntegerToString(g_dqSuppressed) + "\n";
   s += "ALL,tester_ticks_seen," + IntegerToString(g_ticks) + "\n";
   if(g_m1.bars > 0)
      s += "ALL,avg_ticks_per_m1_bar," + DoubleToString((double)g_ticks / (double)g_m1.bars, 2) + "\n";
   ok = g_p.WriteTextVerified("data_quality_summary.csv", s) && ok;

   uchar dq[];
   int dqn = g_p.ReadAllBytes("data_quality.csv", dq);
   string dqCrc = "";
   if(dqn >= 0)
      dqCrc = StringFormat("%08X", HD_Crc32(dq, dqn));
   else
      ok = false;

   string man = BuildManifest(status, reason, dqn, dqCrc);
   ok = g_p.ReplaceVerified("manifest.json", man) && ok;

   uchar mb[];
   int mn = HD_StringToBytes(man, mb);
   string manCrc = StringFormat("%08X", HD_Crc32(mb, mn));

   if(!ok || g_p.Failures() > 0)
     {
      Print("HD: finalisation had I/O failures; completion.json NOT written. ", g_p.LastError());
      g_p.Log("ERROR", "finalisation I/O failures; completion marker withheld");
      return;
     }

   string c = "{";
   c += HD_JS("run_id", g_p.RunId());
   c += HD_JS("status", status);
   c += HD_JS("manifest_crc32", manCrc);
   c += HD_JN("dq_rows", g_dqRows);
   c += HD_JN("dq_csv_bytes", dqn);
   c += HD_JS("dq_csv_crc32", dqCrc);
   c += HD_JN("deinit_reason", reason);
   c += HD_JS("last_m15_bar", HD_TimeStr(g_m15.prev_time));
   c += HD_JS("last_m1_bar", HD_TimeStr(g_m1.prev_time));
   c += "\"period_end_reached_within_3_days\":" + ((g_m15.prev_time + 3 * 86400 >= InpPeriodEnd) ? "1" : "0");
   c += "}";
   if(g_p.WriteTextVerified("completion.json", c))
     {
      g_p.AppendIndex("FINALISED", g_parent, status, _Symbol, "m15_bars=" + IntegerToString(g_m15.bars) + " m1_bars=" + IntegerToString(g_m1.bars));
      g_p.Log("INFO", "completion.json written and verified");
     }
   else
      Print("HD: completion.json could not be verified: ", g_p.LastError());
  }

void OnDeinit(const int reason)
  {
   if(!g_initOk)
      return;
   if(g_aborted)
     {
      Print("HD TEST ABORT: OnDeinit skipping finalisation on purpose.");
      return;
     }
   Finalise(reason);
  }
//+------------------------------------------------------------------+
