//+------------------------------------------------------------------+
//| HD_DataAudit.mqh                                                 |
//| Incremental, causal data-quality audit of completed bars.        |
//| Never interpolates or fabricates bars.                           |
//+------------------------------------------------------------------+
#ifndef HD_DATAAUDIT_MQH
#define HD_DATAAUDIT_MQH

#include <GatesFX_HD\HD_Common.mqh>
#include <GatesFX_HD\HD_Persist.mqh>

#define HD_GAP_SLOT_CAP 20000

struct HD_Event
  {
   string            tf;
   string            type;
   datetime          t_a;
   datetime          t_b;
   long              missing;
   long              in_session;
   string            cls;
   string            detail;
  };

//--- trade-session schedule as currently declared by the symbol (NOT historical)
struct HD_Sessions
  {
   bool              known;
   int               cnt[7];
   int               from_s[7][10];
   int               to_s[7][10];
  };

struct HD_TfAudit
  {
   string            name;
   int               period_sec;
   datetime          last_seen_open;
   datetime          last_fetched;
   datetime          prev_time;
   datetime          first_bar;
   long              bars;
   long              pre;
   long              post;
   long              dup;
   long              ooo;
   long              mis;
   long              bad;
   long              zero;
   long              tv0;
   long              gaps;
   long              miss;
   long              gaps_sched;
   long              miss_sched;
   long              gaps_unexp;
   long              miss_unexp;
   long              gaps_unchecked;
   long              copyfail;
   long              max_gap_sec;
  };

void HD_AuditInit(HD_TfAudit &a, const string name, const int period_sec)
  {
   a.name = name;
   a.period_sec = period_sec;
   a.last_seen_open = 0;
   a.last_fetched = 0;
   a.prev_time = 0;
   a.first_bar = 0;
   a.bars = 0;
   a.pre = 0;
   a.post = 0;
   a.dup = 0;
   a.ooo = 0;
   a.mis = 0;
   a.bad = 0;
   a.zero = 0;
   a.tv0 = 0;
   a.gaps = 0;
   a.miss = 0;
   a.gaps_sched = 0;
   a.miss_sched = 0;
   a.gaps_unexp = 0;
   a.miss_unexp = 0;
   a.gaps_unchecked = 0;
   a.copyfail = 0;
   a.max_gap_sec = 0;
  }

void HD_LoadSessions(const string sym, HD_Sessions &s)
  {
   s.known = false;
   for(int d = 0; d < 7; d++)
     {
      s.cnt[d] = 0;
      for(int i = 0; i < 10; i++)
        {
         s.from_s[d][i] = 0;
         s.to_s[d][i] = 0;
        }
      for(int i = 0; i < 10; i++)
        {
         datetime f = 0, t = 0;
         if(!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)d, (uint)i, f, t))
            break;
         s.from_s[d][i] = (int)f;
         s.to_s[d][i] = (int)t;
         s.cnt[d] = i + 1;
         s.known = true;
        }
     }
  }

bool HD_InSession(const HD_Sessions &s, const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int sod = dt.hour * 3600 + dt.min * 60 + dt.sec;
   int d = dt.day_of_week;
   for(int i = 0; i < s.cnt[d]; i++)
     {
      if(sod >= s.from_s[d][i] && sod < s.to_s[d][i])
         return true;
     }
   return false;
  }

void HD_Push(HD_Event &ev[], const string tf, const string type, const datetime ta, const datetime tb,
             const long missing, const long insess, const string cls, const string detail)
  {
   int n = ArraySize(ev);
   ArrayResize(ev, n + 1);
   ev[n].tf = tf;
   ev[n].type = type;
   ev[n].t_a = ta;
   ev[n].t_b = tb;
   ev[n].missing = missing;
   ev[n].in_session = insess;
   ev[n].cls = cls;
   ev[n].detail = detail;
  }

