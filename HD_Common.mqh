//+------------------------------------------------------------------+
//| HD_Common.mqh                                                    |
//| GatesFX Historical Discovery - Stage 1 shared helpers            |
//| RESEARCH ONLY. No trading functions are used anywhere.           |
//+------------------------------------------------------------------+
#ifndef HD_COMMON_MQH
#define HD_COMMON_MQH

#define HD_VERSION        "1.0.0-stage1"
#define HD_SCHEMA_VERSION 1
#define HD_ROOT_DIR       "GatesFX_HistoricalDiscovery"
#define HD_RUNS_DIR       "GatesFX_HistoricalDiscovery\\Runs"
#define HD_INDEX_FILE     "GatesFX_HistoricalDiscovery\\run_index.csv"

//--- standard CRC-32 (IEEE, same as zlib.crc32 in Python)
uint HD_Crc32(const uchar &data[], const int len)
  {
   uint crc = 0xFFFFFFFF;
   for(int i = 0; i < len; i++)
     {
      crc ^= (uint)data[i];
      for(int b = 0; b < 8; b++)
        {
         if((crc & 1) != 0)
            crc = (crc >> 1) ^ 0xEDB88320;
         else
            crc = (crc >> 1);
        }
     }
   return ~crc;
  }

string HD_Hex(ulong v)
  {
   if(v == 0)
      return "0";
   string digits = "0123456789ABCDEF";
   string s = "";
   while(v > 0)
     {
      s = StringSubstr(digits, (int)(v & 15), 1) + s;
      v = v >> 4;
     }
   return s;
  }

//--- ASCII-only byte conversion (non-ASCII becomes '?'), no terminator
int HD_StringToBytes(const string s, uchar &out[])
  {
   int len = StringLen(s);
   ArrayResize(out, len);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if((c >= 32 && c < 127) || c == 10 || c == 13 || c == 9)
         out[i] = (uchar)c;
      else
         out[i] = (uchar)'?';
     }
   return len;
  }

string HD_TimeStr(const datetime t)
  {
   if(t == 0)
      return "";
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
  }

//--- CSV-safe text (no commas / newlines)
string HD_Sanitize(string s)
  {
   StringReplace(s, ",", ";");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

string HD_JsonEsc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

//--- JSON fragment builders (each ends with a comma)
string HD_JS(const string key, const string val)
  {
   return "\"" + key + "\":\"" + HD_JsonEsc(val) + "\",";
  }

string HD_JN(const string key, const long val)
  {
   return "\"" + key + "\":" + IntegerToString(val) + ",";
  }

//--- minimal extractors for the flat JSON this project writes
bool HD_JsonNum(const string body, const string key, long &v)
  {
   string pat = "\"" + key + "\":";
   int p = StringFind(body, pat, 0);
   if(p < 0)
      return false;
   int s = p + StringLen(pat);
   int e = s;
   int total = StringLen(body);
   while(e < total)
     {
      ushort c = StringGetCharacter(body, e);
      if(c == ',' || c == '}')
         break;
      e++;
     }
   if(e == s)
      return false;
   v = StringToInteger(StringSubstr(body, s, e - s));
   return true;
  }

bool HD_JsonStr(const string body, const string key, string &v)
  {
   string pat = "\"" + key + "\":\"";
   int p = StringFind(body, pat, 0);
   if(p < 0)
      return false;
   int s = p + StringLen(pat);
   int e = StringFind(body, "\"", s);
   if(e < 0)
      return false;
   v = StringSubstr(body, s, e - s);
   return true;
  }

#endif
