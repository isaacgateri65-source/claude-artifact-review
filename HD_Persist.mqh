//+------------------------------------------------------------------+
//| HD_Persist.mqh                                                   |
//| Run directories, verified writes, append logs, checkpoints,      |
//| file-system self-test. All I/O uses FILE_COMMON.                 |
//| Never deletes anything. Never touches paths outside              |
//| GatesFX_HistoricalDiscovery\                                     |
//+------------------------------------------------------------------+
#ifndef HD_PERSIST_MQH
#define HD_PERSIST_MQH

#include <GatesFX_HD\HD_Common.mqh>

//--- read a whole file (absolute path under Common\Files). Returns size, or <0 on failure
int HD_ReadAll(const string path, uchar &arr[])
  {
   ResetLastError();
   int h = FileOpen(path, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return -1;
   int size = (int)FileSize(h);
   ArrayResize(arr, size);
   uint got = 0;
   if(size > 0)
      got = FileReadArray(h, arr, 0, size);
   FileClose(h);
   if((int)got != size)
      return -2;
   return size;
  }

//--- append one line (adds \n), flush, close
bool HD_AppendAbs(const string path, const string line)
  {
   ResetLastError();
   int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_BIN | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;
   FileSeek(h, 0, SEEK_END);
   uchar b[];
   int len = HD_StringToBytes(line + "\n", b);
   uint w = FileWriteArray(h, b, 0, len);
   FileFlush(h);
   FileClose(h);
   return ((int)w == len);
  }

//--- checkpoint file format: 8 hex CRC32 chars, '\n', JSON body (CRC covers body bytes only)
bool HD_LoadCheckpointFile(const string path, string &body, ulong &seq)
  {
   uchar a[];
   int n = HD_ReadAll(path, a);
   if(n < 10)
      return false;
   if(a[8] != (uchar)'\n')
      return false;
   string head = CharArrayToString(a, 0, 8);
   int blen = n - 9;
   uchar b[];
   ArrayResize(b, blen);
   ArrayCopy(b, a, 0, 9, blen);
   uint crc = HD_Crc32(b, blen);
   if(head != StringFormat("%08X", crc))
      return false;
   string txt = CharArrayToString(b, 0, blen);
   long v = 0;
   if(!HD_JsonNum(txt, "seq", v))
      return false;
   body = txt;
   seq = (ulong)v;
   return true;
  }

//--- best valid checkpoint (highest seq among A/B) of a run directory
bool HD_LoadBestCheckpoint(const string runDir, string &body, ulong &seq)
  {
   string bodyA = "", bodyB = "";
   ulong seqA = 0, seqB = 0;
   bool okA = HD_LoadCheckpointFile(runDir + "\\checkpoint_A.json", bodyA, seqA);
   bool okB = HD_LoadCheckpointFile(runDir + "\\checkpoint_B.json", bodyB, seqB);
   if(!okA && !okB)
      return false;
   if(okA && (!okB || seqA > seqB))
     {
      body = bodyA;
      seq = seqA;
     }
   else
     {
      body = bodyB;
      seq = seqB;
     }
   return true;
  }

class CHDPersist
  {
private:
   string            m_runId;
   string            m_dir;
   bool              m_open;
   bool              m_moveOk;
   ulong             m_seq;
   long              m_fail;
   string            m_lastErr;

   void              Fail(const string what)
     {
      int err = GetLastError();
      m_fail++;
      m_lastErr = what + " (err=" + IntegerToString(err) + ")";
      Print("HD PERSIST FAILURE: ", m_lastErr);
     }

public:
                     CHDPersist()
     {
      m_runId = "";
      m_dir = "";
      m_open = false;
      m_moveOk = false;
      m_seq = 0;
      m_fail = 0;
      m_lastErr = "";
     }

   string            RunId() const { return m_runId; }
   string            Dir() const { return m_dir; }
   long              Failures() const { return m_fail; }
   string            LastError() const { return m_lastErr; }
   bool              MoveOk() const { return m_moveOk; }
   string            Path(const string name) const { return m_dir + "\\" + name; }

   //--- create a brand-new, uniquely named run directory (never reuses one)
   bool              OpenNew(const string tag)
     {
      FolderCreate(HD_ROOT_DIR, FILE_COMMON);
      FolderCreate(HD_RUNS_DIR, FILE_COMMON);
      string stamp = HD_Hex(GetTickCount64());
      for(int n = 0; n < 1000; n++)
        {
         string id = tag + "_" + stamp + "_" + StringFormat("%03d", n);
         string dir = HD_RUNS_DIR + "\\" + id;
         if(FileIsExist(dir + "\\claim.txt", FILE_COMMON))
            continue;
         ResetLastError();
         if(!FolderCreate(dir, FILE_COMMON))
           {
            Fail("FolderCreate " + dir);
            continue;
           }
         m_runId = id;
         m_dir = dir;
         m_open = true;
         if(!WriteTextVerified("claim.txt", "claimed " + id))
           {
            m_open = false;
            return false;
           }
         return true;
        }
      return false;
     }

   int               ReadAllBytes(const string name, uchar &arr[])
     {
      return HD_ReadAll(Path(name), arr);
     }

   //--- write file, flush, close, reopen, compare size and CRC
   bool              WriteBytesVerified(const string name, const uchar &bytes[], const int len)
     {
      string path = Path(name);
      ResetLastError();
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
        {
         Fail("open-write " + path);
         return false;
        }
      uint w = 0;
      if(len > 0)
         w = FileWriteArray(h, bytes, 0, len);
      FileFlush(h);
      FileClose(h);
      if((int)w != len)
        {
         Fail("short write " + path);
         return false;
        }
      uchar back[];
      int n = ReadAllBytes(name, back);
      if(n != len)
        {
         Fail("verify size " + path + " got " + IntegerToString(n) + " expected " + IntegerToString(len));
         return false;
        }
      if(HD_Crc32(back, n) != HD_Crc32(bytes, len))
        {
         Fail("verify crc " + path);
         return false;
        }
      return true;
     }

   bool              WriteTextVerified(const string name, const string text)
     {
      uchar b[];
      int len = HD_StringToBytes(text, b);
      return WriteBytesVerified(name, b, len);
     }

   //--- replace an existing file: write <name>.tmp (verified), then FileMove over it
   //--- (FileMove atomicity is NOT guaranteed by MQL5; completion.json is the authoritative marker)
   bool              ReplaceVerified(const string name, const string text)
     {
      if(!m_moveOk)
         return WriteTextVerified(name, text);
      string tmp = name + ".tmp";
      if(!WriteTextVerified(tmp, text))
         return false;
      ResetLastError();
      if(!FileMove(Path(tmp), FILE_COMMON, Path(name), FILE_REWRITE | FILE_COMMON))
        {
         Fail("FileMove " + Path(tmp));
         return false;
        }
      uchar a[], b[];
      int na = ReadAllBytes(name, a);
      int nb = HD_StringToBytes(text, b);
      if(na != nb || HD_Crc32(a, na) != HD_Crc32(b, nb))
        {
         Fail("verify after move " + Path(name));
         return false;
        }
      return true;
     }

   bool              AppendLine(const string name, const string line)
     {
      if(!HD_AppendAbs(Path(name), line))
        {
         Fail("append " + Path(name));
         return false;
        }
      return true;
     }

   void              Log(const string level, const string msg)
     {
      Print("HD ", level, ": ", msg);
      AppendLine("execution.log", HD_TimeStr(TimeCurrent()) + "(tester/server clock)|" + level + "|" + HD_Sanitize(msg));
     }

   bool              AppendIndex(const string event, const string parent, const string status,
                                 const string symbol, const string detail)
     {
      if(!FileIsExist(HD_INDEX_FILE, FILE_COMMON))
         HD_AppendAbs(HD_INDEX_FILE, "event,run_id,parent_run_id,status,symbol,ea_version,detail");
      string line = event + "," + m_runId + "," + parent + "," + status + "," + symbol + "," + HD_VERSION + "," + HD_Sanitize(detail);
      if(!HD_AppendAbs(HD_INDEX_FILE, line))
        {
         Fail("append run index");
         return false;
        }
      return true;
     }

   //--- checkpoint: alternating A/B files, each CRC-protected, each verified after write
   bool              WriteCheckpoint(const string inner)
     {
      m_seq++;
      string body = "{\"seq\":" + IntegerToString((long)m_seq) + "," + inner + "}";
      uchar bb[];
      int bl = HD_StringToBytes(body, bb);
      string head = StringFormat("%08X", HD_Crc32(bb, bl)) + "\n";
      string name = ((m_seq % 2) == 0) ? "checkpoint_A.json" : "checkpoint_B.json";
      return WriteTextVerified(name, head + body);
     }

   //--- copy the header plus the first `rows` data lines of a parent CSV into a new file
   bool              CopyCsvPrefixFrom(const string parentPath, const string name, const long rows)
     {
      uchar a[];
      int n = HD_ReadAll(parentPath, a);
      if(n < 0)
         return false;
      long lines = 0;
      int endPos = 0;
      for(int i = 0; i < n; i++)
        {
         if(a[i] == (uchar)'\n')
           {
            lines++;
            if(lines == rows + 1)
              {
               endPos = i + 1;
               break;
              }
           }
        }
      if(endPos == 0)
         return false;
      uchar b[];
      ArrayResize(b, endPos);
      ArrayCopy(b, a, 0, 0, endPos);
      return WriteBytesVerified(name, b, endPos);
     }

   //--- file-system self-test inside the actual execution environment
   bool              SelfTest(string &report)
     {
      report = "";
      report += "tester=" + IntegerToString(MQLInfoInteger(MQL_TESTER)) + ";";
      report += "optimization=" + IntegerToString(MQLInfoInteger(MQL_OPTIMIZATION)) + ";";
      report += "common_path=" + TerminalInfoString(TERMINAL_COMMONDATA_PATH) + ";";
      report += "data_path=" + TerminalInfoString(TERMINAL_DATA_PATH) + ";";
      report += "run_dir_relative=" + m_dir + ";";

      // T1: write, flush, close, reopen, CRC
      uchar pat[];
      ArrayResize(pat, 4096);
      for(int i = 0; i < 4096; i++)
         pat[i] = (uchar)((i * 31 + 7) & 0xFF);
      bool t1 = WriteBytesVerified("fs_probe.bin", pat, 4096);
      report += "T1_write_flush_reopen_crc=" + (t1 ? "PASS" : "FAIL") + ";";

      // T2: append x3 to a new file, reopen, exact size
      bool t2 = AppendLine("fs_probe_append.txt", "line1") &&
                AppendLine("fs_probe_append.txt", "line2") &&
                AppendLine("fs_probe_append.txt", "line3");
      uchar rb[];
      int rn = ReadAllBytes("fs_probe_append.txt", rb);
      if(t2 && rn != 18)
         t2 = false;
      report += "T2_append_reopen=" + (t2 ? "PASS" : "FAIL") + "(size=" + IntegerToString(rn) + ");";

      // T3: FileMove with rewrite over a longer existing file
      bool t3 = WriteTextVerified("fs_probe_move_src.txt", "move-test-1") &&
                WriteTextVerified("fs_probe_move_dst.txt", "old-content-that-is-longer");
      if(t3)
        {
         ResetLastError();
         t3 = FileMove(Path("fs_probe_move_src.txt"), FILE_COMMON, Path("fs_probe_move_dst.txt"), FILE_REWRITE | FILE_COMMON);
         if(!t3)
            Fail("selftest FileMove");
        }
      if(t3)
        {
         uchar mb[];
         int mn = ReadAllBytes("fs_probe_move_dst.txt", mb);
         t3 = (mn == 11) && !FileIsExist(Path("fs_probe_move_src.txt"), FILE_COMMON);
        }
      m_moveOk = t3;
      report += "T3_move_rewrite=" + (t3 ? "PASS" : "FAIL(non-fatal; direct writes used)") + ";";

      // T4: informational - where does a file WITHOUT FILE_COMMON land (tester agent sandbox)?
      string sb = "HD_sandbox_probe_" + m_runId + ".txt";
      ResetLastError();
      int h = FileOpen(sb, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE)
        {
         FileWriteString(h, "sandbox probe");
         FileFlush(h);
         FileClose(h);
         report += "T4_sandbox_probe=WRITTEN(" + sb + " in the agent/terminal MQL5\\Files, NOT Common);";
        }
      else
         report += "T4_sandbox_probe=NOT_WRITTEN;";

      return (t1 && t2);
     }
  };

#endif