//--- audit ONE completed bar. Bars outside [pStart,pEnd] are counted but not audited.
void HD_AuditBar(HD_TfAudit &a, const HD_Sessions &sess, const MqlRates &r,
                 const datetime pStart, const datetime pEnd, HD_Event &ev[])
  {
   if(r.time < pStart)
     {
      a.pre++;
      return;
     }
   if(r.time > pEnd)
     {
      a.post++;
      return;
     }
   a.bars++;
   if(a.first_bar == 0)
      a.first_bar = r.time;

   string bad = "";
   if(!MathIsValidNumber(r.open) || !MathIsValidNumber(r.high) ||
      !MathIsValidNumber(r.low) || !MathIsValidNumber(r.close))
      bad += "NONFINITE;";
   else
     {
      if(r.open <= 0.0 || r.high <= 0.0 || r.low <= 0.0 || r.close <= 0.0)
        {
         a.zero++;
         bad += "NONPOSITIVE_PRICE;";
        }
      if(r.high < r.low || r.high < r.open || r.high < r.close || r.low > r.open || r.low > r.close)
         bad += "OHLC_INCONSISTENT;";
     }
   if(bad != "")
     {
      a.bad++;
      HD_Push(ev, a.name, "OHLC_INVALID", r.time, 0, 0, 0, "DATA_DEFECT", bad);
     }
   if(r.tick_volume == 0)
      a.tv0++;
   if((((long)r.time) % (long)a.period_sec) != 0)
     {
      a.mis++;
      HD_Push(ev, a.name, "MISALIGNED_TIMESTAMP", r.time, 0, 0, 0, "DATA_DEFECT", "time not multiple of period");
     }

   if(a.prev_time > 0)
     {
      if(r.time == a.prev_time)
        {
         a.dup++;
         HD_Push(ev, a.name, "DUPLICATE_TIMESTAMP", r.time, 0, 0, 0, "DATA_DEFECT", "same time as previous bar");
         return;
        }
      if(r.time < a.prev_time)
        {
         a.ooo++;
         HD_Push(ev, a.name, "OUT_OF_ORDER", a.prev_time, r.time, 0, 0, "DATA_DEFECT", "time earlier than previous bar");
         return;
        }
      long delta = (long)(r.time - a.prev_time);
      if(delta > (long)a.period_sec)
        {
         long missing = delta / (long)a.period_sec - 1;
         long insess = -1;
         string cls = "";
         string detail = "";
         if(!sess.known)
           {
            cls = "UNCLASSIFIED_NO_SESSION_DATA";
            detail = "symbol session schedule unavailable";
            a.gaps_unexp++;
            a.miss_unexp += missing;
           }
         else
           {
            long slots = 0;
            long cnt = 0;
            for(datetime t = a.prev_time + a.period_sec; t < r.time && slots < HD_GAP_SLOT_CAP; t += a.period_sec)
              {
               slots++;
               if(HD_InSession(sess, t))
                  cnt++;
              }
            if(missing > HD_GAP_SLOT_CAP)
              {
               cls = "LONG_GAP_UNCHECKED";
               detail = "gap exceeds slot cap; needs manual review";
               a.gaps_unchecked++;
              }
            else
              {
               insess = cnt;
               if(cnt == 0)
                 {
                  cls = "CLOSURE_PER_CURRENT_SESSION_SCHEDULE";
                  detail = "all missing slots outside currently declared sessions";
                  a.gaps_sched++;
                  a.miss_sched += missing;
                 }
               else
                 {
                  cls = "UNEXPLAINED_MISSING_IN_SESSION";
                  detail = "missing slots inside currently declared sessions; may be holiday or data loss - review";
                  a.gaps_unexp++;
                  a.miss_unexp += missing;
                 }
              }
           }
         a.gaps++;
         a.miss += missing;
         if(delta > a.max_gap_sec)
            a.max_gap_sec = delta;
         HD_Push(ev, a.name, "GAP", a.prev_time, r.time, missing, insess, cls, detail);
        }
     }
   a.prev_time = r.time;
  }

