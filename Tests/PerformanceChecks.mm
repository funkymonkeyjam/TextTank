// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic editor load, find, replace and Undo timings with budgets that can fail.
//
//   performance-checks            the gated tier: 1 and 10 MiB, 100 buffers, one long line
//   performance-checks full       the manual tier: the same plus 100 MiB
//
// The budgets are a coarse tripwire, not a benchmark. Each time budget is about five
// times the value logged on the development Mac (see harness/logs/performance-checks.log:
// load 0.0075 s per MiB, whole-document find 0.00003 to 0.00017 s, replace and Undo
// 0.000007 s, 100 buffers 0.063 s, long line 0.071 s), so a change that makes an
// operation ten times slower, or makes replace or Undo copy the buffer, trips it. The
// memory ceiling is about three times the logged peak. They were calibrated on one Mac
// only; a slower runner sets TEXTTANK_PERF_BUDGET_SCALE.
// TEXTTANK_PERF_BUDGET_SCALE multiplies every budget: above 1 for a slow machine, and a
// tiny value proves that the budgets do fail.
#import <AppKit/AppKit.h>
#import "TTEditor.h"
#import "ScintillaView.h"
#include <sys/resource.h>
#include <algorithm>
#include <chrono>
#include <vector>
#import "Checks.h"
static double seconds(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
static double scale(){const char *value=getenv("TEXTTANK_PERF_BUDGET_SCALE");double parsed=value?atof(value):1;return parsed>0?parsed:1;}
static long peakBytes(){struct rusage usage;getrusage(RUSAGE_SELF,&usage);return usage.ru_maxrss;}
/// Passes when `measured` is within `budget`; a failure prints both.
static void within(double measured,double budget,NSString *what,const char *unit){
 budget*=scale();
 NSString *label=[NSString stringWithFormat:@"%@ stays within its budget",what];
 if(!check(measured<=budget,label.UTF8String)) printf("NOTE %s measured %.6f %s against a budget of %.6f %s\n",what.UTF8String,measured,unit,budget,unit);
}
int main(int argc,char **argv){@autoreleasepool{
 [NSApplication sharedApplication];
 const bool full=argc>1 && strcmp(argv[1],"full")==0;
 std::vector<int> sizes={1,10};if(full)sizes.push_back(100);
 printf("kind,MiB,load_seconds,find_seconds,replace_seconds,undo_seconds,peak_rss_bytes\n");
 for(int mib : sizes){@autoreleasepool{
  NSMutableString *fixture=[NSMutableString stringWithCapacity:mib*1024*1024];
  NSString *line=@"alpha beta gamma delta 0123456789\n";
  while([fixture length]<mib*1024*1024)[fixture appendString:line];
  [fixture appendString:@"UNIQUE-END-TOKEN"];
  // Every timing is the best of a few repetitions, so one scheduling hiccup on a busy
  // machine cannot trip a budget; a real change of cost shows in every repetition.
  TTEditor *editor=nil;double load=1e9;
  for(int attempt=0;attempt<(mib<=10?3:1);++attempt){@autoreleasepool{
   editor=nil;
   TTEditor *candidate=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];
   double a=seconds();candidate.text=fixture;[candidate resetUndoHistory];load=std::min(load,seconds()-a);editor=candidate;
  }}
  BOOL found=YES,restored=YES;double find=1e9,replace=1e9,undo=1e9;
  for(int attempt=0;attempt<5;++attempt){
   // From the start of the document, so the find scans the whole fixture.
   [editor setSelectionAnchor:0 caret:0];
   double b=seconds();found=[editor find:@"UNIQUE-END-TOKEN" matchCase:YES backwards:NO] && found;double c=seconds();
   [editor replaceSelection:@"tail"];double d=seconds();[editor executeCommand:@"undo"];double e=seconds();
   find=std::min(find,c-b);replace=std::min(replace,d-c);undo=std::min(undo,e-d);
  }
  restored=[editor.text isEqual:fixture];
  // Audit package 22 (F221, F218): a whole-document read is one copy out of the engine's
  // buffer, and the status bar's capture is one copy of the raw bytes. Logged on the development
  // Mac: text 0.00004 s at 1 MiB and 0.0006 s at 10 MiB (0.0076 s and 0.054 s before, when a read
  // made four copies), so the budget of 0.002 s per MiB fails if the extra copies come back.
  double read=1e9,capture=1e9;BOOL sameSize=YES;
  for(int attempt=0;attempt<5;++attempt){@autoreleasepool{
   double r=seconds();NSString *copy=editor.text;double s=seconds();NSData *bytes=editor.utf8Data;double t=seconds();
   read=std::min(read,s-r);capture=std::min(capture,t-s);
   sameSize=sameSize && copy.length==fixture.length && bytes.length==fixture.length && editor.byteLength==(NSInteger)fixture.length;
  }}
  NSString *size=[NSString stringWithFormat:@"%d MiB",mib];
  check(found && restored,[[size stringByAppendingString:@" find, replace and Undo restore the exact text"] UTF8String]);
  check(load<=60 && find<=10,[[size stringByAppendingString:@" load within 60 s and find within 10 s"] UTF8String]);
  long peak=peakBytes();
  printf("multiline,%d,%.6f,%.6f,%.6f,%.6f,%ld\n",mib,load,find,replace,undo,peak);fflush(stdout);
  within(load,0.04*mib,[size stringByAppendingString:@" load"],"s");
  within(find,0.0001+0.0001*mib,[size stringByAppendingString:@" find of the last token"],"s");
  within(replace,0.00005,[size stringByAppendingString:@" replace of one selection"],"s");
  within(undo,0.00005,[size stringByAppendingString:@" Undo of one replacement"],"s");
  printf("read,%d,text_seconds=%.6f,utf8_capture_seconds=%.6f\n",mib,read,capture);fflush(stdout);
  check(sameSize,[[size stringByAppendingString:@" text, raw bytes and byte length agree in size"] UTF8String]);
  within(read,0.002*mib,[size stringByAppendingString:@" whole-document text read"],"s");
  within(capture,0.002*mib,[size stringByAppendingString:@" raw UTF-8 capture"],"s");
  // Peak resident size is cumulative for the process, so the ceiling grows with the largest
  // fixture loaded so far: a fixed allowance plus thirty times the fixture's UTF-8 size.
  within((double)peak,150.0*1024*1024+30.0*mib*1024*1024,[size stringByAppendingString:@" peak resident memory"],"bytes");
 }}
 NSMutableArray *tabs=nil;double buffers=1e9,start=0;
 for(int attempt=0;attempt<3;++attempt){@autoreleasepool{
  tabs=[NSMutableArray array];start=seconds();
  for(int i=0;i<100;++i){TTEditor *view=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];view.text=@"100 independent synthetic buffers 😀";[tabs addObject:view];}
  buffers=std::min(buffers,seconds()-start);
 }}
 printf("buffers100,0,%.6f,0,0,0,0\n",buffers);
 check(tabs.count==100 && [[(TTEditor *)tabs.lastObject text] isEqual:@"100 independent synthetic buffers 😀"],"100 independent buffers hold their text");
 within(buffers,0.3,@"creating 100 buffers","s");
 NSString *line=[@"a" stringByPaddingToLength:10*1024*1024 withString:@"a" startingAtIndex:0];
 TTEditor *longLine=nil;double longLoad=1e9;
 for(int attempt=0;attempt<3;++attempt){@autoreleasepool{
  longLine=nil;
  TTEditor *candidate=[[TTEditor alloc]initWithFrame:NSMakeRect(0,0,900,600)];
  start=seconds();candidate.text=line;longLoad=std::min(longLoad,seconds()-start);longLine=candidate;
 }}
 check([longLine.text isEqual:line],"10 MiB single line loads exactly");
 printf("longline,10,%.6f,0,0,0,0\n",longLoad);
 within(longLoad,0.35,@"10 MiB single line load","s");
 return ttchecks::finish("PerformanceChecks",full?"full tier to 100 MiB; synthetic editor load/find/replace/Undo; no physical scrolling claim":"gated tier to 10 MiB; synthetic editor load/find/replace/Undo; no physical scrolling claim");
}}