//--- write events as CSV rows; respects row cap; returns -1 on I/O failure
long HD_WriteEvents(CHDPersist &p, HD_Event &ev[], long &rows, long &suppressed, const long cap)
  {
   int n = ArraySize(ev);
   for(int i = 0; i < n; i++)
     {
      if(rows >= cap)
        {
         suppressed++;
         continue;
        }
      rows++;
      string line = IntegerToString(rows) + "," + ev[i].tf + "," + ev[i].type + "," +
                    HD_TimeStr(ev[i].t_a) + "," + HD_TimeStr(ev[i].t_b) + "," +
                    IntegerToString(ev[i].missing) + "," + IntegerToString(ev[i].in_session) + "," +
                    ev[i].cls + "," + HD_Sanitize(ev[i].detail);
      if(!p.AppendLine("data_quality.csv", line))
         return -1;
     }
   return n;
  }

string HD_AuditSummaryCsv(const HD_TfAudit &a)
  {
   string n = a.name + ",";
   string s = "";
   s += n + "first_bar_audited," + HD_TimeStr(a.first_bar) + "\n";
   s += n + "last_bar_audited," + HD_TimeStr(a.prev_time) + "\n";
   s += n + "bars_audited," + IntegerToString(a.bars) + "\n";
   s += n + "bars_before_period_skipped," + IntegerToString(a.pre) + "\n";
   s += n + "bars_after_period_skipped," + IntegerToString(a.post) + "\n";
   s += n + "duplicate_timestamps," + IntegerToString(a.dup) + "\n";
   s += n + "out_of_order," + IntegerToString(a.ooo) + "\n";
   s += n + "misaligned_timestamps," + IntegerToString(a.mis) + "\n";
   s += n + "ohlc_invalid_bars," + IntegerToString(a.bad) + "\n";
   s += n + "nonpositive_price_bars," + IntegerToString(a.zero) + "\n";
   s += n + "zero_tick_volume_bars," + IntegerToString(a.tv0) + "\n";
   s += n + "gap_events," + IntegerToString(a.gaps) + "\n";
   s += n + "missing_bars_total," + IntegerToString(a.miss) + "\n";
   s += n + "gaps_closure_per_current_schedule," + IntegerToString(a.gaps_sched) + "\n";
   s += n + "missing_bars_closure_per_current_schedule," + IntegerToString(a.miss_sched) + "\n";
   s += n + "gaps_unexplained_or_unclassified," + IntegerToString(a.gaps_unexp) + "\n";
   s += n + "missing_bars_unexplained_or_unclassified," + IntegerToString(a.miss_unexp) + "\n";
   s += n + "gaps_unchecked_long," + IntegerToString(a.gaps_unchecked) + "\n";
   s += n + "max_gap_seconds," + IntegerToString(a.max_gap_sec) + "\n";
   s += n + "copy_failures," + IntegerToString(a.copyfail) + "\n";
   return s;
  }

//--- JSON object (no trailing comma) for the manifest
string HD_AuditJson(const HD_TfAudit &a)
  {
   string j = "{";
   j += HD_JS("first_bar_audited", HD_TimeStr(a.first_bar));
   j += HD_JS("last_bar_audited", HD_TimeStr(a.prev_time));
   j += HD_JN("bars_audited", a.bars);
   j += HD_JN("bars_before_period_skipped", a.pre);
   j += HD_JN("bars_after_period_skipped", a.post);
   j += HD_JN("duplicate_timestamps", a.dup);
   j += HD_JN("out_of_order", a.ooo);
   j += HD_JN("misaligned_timestamps", a.mis);
   j += HD_JN("ohlc_invalid_bars", a.bad);
   j += HD_JN("nonpositive_price_bars", a.zero);
   j += HD_JN("zero_tick_volume_bars", a.tv0);
   j += HD_JN("gap_events", a.gaps);
   j += HD_JN("missing_bars_total", a.miss);
   j += HD_JN("gaps_closure_per_current_schedule", a.gaps_sched);
   j += HD_JN("gaps_unexplained_or_unclassified", a.gaps_unexp);
   j += HD_JN("gaps_unchecked_long", a.gaps_unchecked);
   j += HD_JN("copy_failures", a.copyfail);
   j += "\"max_gap_seconds\":" + IntegerToString(a.max_gap_sec);
   j += "}";
   return j;
  }

//--- checkpoint (de)serialisation of one timeframe; every field ends with a comma
string HD_AuditCk(const string p, const HD_TfAudit &a)
  {
   string s = "";
   s += HD_JN(p + "_seen", (long)a.last_seen_open);
   s += HD_JN(p + "_fetched", (long)a.last_fetched);
   s += HD_JN(p + "_prev", (long)a.prev_time);
   s += HD_JN(p + "_first", (long)a.first_bar);
   s += HD_JN(p + "_bars", a.bars);
   s += HD_JN(p + "_pre", a.pre);
   s += HD_JN(p + "_post", a.post);
   s += HD_JN(p + "_dup", a.dup);
   s += HD_JN(p + "_ooo", a.ooo);
   s += HD_JN(p + "_mis", a.mis);
   s += HD_JN(p + "_bad", a.bad);
   s += HD_JN(p + "_zero", a.zero);
   s += HD_JN(p + "_tv0", a.tv0);
   s += HD_JN(p + "_gaps", a.gaps);
   s += HD_JN(p + "_miss", a.miss);
   s += HD_JN(p + "_gsched", a.gaps_sched);
   s += HD_JN(p + "_msched", a.miss_sched);
   s += HD_JN(p + "_gunexp", a.gaps_unexp);
   s += HD_JN(p + "_munexp", a.miss_unexp);
   s += HD_JN(p + "_gunchk", a.gaps_unchecked);
   s += HD_JN(p + "_cfail", a.copyfail);
   s += HD_JN(p + "_maxgap", a.max_gap_sec);
   return s;
  }

bool HD_AuditRestore(const string body, const string p, HD_TfAudit &a)
  {
   long v = 0;
   bool ok = true;
   if(HD_JsonNum(body, p + "_seen", v))   a.last_seen_open = (datetime)v; else ok = false;
   if(HD_JsonNum(body, p + "_fetched", v)) a.last_fetched = (datetime)v; else ok = false;
   if(HD_JsonNum(body, p + "_prev", v))   a.prev_time = (datetime)v; else ok = false;
   if(HD_JsonNum(body, p + "_first", v))  a.first_bar = (datetime)v; else ok = false;
   if(HD_JsonNum(body, p + "_bars", v))   a.bars = v; else ok = false;
   if(HD_JsonNum(body, p + "_pre", v))    a.pre = v; else ok = false;
   if(HD_JsonNum(body, p + "_post", v))   a.post = v; else ok = false;
   if(HD_JsonNum(body, p + "_dup", v))    a.dup = v; else ok = false;
   if(HD_JsonNum(body, p + "_ooo", v))    a.ooo = v; else ok = false;
   if(HD_JsonNum(body, p + "_mis", v))    a.mis = v; else ok = false;
   if(HD_JsonNum(body, p + "_bad", v))    a.bad = v; else ok = false;
   if(HD_JsonNum(body, p + "_zero", v))   a.zero = v; else ok = false;
   if(HD_JsonNum(body, p + "_tv0", v))    a.tv0 = v; else ok = false;
   if(HD_JsonNum(body, p + "_gaps", v))   a.gaps = v; else ok = false;
   if(HD_JsonNum(body, p + "_miss", v))   a.miss = v; else ok = false;
   if(HD_JsonNum(body, p + "_gsched", v)) a.gaps_sched = v; else ok = false;
   if(HD_JsonNum(body, p + "_msched", v)) a.miss_sched = v; else ok = false;
   if(HD_JsonNum(body, p + "_gunexp", v)) a.gaps_unexp = v; else ok = false;
   if(HD_JsonNum(body, p + "_munexp", v)) a.miss_unexp = v; else ok = false;
   if(HD_JsonNum(body, p + "_gunchk", v)) a.gaps_unchecked = v; else ok = false;
   if(HD_JsonNum(body, p + "_cfail", v))  a.copyfail = v; else ok = false;
   if(HD_JsonNum(body, p + "_maxgap", v)) a.max_gap_sec = v; else ok = false;
   return ok;
  }

#define HD_DQ_HEADER "seq,timeframe,event_type,bar_time_a,bar_time_b,missing_bars,missing_in_session_slots,classification,detail"

#endif
